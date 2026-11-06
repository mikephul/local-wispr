import XCTest
@testable import LocalSTT

final class BackendTests: XCTestCase {
    func testMultipartPreservesAudioAndLanguage() {
        let audio = Data([0, 255, 10, 13])
        let body = Backend.multipart(audio: audio, language: "th", boundary: "test")
        XCTAssertNotNil(body.range(of: audio))
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"language\"\r\n\r\nth\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n--test--\r\n"))
        XCTAssertFalse(text.contains("name=\"model\""))
    }
    func testCleanupRequest() throws {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Backend.cleanupBody("hello")) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "pennyroyal")
        XCTAssertEqual((body["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], false)
        XCTAssertEqual((body["messages"] as? [[String: String]])?.last?["content"], "hello")
    }
    func testCleanupSuccess() async throws {
        var backend = Backend(host: "localhost")
        backend.transport = { request, timeout in
            XCTAssertEqual(timeout, 8)
            XCTAssertEqual(request.url?.port, 8080)
            return Data(#"{"choices":[{"message":{"content":" Hello. "}}]}"#.utf8)
        }
        let result = try await backend.clean("hello")
        XCTAssertEqual(result, DictationResult(text: "Hello.", cleaned: true))
    }
    func testCleanupFailuresKeepRaw() async throws {
        for response in ["{}", #"{"choices":[]}"#, #"{"choices":[{"message":{"content":" "}}]}"#] {
            var backend = Backend(host: "localhost")
            backend.transport = { _, _ in Data(response.utf8) }
            let result = try await backend.clean("raw")
            XCTAssertEqual(result, DictationResult(text: "raw", cleaned: false))
        }
        var backend = Backend(host: "localhost")
        backend.transport = { _, _ in throw ServiceError.timeout }
        let result = try await backend.clean("raw")
        XCTAssertFalse(result.cleaned)
        XCTAssertEqual(result.text, "raw")
    }
    func testCancellationDoesNotFallback() async throws {
        var backend = Backend(host: "localhost")
        backend.transport = { _, _ in try await Task.sleep(for: .seconds(10)); return Data() }
        let task = Task { try await backend.clean("raw") }
        task.cancel()
        do { _ = try await task.value; XCTFail("Canceled cleanup must throw") } catch is CancellationError {} catch { XCTFail("\(error)") }
    }
    func testTranscribeContract() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1, 2, 3]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var backend = Backend(host: "localhost")
        backend.transport = { request, timeout in
            XCTAssertEqual(timeout, 25)
            XCTAssertEqual(request.url?.path, "/v1/audio/transcriptions")
            XCTAssertEqual(request.url?.port, 8090)
            XCTAssertTrue(String(decoding: request.httpBody!, as: UTF8.self).contains("\r\nen\r\n"))
            return Data(#"{"text":" hello "}"#.utf8)
        }
        let text = try await backend.transcribe(file: file, language: "en")
        XCTAssertEqual(text, "hello")
    }
    func testInvalidHost() {
        XCTAssertThrowsError(try Backend(host: "http://localhost").endpoint(port: 8090, path: "/"))
    }
}

extension BackendTests {
    func testCustomPromptMatchesPreviewAndKeepsTranscriptSeparate() async throws {
        let instruction = "Fix punctuation only. Keep Thai and English words unchanged."
        let dictionary = [DictionaryEntry(language: .thai, heard: "ผิด", replacement: "ถูก")]
        let preview = try Backend.systemPrompt(style: .polished, instruction: instruction, dictionary: dictionary)
        var backend = Backend(host: "localhost")
        backend.transport = { request, _ in
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            XCTAssertEqual(messages[0]["content"], preview)
            XCTAssertTrue(preview.hasPrefix(instruction))
            XCTAssertFalse(preview.contains("Improve grammar"))
            XCTAssertTrue(preview.contains("preferred"))
            XCTAssertEqual(messages[1]["content"], "คำพูดต้นฉบับ")
            return Data(#"{"choices":[{"message":{"content":"คำพูดที่แก้แล้ว"}}]}"#.utf8)
        }
        let result = try await backend.clean("คำพูดต้นฉบับ", style: .polished, dictionary: dictionary, instruction: instruction)
        XCTAssertTrue(result.cleaned)
    }
    func testPromptLimitAndBlankFallbackAreEnforcedAtRequestBoundary() throws {
        let oversized = String(repeating: "ก้", count: 600)
        let limited = try Backend.systemPrompt(style: .light, instruction: oversized)
        XCTAssertEqual(limited.count, 500)
        XCTAssertEqual(limited, String(oversized.prefix(500)))
        XCTAssertEqual(try Backend.systemPrompt(style: .polished, instruction: "  \n "), PolishPrompts.defaultPrompt(for: .polished))
        XCTAssertLessThanOrEqual(PolishPrompts.defaultPrompt(for: .polished).count, 500)
    }
    func testPromptsPersistIndependentlyAndMissingSettingsKeepDefaults() throws {
        let suite = "localstt-prompts-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(PolishPrompts.load(defaults), PolishPrompts())
        var prompts = PolishPrompts()
        prompts.set("Keep it conversational.", for: .light)
        prompts.set("Use clear business prose.", for: .polished)
        defaults.set(try JSONEncoder().encode(prompts), forKey: "polishPrompts")
        XCTAssertEqual(PolishPrompts.load(defaults), prompts)
        prompts.set(PolishPrompts.defaultPrompt(for: .light), for: .light)
        XCTAssertEqual(prompts.polished, "Use clear business prose.")
    }
}


extension BackendTests {
    func testCustomLanguageAndModelsReachRequests() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        try Data([1, 2, 3]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var backend = Backend(host: "localhost")
        backend.transport = { request, _ in
            if request.url?.path == "/v1/audio/transcriptions" {
                let body = String(decoding: request.httpBody!, as: UTF8.self)
                XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nja\r\n"))
                XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nwhisper-large-v3\r\n"))
                return Data(#"{"text":"こんにちは"}"#.utf8)
            }
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(body["model"] as? String, "custom-polish")
            return Data(#"{"choices":[{"message":{"content":"こんにちは。"}}]}"#.utf8)
        }
        let raw = try await backend.transcribe(file: file, language: "ja", model: "whisper-large-v3")
        let polished = try await backend.clean(raw, model: "custom-polish")
        XCTAssertEqual(polished.text, "こんにちは。")
        XCTAssertThrowsError(try Backend.cleanupBody("text", model: "bad\r\nmodel"))
    }
}


extension BackendTests {
    func testDiscoveryRejectsInvalidAndDuplicateIDs() async throws {
        let ids = ["valid-model", "", " spaced ", "bad\nmodel", String(repeating: "a", count: 201), "valid-model"]
        let response = try JSONSerialization.data(withJSONObject: ["data": ids.map { ["id": $0] }])
        var backend = Backend(host: "localhost")
        backend.transport = { _, _ in response }
        let result = await backend.models(port: 8090)
        XCTAssertEqual(result.models.map(\.id), ["valid-model"])
        XCTAssertNil(result.error)
    }
}
