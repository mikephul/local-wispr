import XCTest
@testable import LocalSTT

final class PasteTests: XCTestCase {
    func testKnownFieldMustRemainInSameAppAndWindow() {
        XCTAssertTrue(context().allowed)
        XCTAssertFalse(context(sameApp: false).allowed)
        XCTAssertFalse(context(sameWindow: false).allowed)
        XCTAssertFalse(context(sameElement: false).allowed)
        XCTAssertFalse(context(secure: true).allowed)
    }
    func testOrcaWebAreaFallbackNeedsPasteCommandAndSameWindow() {
        XCTAssertTrue(context(sameElement: false, orca: true, command: true).allowed)
        XCTAssertFalse(context(sameElement: false, orca: true).allowed)
        XCTAssertFalse(context(sameApp: false, sameElement: false, orca: true, command: true).allowed)
        XCTAssertFalse(context(sameWindow: false, sameElement: false, orca: true, command: true).allowed)
        XCTAssertFalse(context(sameElement: false, secure: true, orca: true, command: true).allowed)
    }
    private func context(sameApp: Bool = true, sameWindow: Bool = true, sameElement: Bool = true, secure: Bool = false, orca: Bool = false, command: Bool = false) -> PasteEligibility {
        PasteEligibility(sameApp: sameApp, sameWindow: sameWindow, sameElement: sameElement, secureField: secure, orcaWebArea: orca, hasPasteCommand: command)
    }
}
