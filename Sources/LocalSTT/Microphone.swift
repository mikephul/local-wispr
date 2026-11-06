import AVFoundation
import CoreAudio

struct Microphone: Identifiable {
    let id: String
    let name: String
    let deviceID: AudioDeviceID
    static func available() -> [Microphone] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var hiddenAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIsHidden, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var hidden: UInt32 = 0
            var hiddenSize = UInt32(MemoryLayout<UInt32>.size)
            _ = AudioObjectGetPropertyData(id, &hiddenAddress, 0, nil, &hiddenSize, &hidden)
            guard hidden == 0 else { return nil }
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Microphone(id: uid, name: name, deviceID: id)
        }
    }
    static func defaultInputID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }
    static func inputProblem(uid: String, devices: [Microphone], defaultID: AudioDeviceID?) -> MicrophoneInputError? {
        if !uid.isEmpty { return devices.contains { $0.id == uid } ? nil : .disconnected }
        if devices.isEmpty { return .noInput }
        guard let defaultID, devices.contains(where: { $0.deviceID == defaultID }) else { return .noDefaultInput }
        return nil
    }
    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

enum MicrophoneInputError: LocalizedError {
    case noInput, disconnected, noDefaultInput, invalidFormat, stalled, formatChanged
    var errorDescription: String? {
        switch self {
        case .stalled: return "The microphone stopped sending audio. Reconnect it and try again."
        case .formatChanged: return "The microphone format changed. Captured audio has been kept; start a new recording after reconnecting."
        case .noInput: return "No microphone is connected. Connect an input device, then try again."
        case .disconnected: return "The selected microphone is disconnected. Reconnect it or choose another input in Settings."
        case .noDefaultInput: return "No default microphone is available. Choose an input in Settings."
        case .invalidFormat: return "The microphone is not providing audio. Reconnect it or choose another input in Settings."
        }
    }
}

final class MicrophoneObserver {
    private let listener: AudioObjectPropertyListenerBlock
    private var addresses = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice].map {
        AudioObjectPropertyAddress(mSelector: $0, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    init(onChange: @escaping () -> Void) {
        listener = { _, _ in onChange() }
        for index in addresses.indices {
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addresses[index], .main, listener)
        }
    }
    deinit {
        for index in addresses.indices {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addresses[index], .main, listener)
        }
    }
}

final class MicrophoneRecorder: AudioRecording {
    private var engine: AVAudioEngine?
    private let sink: RecordingSink
    private let deviceUID: String
    private let started = ProcessInfo.processInfo.systemUptime
    private var lastOpened = ProcessInfo.processInfo.systemUptime
    private var hasRecovered = false
    private var stopped = false
    var currentTime: Double { ProcessInfo.processInfo.systemUptime - started }
    var snapshot: RecordingSnapshot { sink.snapshot }
    var recordingError: Error? {
        if let error = sink.recordingError { return error }
        return snapshot.isStalled(at: ProcessInfo.processInfo.systemUptime, started: lastOpened) ? MicrophoneInputError.stalled : nil
    }

    init(url: URL?, uid: String) throws {
        let devices = Microphone.available()
        let defaultID = Microphone.defaultInputID()
        if let problem = Microphone.inputProblem(uid: uid, devices: devices, defaultID: defaultID) { throw problem }
        guard let device = devices.first(where: { uid.isEmpty ? $0.deviceID == defaultID : $0.id == uid }) else { throw MicrophoneInputError.noInput }
        deviceUID = device.id
        sink = RecordingSink(url: url)
        try open()
    }
    private func open() throws {
        guard var id = Microphone.available().first(where: { $0.id == deviceUID })?.deviceID else { throw MicrophoneInputError.disconnected }
        let next = AVAudioEngine()
        let input = next.inputNode
        guard let unit = input.audioUnit else { throw MicrophoneInputError.invalidFormat }
        let code = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard code == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(code)) }
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MicrophoneInputError.invalidFormat }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak sink] buffer, _ in sink?.accept(buffer) }
        do { try next.start() }
        catch { input.removeTap(onBus: 0); throw error }
        engine = next
        lastOpened = ProcessInfo.processInfo.systemUptime
    }
    func recover() throws -> Bool {
        guard !stopped, !hasRecovered, sink.recordingError == nil else { return false }
        hasRecovered = true
        closeEngine()
        try open()
        sink.markRecovery()
        return true
    }
    private func closeEngine() {
        guard let engine else { return }
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
    }
    func stop() {
        guard !stopped else { return }
        stopped = true; closeEngine(); sink.close()
    }
    deinit { stop() }
}
