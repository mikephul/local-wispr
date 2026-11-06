import AppKit
import AVFoundation
import ApplicationServices

final class HotkeyMonitor {
    // Only matching and suppression run on the tap thread. App callbacks are delivered
    // in order on the main queue, carrying the original hardware event timestamp.
    private let lock = NSRecursiveLock()
    private var bindings = DictationPreferences.defaultShortcuts
    var shortcuts: [ShortcutAction: KeyShortcut] {
        get { lock.withLock { bindings } }
        set { lock.withLock { bindings = newValue; matcher = ShortcutMatcher(shortcuts: newValue); suppressed.removeAll(); generation += 1 } }
    }
    private var paused = false
    var suspended: Bool {
        get { lock.withLock { paused } }
        set { lock.withLock { paused = newValue; matcher.reset(); suppressed.removeAll(); generation += 1 } }
    }
    var onDown: ((ShortcutAction, TimeInterval) -> Void)?
    var onUp: ((ShortcutAction, TimeInterval) -> Void)?
    var onCancel: (() -> Void)?
    var onInteraction: (() -> Void)?
    var isRunning: Bool { lock.withLock { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false } }
    private var tap: CFMachPort?
    private var tapLoop: CFRunLoop?
    private let stopped = DispatchSemaphore(value: 0)
    private var matcher = ShortcutMatcher(shortcuts: DictationPreferences.defaultShortcuts)
    private var suppressed = Set<Int>()
    private var generation = 0
    private let deliverAsynchronously: Bool

    init(deliverAsynchronously: Bool = true) { self.deliverAsynchronously = deliverAsynchronously }

    private enum Event { case down(ShortcutAction, TimeInterval), up(ShortcutAction, TimeInterval), cancel, interaction }
    private func emit(_ event: Event) {
        let version = generation
        let deliver = { [weak self] in
            guard let self, self.lock.withLock({ self.generation == version }) else { return }
            switch event {
            case .down(let action, let time): self.onDown?(action, time)
            case .up(let action, let time): self.onUp?(action, time)
            case .cancel: self.onCancel?()
            case .interaction: self.onInteraction?()
            }
        }
        if deliverAsynchronously { DispatchQueue.main.async(execute: deliver) }
        else { deliver() }
    }

    @discardableResult
    func handleKey(type: CGEventType, keyCode: CGKeyCode, modifierDown: Bool = false, timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !paused else { return false }
        let code = Int(keyCode)
        if type == .keyDown && code == 53 { emit(.cancel); emit(.interaction); return false }
        let down: Bool
        switch type {
        case .keyDown: down = true
        case .keyUp: down = false
        case .flagsChanged:
            guard KeyShortcut.modifiers.contains(code) else { return false }
            down = modifierDown
        default: return false
        }
        let wasSuppressed = suppressed.contains(code)
        if !down { suppressed.remove(code) }
        if let edge = matcher.update(key: code, down: down) {
            if edge.down {
                if !KeyShortcut.modifiers.contains(code) { suppressed.insert(code) }
                emit(.down(edge.action, timestamp))
            } else { emit(.up(edge.action, timestamp)) }
            let consumed = wasSuppressed || (down && !KeyShortcut.modifiers.contains(code))
            if type == .keyDown && !consumed { emit(.interaction) }
            return consumed
        }
        if type == .keyDown && !wasSuppressed { emit(.interaction) }
        return wasSuppressed
    }

    func start() -> Bool {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true); return isRunning }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.lock.lock(); defer { monitor.lock.unlock() }
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                monitor.matcher.reset()
                monitor.suppressed.removeAll()
                monitor.emit(.cancel)
                if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else if type == .leftMouseDown || type == .rightMouseDown {
                monitor.emit(.interaction)
            } else {
                let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
                if type == .keyDown && !monitor.paused {
                    monitor.matcher.synchronizeModifiers(KeyShortcut.modifierKeys(flags: event.flags))
                }
                let modifierDown = type == .flagsChanged && event.flags.contains(KeyShortcut.modifierFlag(for: code)) && !monitor.matcher.held.contains(code)
                if monitor.handleKey(type: type, keyCode: CGKeyCode(code), modifierDown: modifierDown, timestamp: event.timestamp == 0 ? ProcessInfo.processInfo.systemUptime : Double(event.timestamp) / 1_000_000_000) { return nil }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        lock.withLock { tap = created }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)!
        let ready = DispatchSemaphore(value: 0)
        let stopped = self.stopped
        let thread = Thread { [weak self] in
            self?.lock.withLock { self?.tapLoop = CFRunLoopGetCurrent() }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            ready.signal()
            CFRunLoopRun()
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            stopped.signal()
        }
        thread.name = "local-wispr keyboard"
        thread.start()
        ready.wait()
        CGEvent.tapEnable(tap: created, enable: true)
        return true
    }

    deinit {
        if let tap { CFMachPortInvalidate(tap) }
        if let tapLoop {
            CFRunLoopStop(tapLoop)
            if CFRunLoopGetCurrent() != tapLoop { stopped.wait() }
        }
    }
}

enum PasteOutcome: Equatable {
    case requested
    case copied(String)
    case cancelled
}

struct PasteEligibility {
    let sameApp: Bool
    let sameWindow: Bool
    let sameElement: Bool
    let secureField: Bool
    let orcaWebArea: Bool
    let hasPasteCommand: Bool
    var allowed: Bool {
        sameApp && sameWindow && !secureField && (sameElement || (orcaWebArea && hasPasteCommand))
    }
}

@MainActor
struct PasteTarget {
    let pid: pid_t
    let bundleID: String?
    let element: AXUIElement?
    let window: AXUIElement?
    let screen: NSScreen

    static func capture() -> PasteTarget {
        let app = NSWorkspace.shared.frontmostApplication
        let pid = app?.processIdentifier ?? 0
        let application = AXUIElementCreateApplication(pid)
        if app?.bundleIdentifier == "com.stablyai.orca" {
            AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        return PasteTarget(pid: pid, bundleID: app?.bundleIdentifier,
                           element: elementAttribute(application, kAXFocusedUIElementAttribute),
                           window: elementAttribute(application, kAXFocusedWindowAttribute),
                           screen: NSScreen.main ?? NSScreen.screens[0])
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private static func matches(_ first: AXUIElement?, _ second: AXUIElement?) -> Bool {
        guard let first, let second else { return false }
        return CFEqual(first, second)
    }
    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    private func pasteCommand() -> AXUIElement? {
        guard let menuBar = Self.elementAttribute(AXUIElementCreateApplication(pid), kAXMenuBarAttribute) else { return nil }
        for item in Self.children(menuBar) {
            for menu in Self.children(item) {
                for command in Self.children(menu) {
                    if (Self.attribute(command, "AXMenuItemCmdChar") as? String)?.lowercased() == "v",
                       (Self.attribute(command, "AXMenuItemCmdModifiers") as? Int) == 0,
                       (Self.attribute(command, kAXEnabledAttribute) as? Bool) == true {
                        return command
                    }
                }
            }
        }
        return nil
    }
    private func canPaste(hasPasteCommand: Bool) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let app = AXUIElementCreateApplication(pid)
        let current = Self.elementAttribute(app, kAXFocusedUIElementAttribute)
        let currentWindow = Self.elementAttribute(app, kAXFocusedWindowAttribute)
        let originalRole = element.flatMap { Self.attribute($0, kAXRoleAttribute) as? String }
        let currentRole = current.flatMap { Self.attribute($0, kAXRoleAttribute) as? String }
        let secure = current.flatMap { Self.attribute($0, kAXSubroleAttribute) as? String } == "AXSecureTextField"
        return PasteEligibility(
            sameApp: NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
            sameWindow: Self.matches(window, currentWindow),
            sameElement: Self.matches(element, current),
            secureField: secure,
            orcaWebArea: bundleID == "com.stablyai.orca" && originalRole == "AXWebArea" && currentRole == "AXWebArea",
            hasPasteCommand: hasPasteCommand
        ).allowed
    }

    func paste(_ text: String, stillValid: () -> Bool = { true }) async -> PasteOutcome {
        guard !Task.isCancelled else { return .cancelled }
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        board.clearContents()
        board.setString(text, forType: .string)
        let count = board.changeCount
        let command = bundleID == "com.stablyai.orca" ? pasteCommand() : nil
        guard stillValid(), canPaste(hasPasteCommand: command != nil) else {
            return .copied(AXIsProcessTrusted() ? "The original input could not be confirmed. Press Command-V to paste." : "Enable Accessibility for automatic paste, or press Command-V.")
        }
        func restoreLater() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard board.changeCount == count else { return }
                board.clearContents()
                let items = saved.map { values in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                }
                board.writeObjects(items)
            }
        }
        do { try await Task.sleep(for: .milliseconds(60)) }
        catch { restoreLater(); return .cancelled }
        guard board.changeCount == count else { return .copied("Clipboard changed before insertion. Use Copy text to copy this result again.") }
        guard stillValid(), canPaste(hasPasteCommand: command != nil) else { return .copied("Focus changed. Press Command-V in the intended field.") }
        if bundleID == "com.stablyai.orca", let command,
           AXUIElementPerformAction(command, kAXPressAction as CFString) == .success {
            restoreLater()
            return .requested
        }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return .copied("Could not send the paste shortcut. Press Command-V.")
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(50))
        up.post(tap: .cghidEventTap)
        restoreLater()
        return .requested
    }
}
