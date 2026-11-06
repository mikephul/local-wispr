import XCTest
import AVFoundation
@testable import LocalSTT

final class BatchFeaturesTests: XCTestCase {
    private func rule(_ heard: String, _ replacement: String) -> DictionaryEntry { .init(language: .english, heard: heard, replacement: replacement) }

    func testDictionaryUsesLongestNonCascadingLiteralMatches() {
        let rules = DictionaryRules([rule("swift", "SWIFT"), rule("swift ui", "SwiftUI"), rule("SwiftUI", "Wrong"), rule("a+b", "$1"), rule("", "Vocabulary")])
        XCTAssertEqual(rules.apply(to: "SWIFT UI and swift; swiftly a+b."), "SwiftUI and SWIFT; swiftly $1.")
        XCTAssertEqual(DictionaryRules([rule("foo", "first"), rule("foo", "second")]).apply(to: "foo"), "first")
        XCTAssertEqual(DictionaryRules([rule("e", "X")]).apply(to: "é e\u{301} e"), "é e\u{301} X")
    }
    func testDictionaryHandlesThaiAndMixedScripts() {
        let rules = DictionaryRules([rule("ไท", "ไทย"), rule("swift ui", "SwiftUI")])
        XCTAssertEqual(rules.apply(to: "พูดภาษาไทและใช้swift uiได้"), "พูดภาษาไทยและใช้SwiftUIได้")
    }
    func testRawAndFailedPolishStillApplyDictionary() async throws {
        var backend = Backend(host: "localhost")
        backend.transport = { request, _ in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let messages = body["messages"] as! [[String: String]]
            XCTAssertEqual(messages.last?["content"], "Use SwiftUI")
            throw ServiceError.server
        }
        for style in [CleanupStyle.raw, .light] {
            let result = try await backend.clean("Use swift ui", style: style, dictionary: [rule("swift ui", "SwiftUI")])
            XCTAssertEqual(result.text, "Use SwiftUI")
            XCTAssertFalse(result.cleaned)
        }
    }
    func testPasteLastShortcutPersistsAndCannotOverlapDictation() throws {
        var prefs = DictationPreferences()
        prefs.setShortcut(KeyShortcut([59, 9]), for: .pasteLast)
        prefs.skipSilence = false
        XCTAssertTrue(prefs.isValid)
        XCTAssertEqual(try JSONDecoder().decode(DictationPreferences.self, from: JSONEncoder().encode(prefs)), prefs)
        XCTAssertEqual(prefs.conflict(for: KeyShortcut([59, 9]), excluding: .englishHold), .pasteLast)
        prefs.setShortcut(KeyShortcut([122]), for: .pasteLast)
        XCTAssertFalse(prefs.isValid)
        let monitor = HotkeyMonitor(deliverAsynchronously: false)
        monitor.shortcuts = [.pasteLast: KeyShortcut([59, 9])]
        var edges: [Bool] = []
        monitor.onDown = { action, _ in XCTAssertEqual(action, .pasteLast); edges.append(true) }
        monitor.onUp = { action, _ in XCTAssertEqual(action, .pasteLast); edges.append(false) }
        monitor.handleKey(type: .flagsChanged, keyCode: 59, modifierDown: true)
        XCTAssertTrue(monitor.handleKey(type: .keyDown, keyCode: 9))
        XCTAssertTrue(monitor.handleKey(type: .keyDown, keyCode: 9))
        XCTAssertTrue(monitor.handleKey(type: .keyUp, keyCode: 9))
        XCTAssertEqual(edges, [true, false])
    }
    func testOldHistoryLoadsAndRevisionsAreBoundedAndRestorable() throws {
        let item = Transcript(language: .english, raw: "original", text: "first", style: .light, cleaned: true, speechSeconds: 1, cleanupSeconds: 2)
        var loaded = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(item))
        XCTAssertNil(loaded.revisions)
        for i in 0..<8 { loaded.revise(text: "version \(i)", style: .polished, cleaned: true, seconds: 3) }
        XCTAssertEqual(loaded.revisions?.count, 5)
        let previous = try XCTUnwrap(loaded.revisions?.first)
        loaded.restore(previous.id)
        XCTAssertEqual(loaded.text, "version 6")
        XCTAssertEqual(loaded.revisions?.first?.text, "version 7")
        XCTAssertEqual(loaded.raw, "original")
        XCTAssertEqual(loaded.id, item.id)
    }

    private func fixture(in directory: URL, amplitude: Float, seconds: Double = 0.3) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let count = AVAudioFrameCount(seconds * 16000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        for i in 0..<Int(count) { buffer.floatChannelData![0][i] = amplitude * Float(sin(Double(i) * 2 * .pi * 220 / 16000)) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    func testAudioFixturesUseRealWriterAndConservativeSilenceGate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (amplitude, silent) in [(Float(0), true), (0.00001, true), (0.004, false), (0.2, false)] {
            let input = try fixture(in: directory, amplitude: amplitude)
            let output = directory.appendingPathComponent(UUID().uuidString + ".m4a")
            let recorder = try AudioFixtureRecorder(fixture: input, output: output, realtime: false)
            recorder.drain()
            XCTAssertNil(recorder.recordingError)
            XCTAssertEqual(recorder.snapshot.isSilent, silent)
            XCTAssertEqual(recorder.snapshot.frames, 4800)
            recorder.stop(); recorder.stop()
            let audio = try AVAudioFile(forReading: output)
            XCTAssertGreaterThan(audio.length, 0)
        }
        let click = try AudioFixtureRecorder(fixture: fixture(in: directory, amplitude: 0.5, seconds: 0.02), output: nil, realtime: false)
        click.drain(); click.stop()
        XCTAssertTrue(click.snapshot.isSilent)
    }
    func testStallDistinguishesSilenceFromMissingAudio() {
        var snapshot = RecordingSnapshot()
        XCTAssertFalse(snapshot.isStalled(at: 3.9, started: 0))
        XCTAssertTrue(snapshot.isStalled(at: 4, started: 0))
        snapshot.lastAudioAt = 3.5
        XCTAssertFalse(snapshot.isStalled(at: 7, started: 0))
        XCTAssertTrue(snapshot.isStalled(at: 7.5, started: 0))
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for app state")
    }

    @MainActor func testFixtureRunsCaptureSilenceNetworkFailureRetryAndCancel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "audio-flow-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let silent = try fixture(in: directory, amplitude: 0)
        let audible = try fixture(in: directory, amplitude: 0.2)
        let store = LibraryStore(url: directory.appendingPathComponent("library.json"))
        let model = AppModel(library: store, monitorKeyboard: false, defaults: defaults, recordingInput: .fixture(audible))
        model.preferences.update(.english) { $0.cleanup = .raw }
        var chosen = silent
        var captured: URL?
        model.recordingFactory = { output, _ in
            captured = output
            let recording = try AudioFixtureRecorder(fixture: chosen, output: output, realtime: false)
            recording.drain()
            return recording
        }
        var fail = false
        var requests = 0
        model.backendFactory = { host in
            var backend = Backend(host: host)
            backend.transport = { request, _ in
                requests += 1
                XCTAssertEqual(request.url?.path, "/v1/audio/transcriptions")
                XCTAssertTrue(request.httpBody?.contains(0) == true)
                if fail { throw ServiceError.server }
                return Data(#"{"text":"fixture transcript"}"#.utf8)
            }
            return backend
        }
        model.begin(action: .englishHold); model.finish()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(requests, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: captured!.path))
        model.preferences.skipSilence = false
        model.begin(action: .englishHold); model.finish()
        try await waitUntil { model.phase == .idle }
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(store.data.transcripts.count, 1)
        chosen = audible; fail = true
        model.begin(action: .englishHold); model.finish()
        try await waitUntil { model.phase == .failed }
        XCTAssertTrue(FileManager.default.fileExists(atPath: captured!.path))
        model.cancelFromKeyboard()
        XCTAssertEqual(model.phase, .failed)
        fail = false
        model.retry()
        try await waitUntil { model.phase == .idle }
        XCTAssertFalse(FileManager.default.fileExists(atPath: captured!.path))
        XCTAssertEqual(store.data.transcripts.count, 2)
        model.begin(action: .englishHold); model.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: captured!.path))
        XCTAssertEqual(requests, 3)
    }

    @MainActor func testRepolishFailureCancellationAndRestoreKeepOriginal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "repolish-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(url: directory.appendingPathComponent("library.json"))
        let item = Transcript(language: .english, raw: "original", text: "previous", style: .light, cleaned: true, speechSeconds: 1, cleanupSeconds: 2)
        store.add(item)
        let model = AppModel(library: store, monitorKeyboard: false, defaults: defaults)
        var fail = true
        model.backendFactory = { host in
            var backend = Backend(host: host)
            backend.transport = { _, _ in
                if fail { throw ServiceError.server }
                try await Task.sleep(for: .milliseconds(30))
                return Data(#"{"choices":[{"message":{"content":"New polish."}}]}"#.utf8)
            }
            return backend
        }
        model.repolish(item.id, style: .polished)
        try await waitUntil { model.phase == .idle }
        XCTAssertEqual(store.data.transcripts.first?.text, "previous")
        fail = false
        model.repolish(item.id, style: .polished); model.cancel()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(store.data.transcripts.first?.text, "previous")
        model.repolish(item.id, style: .polished)
        try await waitUntil { model.phase == .idle }
        let saved = try XCTUnwrap(store.data.transcripts.first)
        XCTAssertEqual(saved.text, "New polish.")
        XCTAssertEqual(saved.raw, "original")
        model.restoreRevision(try XCTUnwrap(saved.revisions?.first?.id), transcriptID: item.id)
        XCTAssertEqual(store.data.transcripts.first?.text, "previous")
        XCTAssertEqual(LibraryStore(url: store.url).data.transcripts.first?.revisions?.first?.text, "New polish.")
    }
}

extension BatchFeaturesTests {
    func testRealtimeFixtureStopsDeliveringAndClosesAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try fixture(in: directory, amplitude: 0.2, seconds: 2)
        let output = directory.appendingPathComponent("capture.m4a")
        let recorder = try AudioFixtureRecorder(fixture: input, output: output)
        try await Task.sleep(for: .milliseconds(60))
        recorder.stop()
        let frames = recorder.snapshot.frames
        XCTAssertGreaterThan(frames, 0)
        XCTAssertLessThan(frames, 32000)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(recorder.snapshot.frames, frames)
        XCTAssertGreaterThan(try AVAudioFile(forReading: output).length, 0)
    }
    func testSinkKeepsAudioAcrossRecoveryAndRejectsNewFormat() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try AVAudioFile(forReading: fixture(in: directory, amplitude: 0.2))
        let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length))!
        try input.read(into: buffer)
        let output = directory.appendingPathComponent("recovered.m4a")
        let sink = RecordingSink(url: output)
        sink.accept(buffer, at: 10)
        sink.markRecovery()
        sink.accept(buffer, at: 20)
        XCTAssertEqual(sink.snapshot.frames, 9600)
        let different = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!, frameCapacity: 480)!
        different.frameLength = 480
        sink.accept(different, at: 21)
        XCTAssertEqual(sink.recordingError as? MicrophoneInputError, .formatChanged)
        XCTAssertEqual(sink.snapshot.frames, 9600)
        sink.close()
        XCTAssertGreaterThanOrEqual(try AVAudioFile(forReading: output).length, 9600)
    }

    private final class InterruptedFixture: AudioRecording {
        let base: AudioFixtureRecorder
        var failing = true
        var recoveries = 0
        init(_ base: AudioFixtureRecorder) { self.base = base }
        var snapshot: RecordingSnapshot { base.snapshot }
        var currentTime: Double { base.currentTime }
        var recordingError: Error? { failing ? MicrophoneInputError.stalled : base.recordingError }
        func recover() throws -> Bool {
            recoveries += 1
            guard recoveries == 1 else { return false }
            failing = false
            return true
        }
        func stop() { base.stop() }
    }

    @MainActor func testInterruptedRecordingRecoversOnceThenRetainsPartialAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "recovery-flow-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let input = try fixture(in: directory, amplitude: 0.2)
        let store = LibraryStore(url: directory.appendingPathComponent("library.json"))
        let model = AppModel(library: store, monitorKeyboard: false, defaults: defaults, recordingInput: .fixture(input))
        var captured: URL?
        var recording: InterruptedFixture?
        model.recordingFactory = { output, _ in
            captured = output
            let base = try AudioFixtureRecorder(fixture: input, output: output, realtime: false)
            base.drain()
            let wrapped = InterruptedFixture(base)
            recording = wrapped
            return wrapped
        }
        model.begin(action: .englishHold)
        try await waitUntil { recording?.recoveries == 1 }
        XCTAssertEqual(model.phase, .recording)
        XCTAssertTrue(model.status.contains("reconnected"))
        recording?.failing = true
        try await waitUntil { model.phase == .failed }
        XCTAssertEqual(recording?.recoveries, 2)
        XCTAssertTrue(model.recordingInterrupted)
        XCTAssertEqual(model.retryTitle, "Transcribe captured audio")
        XCTAssertTrue(FileManager.default.fileExists(atPath: captured!.path))
        XCTAssertGreaterThan(try AVAudioFile(forReading: captured!).length, 0)
        model.cancelFromKeyboard()
        XCTAssertTrue(FileManager.default.fileExists(atPath: captured!.path))
        model.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: captured!.path))
    }
}

extension BatchFeaturesTests {
    @MainActor func testRealtimeFixtureDrivesMeterAndCancelStopsCapture() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "meter-flow-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let input = try fixture(in: directory, amplitude: 0.2, seconds: 2)
        let model = AppModel(library: LibraryStore(url: directory.appendingPathComponent("library.json")), monitorKeyboard: false, defaults: defaults, recordingInput: .fixture(input))
        model.backendFactory = { _ in XCTFail("Cancel must not contact the server"); return Backend(host: "localhost") }
        model.begin(action: .englishHold)
        try await waitUntil { model.level > 0.1 }
        XCTAssertEqual(model.phase, .recording)
        model.cancel()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(model.phase, .idle)
    }
}
