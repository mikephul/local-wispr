import XCTest
@testable import LocalSTT

final class HotkeyTests: XCTestCase {
    func testHoldRepeatsAndOtherShortcutCannotStealTheRecording() {
        let monitor = HotkeyMonitor(deliverAsynchronously: false)
        monitor.shortcuts = [.englishHold: KeyShortcut([122]), .thaiHold: KeyShortcut([120]), .englishToggle: KeyShortcut([56, 122])]
        var edges: [String] = []
        monitor.onDown = { action, _ in edges.append("\(action.rawValue) down") }
        monitor.onUp = { action, _ in edges.append("\(action.rawValue) up") }
        XCTAssertTrue(monitor.handleKey(type: .keyDown, keyCode: 122))
        XCTAssertTrue(monitor.handleKey(type: .keyDown, keyCode: 122))
        monitor.handleKey(type: .keyDown, keyCode: 120)
        monitor.handleKey(type: .keyUp, keyCode: 122)
        monitor.handleKey(type: .keyDown, keyCode: 120)
        monitor.handleKey(type: .keyUp, keyCode: 120)
        XCTAssertEqual(edges, ["englishHold down", "englishHold up"])
        monitor.handleKey(type: .keyDown, keyCode: 120)
        monitor.handleKey(type: .keyUp, keyCode: 120)
        XCTAssertEqual(edges.suffix(2), ["thaiHold down", "thaiHold up"])
    }
    func testModifiedFunctionKeyTriggersOnlyHandsFreeAndCanRepeatWithShiftHeld() {
        let monitor = HotkeyMonitor(deliverAsynchronously: false)
        monitor.shortcuts = [.englishHold: KeyShortcut([122]), .thaiHold: KeyShortcut([120]), .englishToggle: KeyShortcut([56, 122])]
        var actions: [ShortcutAction] = []
        monitor.onDown = { action, _ in actions.append(action) }
        monitor.handleKey(type: .flagsChanged, keyCode: 56, modifierDown: true)
        for _ in 0..<2 {
            monitor.handleKey(type: .keyDown, keyCode: 122)
            monitor.handleKey(type: .keyUp, keyCode: 122)
        }
        monitor.handleKey(type: .flagsChanged, keyCode: 56, modifierDown: false)
        XCTAssertEqual(actions, [.englishToggle, .englishToggle])
    }
    func testReleaseEitherKeyEndsHoldWithoutFallingThroughToSingleKey() {
        var matcher = ShortcutMatcher(shortcuts: [.englishHold: KeyShortcut([59, 49]), .thaiHold: KeyShortcut([49])])
        XCTAssertNil(matcher.update(key: 59, down: true))
        XCTAssertEqual(matcher.update(key: 49, down: true)?.action, .englishHold)
        XCTAssertEqual(matcher.update(key: 59, down: false)?.down, false)
        XCTAssertNil(matcher.update(key: 49, down: true))
        XCTAssertNil(matcher.update(key: 49, down: false))
    }
    func testTwoModifiersRightSideAndSuspendedRecorder() {
        let monitor = HotkeyMonitor(deliverAsynchronously: false)
        monitor.shortcuts = [.englishHold: KeyShortcut([61, 62])]
        var starts = 0
        monitor.onDown = { _, _ in starts += 1 }
        monitor.handleKey(type: .flagsChanged, keyCode: 58, modifierDown: true)
        monitor.handleKey(type: .flagsChanged, keyCode: 62, modifierDown: true)
        XCTAssertEqual(starts, 0)
        monitor.suspended = true
        monitor.handleKey(type: .flagsChanged, keyCode: 61, modifierDown: true)
        XCTAssertEqual(starts, 0)
        monitor.suspended = false
        monitor.handleKey(type: .flagsChanged, keyCode: 61, modifierDown: true)
        monitor.handleKey(type: .flagsChanged, keyCode: 62, modifierDown: true)
        XCTAssertEqual(starts, 1)
    }
    func testShortcutRecorderWaitsForReleaseRejectsThreeKeysAndAllowsRetry() {
        var capture = ShortcutCapture()
        capture.update(key: 55, down: true)
        capture.update(key: 49, down: true)
        XCTAssertNil(capture.candidate)
        capture.update(key: 49, down: false)
        XCTAssertNil(capture.candidate)
        capture.update(key: 55, down: false)
        XCTAssertEqual(capture.candidate, KeyShortcut([55, 49]))
        for key in [55, 56, 49] { capture.update(key: key, down: true) }
        for key in [55, 56, 49] { capture.update(key: key, down: false) }
        XCTAssertNil(capture.candidate)
        XCTAssertNotNil(capture.error)
        capture.update(key: 120, down: true)
        capture.update(key: 120, down: false)
        XCTAssertEqual(capture.candidate, KeyShortcut([120]))
        XCTAssertNil(capture.error)
    }
    func testOrdinaryTypingInvalidatesPasteAndConsumedKeysDoNot() {
        let monitor = HotkeyMonitor(deliverAsynchronously: false)
        var edits = 0
        monitor.onInteraction = { edits += 1 }
        monitor.handleKey(type: .keyDown, keyCode: 122)
        monitor.handleKey(type: .keyUp, keyCode: 122)
        XCTAssertEqual(edits, 0)
        XCTAssertFalse(monitor.handleKey(type: .keyDown, keyCode: 0))
        XCTAssertEqual(edits, 1)
    }
}

extension HotkeyTests {
    func testHandsFreeNeedsTwoQuickTapsOfTheSameShortcut() {
        var trigger = HandsFreeTrigger()
        XCTAssertFalse(trigger.update(action: .englishToggle, down: true, now: 0))
        XCTAssertFalse(trigger.update(action: .englishToggle, down: false, now: 0.1))
        XCTAssertTrue(trigger.update(action: .englishToggle, down: true, now: 0.3))
        XCTAssertFalse(trigger.update(action: .englishToggle, down: false, now: 0.4))
        XCTAssertFalse(trigger.update(action: .englishToggle, down: true, now: 0.5))
        trigger.reset()
        XCTAssertFalse(trigger.update(action: .englishToggle, down: true, now: 1))
        XCTAssertFalse(trigger.update(action: .englishToggle, down: false, now: 1.1))
        XCTAssertFalse(trigger.update(action: .thaiToggle, down: true, now: 1.2))
    }
    func testSlowTapsAndLongHoldsDoNotStartHandsFree() {
        var trigger = HandsFreeTrigger()
        XCTAssertFalse(trigger.update(action: .englishToggle, down: true, now: 0))
        XCTAssertFalse(trigger.update(action: .englishToggle, down: false, now: 1))
        XCTAssertFalse(trigger.update(action: .englishToggle, down: true, now: 1.1))
        XCTAssertFalse(trigger.update(action: .englishToggle, down: false, now: 1.2))
        XCTAssertFalse(trigger.update(action: .englishToggle, down: true, now: 2))
    }
    func testCapsLockDoesNotBlockShortcuts() {
        let monitor = HotkeyMonitor(deliverAsynchronously: false)
        var action: ShortcutAction?
        monitor.onDown = { value, _ in action = value }
        monitor.handleKey(type: .flagsChanged, keyCode: 57, modifierDown: true)
        monitor.handleKey(type: .keyDown, keyCode: 122)
        XCTAssertEqual(action, .englishHold)
    }
}

extension HotkeyTests {
    func testSharedKeyDoubleTapStartsHandsFreeAndSinglePressStops() {
        var gesture = SharedShortcutGesture()
        XCTAssertEqual(gesture.update(action: .englishHold, down: true, now: 0), .startHold)
        XCTAssertEqual(gesture.update(action: .englishHold, down: false, now: 0.1), .discardTap)
        XCTAssertEqual(gesture.update(action: .englishHold, down: true, now: 0.25), .startHandsFree)
        XCTAssertEqual(gesture.update(action: .englishHold, down: false, now: 0.35), .none)
        XCTAssertEqual(gesture.update(action: .thaiHold, down: true, now: 1), .none)
        XCTAssertEqual(gesture.update(action: .englishHold, down: true, now: 2), .finish)
        XCTAssertEqual(gesture.update(action: .englishHold, down: false, now: 2.1), .none)
    }
    func testSharedKeyHoldStillDictatesAndSlowTapsNeverSubmitAudio() {
        var gesture = SharedShortcutGesture()
        XCTAssertEqual(gesture.update(action: .englishHold, down: true, now: 0), .startHold)
        XCTAssertEqual(gesture.update(action: .englishHold, down: false, now: 1), .finish)
        XCTAssertEqual(gesture.update(action: .englishHold, down: true, now: 1.1), .startHold)
        XCTAssertEqual(gesture.update(action: .englishHold, down: false, now: 1.2), .discardTap)
        XCTAssertEqual(gesture.update(action: .englishHold, down: true, now: 2), .startHold)
        XCTAssertEqual(gesture.update(action: .englishHold, down: false, now: 2.1), .discardTap)
        gesture.reset()
        XCTAssertEqual(gesture.update(action: .englishHold, down: true, now: 2.2), .startHold)
    }
    func testSharedBindingsAreAllowedOnlyWithinOneLanguageAndPersist() throws {
        var prefs = DictationPreferences()
        prefs.shortcuts[.englishToggle] = prefs.shortcuts[.englishHold]
        XCTAssertTrue(prefs.isValid)
        XCTAssertTrue(prefs.sharesShortcut(for: .english))
        let decoded = try JSONDecoder().decode(DictationPreferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(decoded, prefs)
        var matcher = ShortcutMatcher(shortcuts: prefs.shortcuts)
        XCTAssertEqual(matcher.update(key: 122, down: true)?.action, .englishHold)
        XCTAssertEqual(matcher.update(key: 122, down: false)?.action, .englishHold)
        prefs.profiles.append(LanguageProfile(language: .thai, dictationModel: "custom-model"))
        prefs.shortcuts[.thaiToggle] = prefs.shortcuts[.englishHold]
        XCTAssertFalse(prefs.isValid)
    }
}


extension HotkeyTests {
    func testPlainComponentOfComboStillInvalidatesPaste() {
        let monitor = HotkeyMonitor(deliverAsynchronously: false)
        monitor.shortcuts = [.englishHold: KeyShortcut([59, 49])]
        var interactions = 0
        monitor.onInteraction = { interactions += 1 }
        XCTAssertFalse(monitor.handleKey(type: .keyDown, keyCode: 49))
        XCTAssertFalse(monitor.handleKey(type: .keyDown, keyCode: 49))
        monitor.handleKey(type: .keyUp, keyCode: 49)
        XCTAssertEqual(interactions, 2)
        monitor.handleKey(type: .flagsChanged, keyCode: 59, modifierDown: true)
        XCTAssertTrue(monitor.handleKey(type: .keyDown, keyCode: 49))
        XCTAssertTrue(monitor.handleKey(type: .keyDown, keyCode: 49))
        monitor.handleKey(type: .keyUp, keyCode: 49)
        XCTAssertEqual(interactions, 2)
    }

    @MainActor func testQueuedDeliveryPreservesTimestampsAndOrdering() async {
        let monitor = HotkeyMonitor()
        let delivered = expectation(description: "ordered events")
        delivered.expectedFulfillmentCount = 4
        var events: [String] = []
        var times: [TimeInterval] = []
        monitor.onDown = { _, time in
            XCTAssertTrue(Thread.isMainThread)
            events.append("down"); times.append(time); delivered.fulfill()
        }
        monitor.onUp = { _, time in events.append("up"); times.append(time); delivered.fulfill() }
        for time in [10.0, 10.2] {
            XCTAssertTrue(monitor.handleKey(type: .keyDown, keyCode: 122, timestamp: time))
            XCTAssertTrue(monitor.handleKey(type: .keyUp, keyCode: 122, timestamp: time + 0.1))
        }
        XCTAssertTrue(events.isEmpty, "App work must not run in the input callback")
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(events, ["down", "up", "down", "up"])
        for (actual, expected) in zip(times, [10.0, 10.1, 10.2, 10.3]) { XCTAssertEqual(actual, expected, accuracy: 0.00001) }
    }

    @MainActor func testSuspendingDropsAlreadyQueuedShortcutEvents() async {
        let monitor = HotkeyMonitor()
        let drained = expectation(description: "main queue drained")
        var starts = 0
        monitor.onDown = { _, _ in starts += 1 }
        monitor.handleKey(type: .keyDown, keyCode: 122)
        monitor.suspended = true
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertEqual(starts, 0)
    }
}
