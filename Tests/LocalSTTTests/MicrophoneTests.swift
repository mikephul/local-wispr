import XCTest
@testable import LocalSTT

final class MicrophoneTests: XCTestCase {
    private let microphone = Microphone(id: "usb-mic", name: "USB microphone", deviceID: 42)

    func testMissingInputIsReportedAsMicrophoneProblem() {
        XCTAssertEqual(Microphone.inputProblem(uid: "", devices: [], defaultID: nil), .noInput)
        XCTAssertTrue(MicrophoneInputError.noInput.localizedDescription.contains("No microphone"))
        XCTAssertFalse(MicrophoneInputError.invalidFormat.localizedDescription.contains("file"))
    }
    func testSelectedDisconnectedInputDoesNotSilentlySwitch() {
        XCTAssertEqual(Microphone.inputProblem(uid: "missing", devices: [microphone], defaultID: 42), .disconnected)
        XCTAssertEqual(Microphone.inputProblem(uid: "usb-mic", devices: [], defaultID: nil), .disconnected)
    }
    func testReconnectRestoresExplicitAndDefaultInputs() {
        XCTAssertNil(Microphone.inputProblem(uid: "usb-mic", devices: [microphone], defaultID: nil))
        XCTAssertNil(Microphone.inputProblem(uid: "", devices: [microphone], defaultID: 42))
        XCTAssertEqual(Microphone.inputProblem(uid: "", devices: [microphone], defaultID: nil), .noDefaultInput)
        XCTAssertEqual(Microphone.inputProblem(uid: "", devices: [microphone], defaultID: 99), .noDefaultInput)
    }
}
