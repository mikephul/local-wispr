import XCTest
@testable import LocalSTT

final class SetupTests: XCTestCase {
    func testCheckConsumesPressAndReleaseWithoutStartingDictation() {
        var check = HotkeyCheck()
        check.start()
        XCTAssertTrue(check.press())
        XCTAssertEqual(check.state, .held)
        XCTAssertTrue(check.release())
        XCTAssertEqual(check.state, .passed)
        XCTAssertFalse(check.isActive)
        XCTAssertFalse(check.press(), "Next press must reach normal dictation")
        XCTAssertFalse(check.release())
    }
    func testReleaseWithoutPressDoesNotPass() {
        var check = HotkeyCheck()
        check.start()
        XCTAssertTrue(check.release())
        XCTAssertEqual(check.state, .waiting)
    }
    func testTimeoutOnlyWhenNoPressArrived() {
        var check = HotkeyCheck()
        check.start()
        check.timeout()
        XCTAssertEqual(check.state, .timedOut)
        XCTAssertFalse(check.isActive)
        check.start()
        _ = check.press()
        check.timeout()
        XCTAssertEqual(check.state, .held)
        _ = check.release()
        check.timeout()
        XCTAssertEqual(check.state, .passed)
    }
    func testCancelRestoresNormalRouting() {
        var check = HotkeyCheck()
        check.start()
        _ = check.press()
        check.cancel()
        XCTAssertFalse(check.press())
        XCTAssertFalse(check.release())
        XCTAssertEqual(check.state, .idle)
    }
    func testMonitorDrivesCheckWithoutRecordingCallbacks() {
        var check = HotkeyCheck()
        check.start()
        let monitor = HotkeyMonitor(deliverAsynchronously: false)
        var recordings = 0
        var stops = 0
        monitor.onDown = { _, _ in if !check.press() { recordings += 1 } }
        monitor.onUp = { _, _ in if !check.release() { stops += 1 } }
        monitor.handleKey(type: .keyDown, keyCode: 122)
        monitor.handleKey(type: .keyDown, keyCode: 122)
        monitor.handleKey(type: .keyUp, keyCode: 122)
        XCTAssertEqual(check.state, .passed)
        XCTAssertEqual(recordings, 0)
        XCTAssertEqual(stops, 0)
        monitor.handleKey(type: .keyDown, keyCode: 122)
        monitor.handleKey(type: .keyUp, keyCode: 122)
        XCTAssertEqual(recordings, 1)
        XCTAssertEqual(stops, 1)
    }
}


extension SetupTests {
    @MainActor func testEscapePreservesFailureAndIdleStatusButCancelsActiveWork() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(library: LibraryStore(url: directory.appendingPathComponent("library.json")), monitorKeyboard: false, localModels: LocalModelStore(root: directory.appendingPathComponent("models")))
        model.phase = .failed
        model.status = "Retained for retry"
        model.feedback = .failed
        model.cancelFromKeyboard()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.status, "Retained for retry")
        XCTAssertEqual(model.feedback, .failed)
        model.phase = .idle
        model.status = "Text ready"
        model.cancelFromKeyboard()
        XCTAssertEqual(model.status, "Text ready")
        for phase in [AppModel.Phase.recording, .transcribing, .cleaning] {
            model.phase = phase
            model.cancelFromKeyboard()
            XCTAssertEqual(model.phase, .idle)
            XCTAssertEqual(model.status, "Ready.")
        }
    }
}
