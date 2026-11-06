import XCTest
@testable import LocalSTT

final class IntegrationTests: XCTestCase {
    private struct Fixture: Decodable {
        let file: String
        let language: String
        let dictationModel: String
        let polishModel: String?
        let expectedText: String
    }

    func testConfiguredLanguageFixtures() async throws {
        guard let fixtureDirectory = ProcessInfo.processInfo.environment["STT_FIXTURES"],
              let host = ProcessInfo.processInfo.environment["STT_HOST"], !host.isEmpty else {
            throw XCTSkip("Set STT_FIXTURES and STT_HOST explicitly to run the live backend test.")
        }
        let directory = URL(fileURLWithPath: fixtureDirectory)
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: directory.appendingPathComponent("fixtures.json")))
        XCTAssertFalse(fixtures.isEmpty, "Add at least one fixture to fixtures.json")
        let backend = Backend(host: host)
        for fixture in fixtures {
            XCTAssertFalse(fixture.expectedText.isEmpty, "Supply expectedText for \(fixture.file)")
            let raw = try await backend.transcribe(file: directory.appendingPathComponent(fixture.file), language: fixture.language, model: fixture.dictationModel)
            XCTAssertFalse(raw.isEmpty)
            let text: String
            if let model = fixture.polishModel {
                let result = try await backend.clean(raw, model: model)
                XCTAssertTrue(result.cleaned, "Live Polish unavailable for \(fixture.language)")
                text = result.text
            } else {
                text = raw
            }
            XCTAssertTrue(text.localizedCaseInsensitiveContains(fixture.expectedText), "Missing expected phrase for \(fixture.language)")
        }
    }
}
