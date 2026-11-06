import AVFoundation

struct RecordingSnapshot {
    var frames: Int64 = 0
    var sampleRate: Double = 0
    var power: Float = -160
    var lastAudioAt: TimeInterval?
    var longestAudibleRun: Double = 0
    var hasAudio: Bool { frames > 0 }
    var isSilent: Bool { longestAudibleRun + 0.000001 < 0.08 }
    func isStalled(at now: TimeInterval, started: TimeInterval) -> Bool { now - (lastAudioAt ?? started) >= 4 }
}

protocol AudioRecording: AnyObject {
    var snapshot: RecordingSnapshot { get }
    var currentTime: Double { get }
    var recordingError: Error? { get }
    func recover() throws -> Bool
    func stop()
}
extension AudioRecording {
    var averagePower: Float { snapshot.power }
}

// Both physical microphones and WAV fixtures use this writer and silence gate.
final class RecordingSink {
    private let lock = NSLock()
    private let url: URL?
    private var output: AVAudioFile?
    private var format: AVAudioFormat?
    private var state = RecordingSnapshot()
    private var error: Error?
    private var closed = false
    private var windowEnergy: Double = 0
    private var windowFrames = 0
    private var audibleRun: Double = 0

    init(url: URL?) { self.url = url }
    var snapshot: RecordingSnapshot { lock.withLock { state } }
    var recordingError: Error? { lock.withLock { error } }
    func accept(_ buffer: AVAudioPCMBuffer, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.withLock {
            guard !closed, error == nil, buffer.frameLength > 0 else { return }
            let incoming = buffer.format
            guard incoming.sampleRate > 0, incoming.channelCount > 0, incoming.commonFormat == .pcmFormatFloat32, let channels = buffer.floatChannelData else {
                error = MicrophoneInputError.invalidFormat; return
            }
            if let format, !format.isEqual(incoming) { error = MicrophoneInputError.formatChanged; return }
            do {
                if format == nil {
                    format = incoming
                    if let url {
                        output = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: incoming.sampleRate, AVNumberOfChannelsKey: incoming.channelCount, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue], commonFormat: incoming.commonFormat, interleaved: incoming.isInterleaved)
                    }
                }
                try output?.write(from: buffer)
            } catch { self.error = error; return }
            state.sampleRate = incoming.sampleRate
            state.frames += Int64(buffer.frameLength)
            state.lastAudioAt = now
            let windowSize = max(1, Int(incoming.sampleRate / 100))
            var peakEnergy: Double = 0
            for frame in 0..<Int(buffer.frameLength) {
                var energy: Double = 0
                for channel in 0..<Int(incoming.channelCount) {
                    let value = incoming.isInterleaved ? channels[0][frame * Int(incoming.channelCount) + channel] : channels[channel][frame]
                    if value.isFinite { energy = max(energy, Double(value * value)) }
                }
                peakEnergy += energy
                windowEnergy += energy
                windowFrames += 1
                if windowFrames == windowSize {
                    // Conservative level gate, not a speech/noise classifier.
                    audibleRun = windowEnergy / Double(windowFrames) > 0.000001 ? audibleRun + Double(windowFrames) / incoming.sampleRate : 0
                    state.longestAudibleRun = max(state.longestAudibleRun, audibleRun)
                    windowEnergy = 0; windowFrames = 0
                }
            }
            state.power = Float(10 * log10(max(peakEnergy / Double(buffer.frameLength), 1e-16)))
        }
    }
    func markRecovery() { lock.withLock { state.lastAudioAt = ProcessInfo.processInfo.systemUptime; audibleRun = 0; windowFrames = 0; windowEnergy = 0 } }
    func close() { lock.withLock { closed = true; output = nil } }
}

final class AudioFixtureRecorder: AudioRecording {
    private let input: AVAudioFile
    private let sink: RecordingSink
    private let queue = DispatchQueue(label: "local-wispr.audio-fixture")
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var error: Error?
    private let started = ProcessInfo.processInfo.systemUptime
    var snapshot: RecordingSnapshot { sink.snapshot }
    var currentTime: Double { ProcessInfo.processInfo.systemUptime - started }
    var recordingError: Error? { queue.sync { error ?? sink.recordingError } }

    init(fixture: URL, output: URL?, realtime: Bool = true) throws {
        input = try AVAudioFile(forReading: fixture, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard input.length > 0, input.processingFormat.sampleRate > 0 else { throw MicrophoneInputError.invalidFormat }
        sink = RecordingSink(url: output)
        if realtime {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(10))
            timer.setEventHandler { [weak self] in self?.readChunk() }
            self.timer = timer
            timer.resume()
        }
    }
    private func readChunk() {
        guard !stopped, error == nil, input.framePosition < input.length else { return }
        let count = AVAudioFrameCount(max(1, input.processingFormat.sampleRate / 100))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: count) else { return }
        do { try input.read(into: buffer, frameCount: count); sink.accept(buffer) }
        catch { self.error = error }
    }
    func drain() {
        queue.sync { while !stopped && error == nil && input.framePosition < input.length { readChunk() } }
    }
    func recover() throws -> Bool { false }
    func stop() { queue.sync { stopped = true; timer?.cancel(); timer = nil; sink.close() } }
    deinit { timer?.cancel(); sink.close() }
}

enum RecordingInput {
    case microphone
    case fixture(URL)
    var isFixture: Bool { if case .fixture = self { return true }; return false }
    func open(output: URL?, uid: String) throws -> any AudioRecording {
        switch self {
        case .microphone: return try MicrophoneRecorder(url: output, uid: uid)
        case .fixture(let url): return try AudioFixtureRecorder(fixture: url, output: output)
        }
    }
}
