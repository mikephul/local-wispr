import SwiftUI
import AppKit
import AVFoundation

struct HotkeyCheck {
    enum State: Equatable { case idle, waiting, held, passed, timedOut }
    private(set) var state: State = .idle
    var isActive: Bool { state == .waiting || state == .held }
    mutating func start() { state = .waiting }
    mutating func cancel() { state = .idle }
    mutating func timeout() { if state == .waiting { state = .timedOut } }
    mutating func press() -> Bool {
        guard isActive else { return false }
        state = .held
        return true
    }
    mutating func release() -> Bool {
        guard isActive else { return false }
        if state == .held { state = .passed }
        return true
    }
}

struct SetupView: View {
    @ObservedObject var model: AppModel
    @FocusState private var editorFocused: Bool
    private let accent = ConsoleTheme.control

    var body: some View {
        ConsolePage(title: "Setup & test", subtitle: "Check access, test each shortcut, then try your voice.") {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        permission("Microphone", detail: "Records your voice during dictation.", granted: model.microphoneAllowed) { model.requestMicrophone() }
                        if let problem = model.microphoneProblem {
                            Label(problem.localizedDescription, systemImage: "mic.slash").font(.callout).foregroundStyle(.orange)
                            Button("Choose microphone…") { model.showSettings() }
                        }
                        Divider()
                        permission("Input Monitoring", detail: "Receives the dictation key outside this window.", granted: model.inputAllowed) { model.requestInput() }
                        Divider()
                        permission("Accessibility", detail: "Inserts text into the original text field.", granted: model.accessibilityAllowed) { model.requestAccessibility() }
                        Divider()
                        Label(!model.verifiedHotkeys.isEmpty ? "Key delivery verified" : model.hotkeyListening ? "Keyboard listener ready. Test a key below to verify." : "Keyboard listener unavailable", systemImage: !model.verifiedHotkeys.isEmpty ? "checkmark.circle.fill" : "info.circle")
                            .foregroundStyle(!model.verifiedHotkeys.isEmpty ? accent : ConsoleTheme.secondaryText)
                        HStack {
                            Button("Recheck permissions") { model.refreshPermissions() }
                            Text("Checks also refresh automatically.").font(.caption).foregroundStyle(ConsoleTheme.secondaryText)
                        }
                        if !model.inputAllowed || !model.accessibilityAllowed {
                            DisclosureGroup("Permissions still showing as missing?") {
                            Text("Already enabled in System Settings? Restart local-wispr first. If these checks still show missing access, remove the old local-wispr entry and add this exact app again. Switching from an older signing identity can require a fresh permission grant.")
                                .font(.caption).foregroundStyle(ConsoleTheme.secondaryText)
                            HStack {
                                Button("Restart local-wispr") { model.restartApp() }.disabled(model.phase != .idle)
                                Button("Show this app in Finder") { model.revealApp() }
                            }
                            }
                        }
                    }.padding(16)
                } label: { Text("1  Permissions").font(.headline) }

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.preferences.actions) { action in
                            HStack {
                                Image(systemName: model.verifiedHotkeys.contains(action) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(model.verifiedHotkeys.contains(action) ? (action.language.map { model.preferences.waveColor(for: $0).color } ?? ConsoleTheme.control) : ConsoleTheme.secondaryText)
                                Text(action.title).fontWeight(.medium)
                                ShortcutKeycaps(shortcut: model.preferences.shortcut(for: action), doubleTap: action.mode == .toggle)
                                    .padding(.leading, 4)
                                Spacer()
                                Button("Test") { model.startHotkeyCheck(for: action) }.accessibilityLabel("Test \(action.title)")
                                    .disabled(model.preferences.shortcut(for: action) == nil || !model.hotkeyListening || model.hotkeyCheck.isActive || model.phase != .idle)
                            }
                        }
                        if model.preferences.actions.contains(where: { $0 != .pasteLast && model.preferences.shortcut(for: $0) == nil }) {
                            Button("Set missing shortcuts in Settings…") { model.showSettings() }
                        }
                        Text(hotkeyMessage).frame(maxWidth: .infinity, alignment: .leading)
                        if model.hotkeyCheck.isActive { Button("Cancel test") { model.stopHotkeyCheck() } }
                        if model.verifiedHotkeys.count < model.preferences.actions.count {
                            DisclosureGroup("Function key changes brightness or volume?") {
                            Text("If a function key changes brightness or volume: in System Settings → Keyboard → Keyboard Shortcuts → Function Keys, turn on “Use F1, F2, etc. keys as standard function keys.” This changes the entire function-key row.")
                                .font(.caption).foregroundStyle(ConsoleTheme.secondaryText)
                            Button("Open Keyboard settings") { model.openSettings("com.apple.Keyboard-Settings.extension") }
                            }
                        }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                } label: { Text("2  Test your shortcuts").font(.headline) }

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Click the empty box and try any shortcut above. Push to talk records while held. Hands-free starts with a double-tap and finishes with one press. Your wave and dictated text should appear.")
                        TextEditor(text: $model.testText)
                            .font(.system(size: 15))
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(height: 135)
                            .background(ConsoleTheme.screen, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(editorFocused ? accent : Color.secondary.opacity(0.4), lineWidth: 1))
                            .focused($editorFocused)
                            .accessibilityLabel("Dictation test text")
                        HStack {
                            Button("Focus text box") { model.stopHotkeyCheck(); editorFocused = true }
                            Button("Clear") { model.testText = ""; editorFocused = true }.disabled(model.testText.isEmpty)
                            if model.phase == .failed {
                                Button("Retry") { model.retry() }
                                Button("Discard") { model.cancel() }
                            } else if model.phase != .idle { Button("Cancel") { model.cancel() } }
                            if !model.latest.isEmpty { Button("Copy latest result") { model.copyLatest() } }
                        }
                        Text(model.status).font(.callout).foregroundStyle(ConsoleTheme.secondaryText).textSelection(.enabled)
                    }.padding(16)
                } label: { Text("3  Try dictation").font(.headline) }
            }.padding(.bottom, 16).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
        }
        .background(ConsoleTheme.paper)
        .tint(ConsoleTheme.control)
        .groupBoxStyle(ConsoleGroupBoxStyle())
        .frame(minWidth: 580)
        .task {
            while !Task.isCancelled {
                model.refreshPermissions()
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
        .onDisappear { model.stopHotkeyCheck() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if (notification.object as? NSWindow)?.identifier?.rawValue == "main" { model.stopHotkeyCheck() }
        }
    }

    private var hotkeyMessage: String {
        switch model.hotkeyCheck.state {
        case .idle: return "Test each shortcut separately. Press and release all its keys together. A single press verifies key delivery, including hands-free shortcuts. These checks do not record audio."
        case .waiting: return "Press and hold \(model.keyName) now."
        case .held: return "Key down received. Release it to finish the check."
        case .passed: return "\(model.testAction.title) verified. Test another shortcut or try dictation below."
        case .timedOut: return "No key press received. Check Input Monitoring and your function-key settings, then try again."
        }
    }

    private func permission(_ title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(granted ? accent : .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(ConsoleTheme.secondaryText)
            }
            Spacer()
            if granted { Text("Allowed").foregroundStyle(accent) }
            else { Button("Enable", action: action) }
        }
    }
}
