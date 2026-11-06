import XCTest
import AVFoundation
import CryptoKit
@testable import LocalSTT

final class LocalDictationTests: XCTestCase {
    func testSettingsPreserveServerModeAndMakeLocalPolishOptIn() throws {
        let suite = "local-engine-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(DictationEngineSettings.load(defaults).source, .server)
        var settings = DictationEngineSettings()
        settings.source = .onDevice
        XCTAssertEqual(settings.style(.polished), .raw)
        settings.serverPolish = true
        XCTAssertEqual(settings.style(.polished), .polished)
        XCTAssertEqual(settings.style(.raw), .raw)
        defaults.set(try JSONEncoder().encode(settings), forKey: "dictationEngine")
        XCTAssertEqual(DictationEngineSettings.load(defaults), settings)
    }

    func testCatalogPinsEveryFileAndIncludesOfflineTokenizers() throws {
        XCTAssertEqual(Set(LocalModelFiles.catalog.keys), Set(LocalSpeechModel.allCases.map(\.rawValue)))
        for model in LocalSpeechModel.allCases {
            let files = try XCTUnwrap(LocalModelFiles.catalog[model.rawValue])
            XCTAssertTrue(files.contains { $0.path == "tokenizer.json" })
            XCTAssertTrue(files.contains { $0.path == "tokenizer_config.json" })
            XCTAssertEqual(Set(files.map(\.path)).count, files.count)
            for file in files {
                XCTAssertEqual(file.url.scheme, "https")
                XCTAssertEqual(file.url.host, "huggingface.co")
                XCTAssertTrue(file.url.path.range(of: "/resolve/[a-f0-9]{40}/", options: .regularExpression) != nil)
                XCTAssertTrue(file.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil)
                XCTAssertGreaterThan(file.bytes, 0)
                XCTAssertFalse(file.path.hasPrefix("/"))
                XCTAssertFalse(file.path.components(separatedBy: "/").contains(".."))
            }
        }
        XCTAssertEqual(LocalSpeechModel.languageCode("en-US"), "en")
        XCTAssertEqual(LocalSpeechModel.languageCode("th"), "th")
        XCTAssertEqual(LocalSpeechModel.languageCode("zh-cn"), "zh")
        XCTAssertNil(LocalSpeechModel.languageCode("invalid"))
    }

    func testVerificationRejectsTruncatedAndSameLengthCorruptedDownloads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let expected = Data("test model".utf8)
        let hash = SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined()
        let file = LocalModelFile(path: "model", url: URL(string: "https://example.com/model")!, bytes: Int64(expected.count), sha256: hash)
        try expected.write(to: url)
        XCTAssertNoThrow(try LocalModelFiles.verify(url, file: file))
        try Data("bad! model".utf8).write(to: url)
        XCTAssertThrowsError(try LocalModelFiles.verify(url, file: file))
        try Data("test".utf8).write(to: url)
        XCTAssertThrowsError(try LocalModelFiles.verify(url, file: file))
        XCTAssertFalse(LocalModelFiles(root: url).isInstalled(.base))
    }

    @MainActor func testLocalDictationNeverCallsServerUnlessPolishIsEnabled() async throws {
        let suite = "local-flow-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("fixture.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4000)!
        buffer.frameLength = 4000
        for i in 0..<4000 { buffer.floatChannelData![0][i] = 0.2 * Float(sin(Double(i))) }
        do {
            let audio = try AVAudioFile(forWriting: input, settings: format.settings)
            try audio.write(from: buffer)
        }
        let library = LibraryStore(url: directory.appendingPathComponent("library.json"))
        library.update { $0.dictionary = [DictionaryEntry(language: .english, heard: "swift ui", replacement: "SwiftUI")] }
        let model = AppModel(library: library, monitorKeyboard: false, defaults: defaults, recordingInput: .fixture(input), localModels: LocalModelStore(root: directory.appendingPathComponent("models")))
        defer { model.cancel() }
        model.engineSettings.source = .onDevice
        model.preferences.update(.english) { $0.cleanup = .polished; $0.dictationModel = "" }
        model.recordingFactory = { output, _ in
            let recorder = try AudioFixtureRecorder(fixture: input, output: output, realtime: false)
            recorder.drain(); return recorder
        }
        var localCalls = 0; var requests: [String] = []
        var fail = false
        model.localTranscribe = { _, selected, language in
            localCalls += 1
            XCTAssertEqual(selected, .base); XCTAssertEqual(language, "en")
            if fail { throw LocalModelError.corrupt }
            return "Use swift ui"
        }
        model.backendFactory = { host in
            var backend = Backend(host: host)
            backend.transport = { request, _ in
                requests.append(request.url!.path)
                return Data(#"{"choices":[{"message":{"content":"Use SwiftUI."}}]}"#.utf8)
            }
            return backend
        }
        func finish() async throws {
            model.begin(action: .englishHold)
            XCTAssertEqual(model.phase, .recording, model.status)
            model.finish()
            for _ in 0..<100 {
                if model.phase == .idle || model.phase == .failed { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("Dictation did not finish")
        }
        try await finish()
        XCTAssertEqual(model.latest, "Use SwiftUI")
        XCTAssertEqual(requests, [])
        XCTAssertEqual(library.data.transcripts.first?.style, .raw)
        model.repolish(try XCTUnwrap(library.data.transcripts.first).id, style: .light)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(requests, [])
        model.engineSettings.serverPolish = true
        try await finish()
        XCTAssertEqual(requests, ["/v1/chat/completions"])
        XCTAssertEqual(model.latest, "Use SwiftUI.")
        fail = true
        try await finish()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(localCalls, 3)
        XCTAssertEqual(requests, ["/v1/chat/completions"], "A local failure must never fall back to sending audio to a server")
    }

    func testLocalModelLatencyWhenExplicitlyEnabled() async throws {
        guard let root = ProcessInfo.processInfo.environment["WISPR_BENCHMARK_MODELS"],
              let fixture = ProcessInfo.processInfo.environment["WISPR_LOCAL_AUDIO_FIXTURE"] else {
            throw XCTSkip("Set WISPR_BENCHMARK_MODELS and WISPR_LOCAL_AUDIO_FIXTURE to measure already-downloaded models without changing them.")
        }
        let engine = LocalSpeechEngine(root: URL(fileURLWithPath: root))
        for model in LocalSpeechModel.allCases {
            guard LocalModelFiles(root: URL(fileURLWithPath: root)).isInstalled(model) else { continue }
            for run in 1...2 {
                let start = ProcessInfo.processInfo.systemUptime
                let text = try await engine.transcribe(file: URL(fileURLWithPath: fixture), model: model, language: "en")
                XCTAssertTrue(text.localizedCaseInsensitiveContains("local"))
                let timing = await engine.timings
                print(String(format: "BENCH %@ run %d: verify %.3fs load %.3fs decode %.3fs total %.3fs", model.rawValue, run, timing.verification, timing.loading, timing.decoding, ProcessInfo.processInfo.systemUptime - start))
            }
        }
    }

    func testWarmModelLifecycleWhenExplicitlyEnabled() async throws {
        guard let root = ProcessInfo.processInfo.environment["WISPR_BENCHMARK_MODELS"],
              let fixture = ProcessInfo.processInfo.environment["WISPR_LOCAL_AUDIO_FIXTURE"] else {
            throw XCTSkip("Set WISPR_BENCHMARK_MODELS and WISPR_LOCAL_AUDIO_FIXTURE for model lifecycle verification.")
        }
        let engine = LocalSpeechEngine(root: URL(fileURLWithPath: root), idleSeconds: 0.3)
        let file = URL(fileURLWithPath: fixture)
        async let preparation: Void = engine.prepare(.base)
        async let transcription = engine.transcribe(file: file, model: .base, language: "en")
        let (_, text) = try await (preparation, transcription)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("local"))
        let firstCount = await engine.modelLoadCount
        XCTAssertEqual(firstCount, 1, "Preparation and dictation must share one load")
        let second = try await engine.transcribe(file: file, model: .base, language: "en")
        XCTAssertTrue(second.localizedCaseInsensitiveContains("local"))
        let secondCount = await engine.modelLoadCount
        XCTAssertEqual(secondCount, 1)
        let cancelled = Task { try await engine.transcribe(file: file, model: .base, language: "en") }
        try await Task.sleep(for: .milliseconds(50))
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let afterCancel = try await engine.transcribe(file: file, model: .base, language: "en")
        XCTAssertTrue(afterCancel.localizedCaseInsensitiveContains("local"))
        try await Task.sleep(for: .milliseconds(500))
        let unloaded = await engine.loadedModelID
        XCTAssertNil(unloaded, "Idle model should release memory")
        try await engine.prepare(.base)
        let reloadedCount = await engine.modelLoadCount
        XCTAssertEqual(reloadedCount, 2)
        await engine.releaseIfIdle()
        let released = await engine.loadedModelID
        XCTAssertNil(released)
    }

    func testRealLocalModelWithNonSensitiveFixtureWhenExplicitlyEnabled() async throws {
        guard let root = ProcessInfo.processInfo.environment["WISPR_LOCAL_MODEL_TEST_ROOT"],
              let fixture = ProcessInfo.processInfo.environment["WISPR_LOCAL_AUDIO_FIXTURE"] else {
            throw XCTSkip("Set WISPR_LOCAL_MODEL_TEST_ROOT and WISPR_LOCAL_AUDIO_FIXTURE for an explicit model download/inference check.")
        }
        let engine = LocalSpeechEngine(root: URL(fileURLWithPath: root))
        try await engine.install(.base) { _ in }
        LocalNetworkGuard.reset()
        URLProtocol.registerClass(LocalNetworkGuard.self)
        defer { URLProtocol.unregisterClass(LocalNetworkGuard.self) }
        let result = try await engine.transcribe(file: URL(fileURLWithPath: fixture), model: .base, language: "en")
        XCTAssertTrue(result.localizedCaseInsensitiveContains("local"), "Expected fixture to say 'local', received: \(result)")
        // A new engine must load entirely from downloaded files, including its tokenizer.
        let restarted = LocalSpeechEngine(root: URL(fileURLWithPath: root))
        let second = try await restarted.transcribe(file: URL(fileURLWithPath: fixture), model: .base, language: "en")
        XCTAssertTrue(second.localizedCaseInsensitiveContains("local"))
        XCTAssertEqual(LocalNetworkGuard.requests, 0, "Inference must not make HTTP requests after download, including after restart")
        try await restarted.remove(.base)
        XCTAssertFalse(LocalModelFiles(root: URL(fileURLWithPath: root)).isInstalled(.base))
    }
}

private final class LocalNetworkGuard: URLProtocol {
    private static let lock = NSLock()
    private static var count = 0
    static var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func reset() { lock.lock(); count = 0; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool {
        ["http", "https"].contains(request.url?.scheme ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.count += 1; Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
