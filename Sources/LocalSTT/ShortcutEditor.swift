import SwiftUI
import AppKit

struct ShortcutCapture {
    private(set) var held = Set<Int>()
    private(set) var keys = Set<Int>()
    private(set) var candidate: KeyShortcut?
    private(set) var error: String?
    mutating func update(key: Int, down: Bool) {
        if down {
            if held.isEmpty { keys.removeAll(); candidate = nil; error = nil }
            held.insert(key); keys.insert(key)
            if keys.count > 2 { error = "Use no more than two keys." }
            else if key == 57 { error = "Caps Lock is a toggle. Choose another key." }
        } else {
            held.remove(key)
            if held.isEmpty && error == nil {
                let shortcut = KeyShortcut(Array(keys))
                if shortcut.isValid { candidate = shortcut }
                else { error = "For two-key shortcuts, include a modifier such as Shift, Control, Option, or Command." }
            }
        }
    }
}

struct ShortcutKeycaps: View {
    let shortcut: KeyShortcut?
    var compact = false
    var doubleTap = false
    var body: some View {
        HStack(spacing: 4) {
            ForEach(shortcut?.displayKeys ?? [], id: \.self) { key in
                Text(key).font(.system(size: compact ? 10 : 12, weight: .medium, design: .monospaced))
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .padding(.horizontal, compact ? 5 : 7).padding(.vertical, compact ? 3 : 5)
                    .background(ConsoleTheme.keycap, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ConsoleTheme.edge, lineWidth: 0.75))
            }
            if shortcut == nil { Text("Not set").font(.caption).foregroundStyle(ConsoleTheme.secondaryText) }
            if doubleTap && shortcut != nil {
                Text("×2").font(.system(size: compact ? 10 : 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ConsoleTheme.control)
            }
        }.fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .ignore)
             .accessibilityLabel(doubleTap && shortcut != nil ? "Double-tap \(shortcut?.title ?? "Not assigned")" : shortcut?.title ?? "Not assigned")
    }
}

struct ShortcutSettingRow: View {
    @ObservedObject var model: AppModel
    let action: ShortcutAction
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(action.mode?.title ?? action.title)
                Text(action == .pasteLast ? "Paste your latest result into the focused text field." : action.mode == .hold ? "Hold to record. Release to finish." : "Double-tap to start. Press once to finish.")
                    .font(.caption).foregroundStyle(ConsoleTheme.secondaryText)
            }
            Spacer()
            Button { model.editShortcut(action) } label: {
                HStack(spacing: 12) {
                    ShortcutKeycaps(shortcut: model.preferences.shortcut(for: action), doubleTap: action.mode == .toggle)
                    Image(systemName: "pencil").foregroundStyle(ConsoleTheme.control)
                }.padding(6).consoleCard()
            }.buttonStyle(.plain).help("Edit \(action.title) shortcut")
                .accessibilityLabel("Edit \(action.title) shortcut")
        }
    }
}

struct ShortcutEditor: View {
    @ObservedObject var model: AppModel
    let action: ShortcutAction
    @State private var capture = ShortcutCapture()
    private var conflict: ShortcutAction? {
        guard let candidate = capture.candidate else { return nil }
        var updated = model.preferences
        updated.setShortcut(candidate, for: action)
        return updated.conflict(for: candidate, excluding: action)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Edit shortcut").font(.title2).fontWeight(.semibold)
            Text(action.title).foregroundStyle(ConsoleTheme.secondaryText)
            Text("Press and release one key, or a modifier plus one other key. Two modifiers also work. Escape cancels.").font(.callout)
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(ConsoleTheme.screen)
                if !capture.keys.isEmpty {
                    ShortcutKeycaps(shortcut: KeyShortcut(Array(capture.keys)), doubleTap: action.mode == .toggle)
                } else { Text("Waiting for keys…").foregroundStyle(ConsoleTheme.secondaryText) }
                ShortcutCaptureView { key, down in
                    if key == 53 { model.finishEditingShortcut() }
                    else { capture.update(key: key, down: down) }
                }
            }.frame(height: 76).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ConsoleTheme.control, lineWidth: 1))
            Group {
                if let error = capture.error { Text(error).foregroundStyle(.orange) }
                else if let conflict { Text("Overlaps \(conflict.title). Choose a different shortcut.").foregroundStyle(.orange) }
                else if capture.candidate != nil { Text("Ready to save. Press another shortcut to replace it.").foregroundStyle(ConsoleTheme.secondaryText) }
                else { Text("Maximum two keys. You can share a key between modes for the same language.").foregroundStyle(ConsoleTheme.secondaryText) }
            }.font(.caption).frame(minHeight: 32, alignment: .topLeading)
            if action.mode == .toggle, let language = action.language {
                Button("Use push-to-talk shortcut ×2") {
                    model.preferences.useHoldShortcutForHandsFree(language)
                    model.finishEditingShortcut()
                }.disabled(model.preferences.shortcut(for: .action(for: language, mode: .hold)) == nil)
            }
            HStack {
                Text("Some shortcuts are reserved by macOS or other apps.").font(.caption).foregroundStyle(ConsoleTheme.secondaryText)
                Spacer()
                if model.preferences.shortcut(for: action) != nil {
                    Button("Clear") {
                        model.preferences.setShortcut(nil, for: action)
                        model.finishEditingShortcut()
                    }
                }
                Button("Cancel") { model.finishEditingShortcut() }
                Button("Save") {
                    guard let shortcut = capture.candidate, conflict == nil else { return }
                    model.preferences.setShortcut(shortcut, for: action)
                    model.finishEditingShortcut()
                }.disabled(capture.candidate == nil || conflict != nil || capture.error != nil)
            }
        }.padding(24).frame(width: 480).background(ConsoleTheme.paper).tint(ConsoleTheme.control)
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in capture = ShortcutCapture() }
    }
}

private struct ShortcutCaptureView: NSViewRepresentable {
    let onKey: (Int, Bool) -> Void
    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.onKey = onKey
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ view: KeyView, context: Context) { view.onKey = onKey }
    final class KeyView: NSView {
        var onKey: ((Int, Bool) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
        private var modifiers = Set<Int>()
        override func keyDown(with event: NSEvent) {
            guard !event.isARepeat else { return }
            let current = KeyShortcut.modifierKeys(flags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)))
            for key in current.subtracting(modifiers) { onKey?(key, true) }
            modifiers.formUnion(current)
            onKey?(Int(event.keyCode), true)
        }
        override func keyUp(with event: NSEvent) {
            onKey?(Int(event.keyCode), false)
            for key in modifiers where !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(key)) {
                onKey?(key, false)
                modifiers.remove(key)
            }
        }
        override func flagsChanged(with event: NSEvent) {
            let code = Int(event.keyCode)
            guard KeyShortcut.modifiers.contains(code) else {
                onKey?(code, true); onKey?(code, false)
                return
            }
            let down = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)).contains(KeyShortcut.modifierFlag(for: code)) && !modifiers.contains(code)
            if down { modifiers.insert(code) } else { modifiers.remove(code) }
            onKey?(code, down)
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else { return false }
            keyDown(with: event)
            return true
        }
    }
}
