import SwiftUI
import AppKit

enum AppPage: String, CaseIterable, Identifiable {
    case dictation, dictionary, llm, settings, setup
    var id: String { rawValue }
    var title: String {
        switch self { case .dictionary: return "Dictionary"; case .llm: return "LLM"; case .dictation: return "Dictation"; case .settings: return "Settings"; case .setup: return "Setup & test" }
    }
    var symbol: String {
        switch self { case .dictionary: return "character.book.closed"; case .llm: return "cpu"; case .dictation: return "waveform"; case .settings: return "slider.horizontal.3"; case .setup: return "checkmark.shield" }
    }
}

enum SettingsAnchor: Hashable { case history, language(DictationLanguage) }

enum ConsoleAppearance: String, CaseIterable {
    case system, light, dark
    var title: String { rawValue.capitalized }
    var native: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum ConsoleTheme {
    private static func adaptive(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
    static let paper = adaptive(NSColor(srgbRed: 0.970, green: 0.957, blue: 0.989, alpha: 1), NSColor(srgbRed: 0.105, green: 0.110, blue: 0.120, alpha: 1))
    static let sidebar = adaptive(NSColor(srgbRed: 0.930, green: 0.910, blue: 0.966, alpha: 1), NSColor(srgbRed: 0.078, green: 0.082, blue: 0.090, alpha: 1))
    static let screen = adaptive(NSColor(srgbRed: 0.995, green: 0.986, blue: 1.0, alpha: 1), NSColor(srgbRed: 0.150, green: 0.157, blue: 0.170, alpha: 1))
    static let edge = adaptive(NSColor(srgbRed: 0.36, green: 0.24, blue: 0.52, alpha: 0.16), NSColor(white: 0.28, alpha: 1))
    static let control = adaptive(NSColor(srgbRed: 0.37, green: 0.23, blue: 0.60, alpha: 1), NSColor(srgbRed: 0.81, green: 0.76, blue: 0.96, alpha: 1))
    static let secondaryText = adaptive(.secondaryLabelColor, NSColor(white: 0.72, alpha: 1))
    static let selectionTint = Color(red: 0.42, green: 0.27, blue: 0.66)
    static let selection = adaptive(NSColor(srgbRed: 0.985, green: 0.970, blue: 1.0, alpha: 1), NSColor(srgbRed: 0.230, green: 0.220, blue: 0.290, alpha: 1))
    static let keycap = adaptive(.white.withAlphaComponent(0.75), NSColor(white: 1, alpha: 0.08))

}

struct ConsoleGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            configuration.label.font(.system(size: 12, weight: .semibold)).foregroundStyle(ConsoleTheme.secondaryText)
            configuration.content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ConsoleTheme.screen, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ConsoleTheme.edge, lineWidth: 0.75))
        }
    }
}

struct AppWorkspaceView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 10) {
                    if let icon = NSImage(named: "AppIcon") {
                        Image(nsImage: icon).resizable().scaledToFit().frame(width: 34, height: 34)
                    } else {
                        Image(systemName: "waveform.path").font(.system(size: 25, weight: .medium)).foregroundStyle(ConsoleTheme.control)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("local-wispr").font(.system(size: 18, weight: .semibold))
                        Text("VOICE CONSOLE").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.4).foregroundStyle(ConsoleTheme.secondaryText)
                        Text("Version \(AppVersion.display)").font(.system(size: 10)).foregroundStyle(ConsoleTheme.secondaryText)
                    }
                }.padding(.horizontal, 18).padding(.top, 26)
                VStack(spacing: 5) {
                    ForEach(AppPage.allCases) { page in
                        Button { model.selectedPage = page } label: {
                            HStack(spacing: 10) {
                                Image(systemName: page.symbol).frame(width: 18)
                                Text(page.title).font(.system(size: 13, weight: model.selectedPage == page ? .semibold : .regular))
                                Spacer()
                            }
                            .padding(.horizontal, 12).padding(.vertical, 11)
                            .foregroundStyle(model.selectedPage == page ? ConsoleTheme.control : Color.primary)
                            .background(model.selectedPage == page ? ConsoleTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(model.selectedPage == page ? ConsoleTheme.edge : .clear, lineWidth: 0.5))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(model.selectedPage == page ? "Selected" : "")
                    }
                }.padding(.horizontal, 12)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                    Text("DICTATION SHORTCUTS").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.3).foregroundStyle(ConsoleTheme.secondaryText)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(model.preferences.languages) { keyRow($0) }
                        }
                    }.frame(height: min(CGFloat(model.preferences.profiles.count) * 76, 220))
                }.padding(18)
            }
            .background(ConsoleTheme.sidebar.ignoresSafeArea(edges: .top))
            .frame(width: 210)
            Rectangle().fill(ConsoleTheme.edge).frame(width: 1).ignoresSafeArea(edges: .top)
            VStack(spacing: 0) {
                if let notice = model.recoveryNotice {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(notice).font(.callout)
                        Spacer()
                        Button("Dismiss") { model.dismissRecoveryNotice() }
                    }.padding().background(ConsoleTheme.screen)
                }
                switch model.selectedPage ?? .dictation {
                case .dictation: AppHomeView(model: model)
                case .dictionary: DictionaryView(model: model, library: model.library)
                case .llm: LLMView(model: model)
                case .settings: AppSettingsView(model: model)
                case .setup: SetupView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ConsoleTheme.paper.ignoresSafeArea(edges: .top))
        }
        .frame(minWidth: 820, minHeight: 650)
        .tint(ConsoleTheme.control)
        .sheet(item: $model.editingShortcut, onDismiss: { model.finishEditingShortcut() }) { action in
            ShortcutEditor(model: model, action: action)
        }
    }

    private func keyRow(_ language: DictationLanguage) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Circle().fill(model.preferences.waveColor(for: language).color).frame(width: 7, height: 7)
                Text(language.title).font(.system(size: 12, weight: .medium))
            }
            ForEach(RecordingMode.allCases, id: \.self) { mode in
                HStack {
                    Text(mode == .hold ? "Hold" : "Tap").foregroundStyle(ConsoleTheme.secondaryText)
                    Spacer(minLength: 4)
                    ShortcutKeycaps(shortcut: model.preferences.shortcut(for: .action(for: language, mode: mode)), compact: true, doubleTap: mode == .toggle)
                }.font(.system(size: 10, design: .monospaced))
            }
        }
    }
}

struct AppSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ConsolePage(title: "Settings", subtitle: "Recording, languages, and the wave box.") {
            ScrollViewReader { scroll in
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $model.appearance) {
                        ForEach(ConsoleAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text("System follows your Mac’s appearance.").font(.caption).foregroundStyle(ConsoleTheme.secondaryText)
                }
                Section("Recording") {
                    Toggle("Skip silent recordings", isOn: $model.preferences.skipSilence)
                    Text("Skips silence and extremely quiet audio. Turn off for whispers or quiet microphones. Background noise may still be transcribed.").font(.caption).foregroundStyle(ConsoleTheme.secondaryText)
                    Picker("Microphone", selection: $model.preferences.microphoneUID) {
                        Text("System default").tag("")
                        ForEach(model.microphones) { Text($0.name).tag($0.id) }
                        if !model.preferences.microphoneUID.isEmpty && !model.microphones.contains(where: { $0.id == model.preferences.microphoneUID }) {
                            Text("Selected microphone disconnected").tag(model.preferences.microphoneUID)
                        }
                    }.disabled(model.phase != .idle || model.testingMicrophone)
                    HStack {
                        Button(model.testingMicrophone ? "Stop test" : "Test microphone") { model.testMicrophone() }.disabled(model.phase != .idle)
                        ProgressView(value: model.testingMicrophone ? model.level : 0).frame(width: 100)
                        Button("Refresh inputs") { model.refreshMicrophones() }
                    }
                    if let problem = model.microphoneProblem {
                        Label(problem.localizedDescription, systemImage: "mic.slash").font(.callout).foregroundStyle(.orange)
                    }
                    Text("Test for up to 15 seconds. No audio is saved or sent.").font(.caption).foregroundStyle(ConsoleTheme.secondaryText)
                    if !model.microphoneTestStatus.isEmpty { Text(model.microphoneTestStatus).font(.caption).foregroundStyle(ConsoleTheme.secondaryText) }
                }
                ForEach(model.preferences.languages, id: \.self) { language in
                    let defaults = model.preferences.resetting(language)
                    let conflict = model.preferences.actions.filter { $0.language == language }.compactMap { defaults.conflict(for: defaults.shortcut(for: $0), excluding: $0) }.first
                    Section(language.title) {
                        ForEach(model.preferences.actions.filter { $0.language == language }) { action in
                            ShortcutSettingRow(model: model, action: action)
                        }
                        Picker("Polish", selection: Binding(get: { model.preferences.cleanup(for: language) }, set: { style in
                            model.preferences.update(language) { $0.cleanup = style }
                        })) {
                            ForEach(CleanupStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .disabled(model.engineSettings.source == .onDevice && !model.engineSettings.serverPolish)
                        Text(model.engineSettings.source == .onDevice && !model.engineSettings.serverPolish ? "Polish is off for local Dictation. Enable optional server Polish in LLM to use these styles." : model.preferences.cleanup(for: language).explanation).font(.caption).foregroundStyle(ConsoleTheme.secondaryText)
                        ColorPicker("Wave color", selection: colorBinding(language), supportsOpacity: false)
                        HStack {
                            Button("Reset to defaults") {
                                let restored = model.preferences.resetting(language)
                                if restored.isValid { model.preferences = restored }
                            }
                            .disabled(conflict != nil || defaults == model.preferences)
                            .accessibilityLabel("Reset \(language.title) to defaults")
                            Text("Shortcuts, Polish, and wave color.").font(.caption).foregroundStyle(ConsoleTheme.secondaryText)
                        }
                        if let conflict {
                            Text("A default shortcut overlaps \(conflict.title). Change that shortcut before resetting.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }.id(SettingsAnchor.language(language)).disabled(model.phase != .idle || model.hotkeyCheck.isActive)
                }
                Section("Paste last dictation") {
                    ShortcutSettingRow(model: model, action: .pasteLast)
                        .disabled(model.phase != .idle)
                    Text("Optional. Choose a shortcut that is not used for dictation.").font(.caption)
                }
                Section { Button("Manage languages & models…") { model.selectedPage = .llm } }
                WaveSettingsSection(model: model)
                HistorySettingsSection(library: model.library).id(SettingsAnchor.history)
                Section("General") {
                    LabeledContent("Version", value: AppVersion.display)
                    Toggle("Launch at login", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                    if !model.loginMessage.isEmpty { Text(model.loginMessage).font(.caption) }
                    Button("Permissions & test…") { model.showSetup() }
                    Text("Settings save automatically.").font(.caption).foregroundStyle(ConsoleTheme.secondaryText)
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
            .onChange(of: model.settingsTarget, initial: true) { _, target in
                guard let target else { return }
                DispatchQueue.main.async {
                    scroll.scrollTo(target, anchor: .top)
                    model.settingsTarget = nil
                }
            }
            }.frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.refreshMicrophones() }
        .onDisappear { model.stopMicrophoneTest(); model.stopWavePreview() }
        .frame(minWidth: 580).background(ConsoleTheme.paper).tint(ConsoleTheme.control)
    }
    private func colorBinding(_ language: DictationLanguage) -> Binding<Color> {
        Binding(get: { model.preferences.waveColor(for: language).color }, set: { color in
            model.preferences.update(language) { $0.color = WaveColor(color) }
        })
    }
}

struct WaveSettingsSection: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Section("Wave box") {
            Picker("Position", selection: $model.preferences.wavePlacement) {
                ForEach(WavePlacement.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            HStack {
                Slider(value: $model.preferences.waveWidth, in: 112...280, step: 14) { Text("Size") }
                Text("\(Int(model.preferences.waveWidth)) × \(Int(model.preferences.waveSize.height.rounded()))")
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(ConsoleTheme.secondaryText).frame(width: 74, alignment: .trailing)
            }
            HStack {
                Slider(value: $model.preferences.waveInset, in: 0...100, step: 4) { Text("Edge spacing") }
                Text("\(Int(model.preferences.waveInset)) pt").font(.system(.caption, design: .monospaced)).foregroundStyle(ConsoleTheme.secondaryText).frame(width: 74, alignment: .trailing)
            }
            HStack {
                Button(model.previewingWave ? "Show again" : "Preview on screen") { model.previewWave() }
                Button("Reset") {
                    model.preferences.waveWidth = 140
                    model.preferences.waveInset = 16
                    model.preferences.wavePlacement = .bottomCenter
                }
            }
            Text("Appears on the screen where you start dictating. Position stays clear of the menu bar and Dock. Preview lasts four seconds and refreshes as you adjust it.").font(.caption).foregroundStyle(ConsoleTheme.secondaryText)
        }.disabled(model.phase != .idle)
    }
}
