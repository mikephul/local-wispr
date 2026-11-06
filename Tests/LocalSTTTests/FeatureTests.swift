import XCTest
@testable import LocalSTT

final class FeatureTests: XCTestCase {
    func testPreferencesMigrateWithoutLosingKeysOrColors() throws {
        let old = Data(#"{"englishKey":114,"thaiKey":61,"englishColor":{"red":0.2,"green":0.3,"blue":0.4},"thaiColor":{"red":0.7,"green":0.6,"blue":0.5}}"#.utf8)
        var prefs = try JSONDecoder().decode(DictationPreferences.self, from: old)
        XCTAssertEqual(prefs.shortcut(for: .englishHold), KeyShortcut([114]))
        XCTAssertEqual(prefs.shortcut(for: .thaiHold), KeyShortcut([61]))
        XCTAssertEqual(prefs.waveColor(for: .english).red, 0.2)
        XCTAssertEqual(prefs.cleanup(for: .english), .light)
        prefs.update(.thai) { $0.cleanup = .raw }; prefs.shortcuts[.englishToggle] = KeyShortcut([55, 49]); prefs.microphoneUID = "device"
        XCTAssertEqual(try JSONDecoder().decode(DictationPreferences.self, from: JSONEncoder().encode(prefs)), prefs)
    }
    func testToggleReleaseDoesNotStopAndOtherLanguageCannotStop() {
        XCTAssertEqual(RecordingMode.toggle.action(down: true, recording: false, sameLanguage: false), .begin)
        XCTAssertEqual(RecordingMode.toggle.action(down: false, recording: true, sameLanguage: true), .ignore)
        XCTAssertEqual(RecordingMode.toggle.action(down: true, recording: true, sameLanguage: false), .ignore)
        XCTAssertEqual(RecordingMode.toggle.action(down: true, recording: true, sameLanguage: true), .finish)
        XCTAssertEqual(RecordingMode.hold.action(down: false, recording: true, sameLanguage: true), .finish)
        XCTAssertEqual(RecordingMode.hold.action(down: true, recording: true, sameLanguage: true), .ignore)
    }
    func testRawSkipsNetworkAndKeepsExactTranscript() async throws {
        var backend = Backend(host: "invalid")
        backend.transport = { _, _ in XCTFail("Raw mode must not contact LLM"); throw ServiceError.server }
        let result = try await backend.clean("um สวัสดี", style: .raw)
        XCTAssertEqual(result.text, "um สวัสดี")
    }
    func testDictionaryIsDataAndPolishedPromptPreservesMeaning() throws {
        let body = try Backend.cleanupBody("test", style: .polished, dictionary: [.init(language: .thai, heard: "ผิด", replacement: "ถูก")])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[1]["content"], "test")
        XCTAssertTrue(messages[0]["content"]!.contains("Do not add facts"))
        XCTAssertTrue(messages[0]["content"]!.contains("ถูก"))
    }
    @MainActor func testHistoryPersistsSearchesPrunesAndKeepsDictionary() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.json")
        let store = LibraryStore(url: url)
        var old = Transcript(language: .english, raw: "misheard", text: "correct", style: .light, cleaned: true, speechSeconds: 1, cleanupSeconds: 2)
        old.date = Date().addingTimeInterval(-31 * 86400)
        store.update { $0.retentionDays = 0 }
        store.add(old)
        store.add(Transcript(language: .thai, raw: "สวัสดี", text: "สวัสดีครับ", style: .polished, cleaned: true, speechSeconds: 1, cleanupSeconds: 2))
        store.update { $0.dictionary.append(.init(language: .english, heard: "", replacement: "SwiftUI")) }
        let loaded = LibraryStore(url: url)
        XCTAssertEqual(loaded.data.transcripts.count, 2)
        XCTAssertTrue(loaded.data.transcripts[0].matches("สวัสดี"))
        XCTAssertTrue(loaded.data.transcripts[1].matches("MISHEARD"))
        loaded.update { $0.retentionDays = 30 }
        XCTAssertEqual(LibraryStore(url: url).data.transcripts.count, 1)
        loaded.update { $0.transcripts.removeAll() }
        XCTAssertEqual(LibraryStore(url: url).data.dictionary.count, 1)
    }
    @MainActor func testUnreadableHistoryIsNotOverwritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data("broken".utf8)
        try original.write(to: url)
        let store = LibraryStore(url: url)
        XCTAssertNotNil(store.error)
        XCTAssertFalse(store.canWrite)
        store.update { $0.retentionDays = 7 }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    @MainActor func testLibraryCanSaveAfterTemporaryWriteFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let parent = directory.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: parent)
        let store = LibraryStore(url: parent.appendingPathComponent("library.json"))
        XCTAssertFalse(store.update { $0.retentionDays = 7 })
        XCTAssertNotNil(store.error)
        XCTAssertEqual(store.data.retentionDays, 30)
        try FileManager.default.removeItem(at: parent)
        XCTAssertTrue(store.update { $0.retentionDays = 7 })
        XCTAssertNil(store.error)
        XCTAssertEqual(LibraryStore(url: store.url).data.retentionDays, 7)
    }
    func testModelDiscoveryPreservesLanguageAndReportsFailure() async {
        var backend = Backend(host: "localhost")
        backend.transport = { request, timeout in
            XCTAssertEqual(request.url?.path, "/v1/models")
            XCTAssertEqual(timeout, 3)
            if request.url?.port == 8090 { return Data(#"{"data":[{"id":"parakeet-tdt-0.6b-v2","language":"en"},{"id":"typhoon-whisper-turbo","language":"th"}]}"#.utf8) }
            throw ServiceError.timeout
        }
        let speech = await backend.models(port: 8090)
        let cleanup = await backend.models(port: 8080)
        XCTAssertEqual(speech.models.map(\.languageName), ["English", "Thai"])
        XCTAssertNil(speech.error)
        XCTAssertNotNil(cleanup.error)
        XCTAssertTrue(cleanup.models.isEmpty)
    }
    func testModelDiscoveryHandlesMissingLanguageEmptyListAndMalformedResponse() async {
        for response in [#"{"data":[{"id":"pennyroyal"}]}"#, #"{"data":[]}"#, "{}"] {
            var backend = Backend(host: "localhost")
            backend.transport = { _, _ in Data(response.utf8) }
            let info = await backend.models(port: 8080)
            if response.contains("pennyroyal") {
                XCTAssertEqual(info.models.first?.id, Backend.cleanupModel)
                XCTAssertNil(info.models.first?.languageName)
                XCTAssertNil(info.error)
            } else { XCTAssertNotNil(info.error) }
        }
    }

    func testWaveLayoutSupportsOffsetScreensAndClampsInsets() {
        let area = CGRect(x: -1440, y: 24, width: 1440, height: 850)
        let size = CGSize(width: 140, height: 44)
        XCTAssertEqual(WavePlacement.bottomCenter.origin(in: area, size: size, inset: 16), CGPoint(x: -790, y: 40))
        XCTAssertEqual(WavePlacement.topRight.origin(in: area, size: size, inset: 16), CGPoint(x: -156, y: 814))
        let small = CGRect(x: 0, y: 0, width: 160, height: 60)
        XCTAssertEqual(WavePlacement.topLeft.origin(in: small, size: size, inset: 100), CGPoint(x: 10, y: 8))
    }
    func testWaveSettingsPersistAndOldPreferencesKeepOriginalLayout() throws {
        var prefs = DictationPreferences()
        prefs.waveWidth = 224; prefs.waveInset = 32; prefs.wavePlacement = .topLeft
        let restored = try JSONDecoder().decode(DictationPreferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(restored, prefs)
        XCTAssertEqual(restored.waveSize.width, 224)
        let legacy = try JSONDecoder().decode(DictationPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.waveWidth, 140)
        XCTAssertEqual(legacy.waveInset, 16)
        XCTAssertEqual(legacy.wavePlacement, .bottomCenter)
        prefs.waveWidth = .infinity
        XCTAssertFalse(prefs.isValid)
    }

}
