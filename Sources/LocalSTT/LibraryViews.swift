import SwiftUI
import AppKit

struct ConsoleHeader: View {
    let title: String
    var subtitle: String? = nil
    var accessory: AnyView? = nil
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 29, weight: .semibold))
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(ConsoleTheme.secondaryText) }
            }
            Spacer(minLength: 16)
            if let accessory { accessory }
        }
    }
}
struct ConsolePage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ConsoleHeader(title: title, subtitle: subtitle).fixedSize(horizontal: false, vertical: true).layoutPriority(1)
            content
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
struct ConsoleEmptyState: View {
    let title: String
    let symbol: String
    let detail: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 25)).foregroundStyle(ConsoleTheme.control.opacity(0.65))
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.callout).foregroundStyle(ConsoleTheme.secondaryText).multilineTextAlignment(.center).frame(maxWidth: 340)
        }.frame(maxWidth: .infinity).padding(.vertical, 36)
    }
}
extension View {
    func consoleCard() -> some View {
        background(ConsoleTheme.screen, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ConsoleTheme.edge, lineWidth: 0.75))
    }
}

struct DictionaryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LibraryStore
    @State private var language: DictationLanguage = .english
    @State private var heard = ""
    @State private var replacement = ""
    @State private var removing: DictionaryEntry?
    private var languages: [DictationLanguage] { Array(Set(model.preferences.languages + library.data.dictionary.map(\.language))).sorted { $0.title < $1.title } }
    var body: some View {
        ConsolePage(title: "Dictionary", subtitle: "Correct phrases in every mode. Vocabulary-only entries guide Polish.") {
            VStack(alignment: .leading, spacing: 18) {
            if let error = library.error { Text(error).foregroundStyle(.red) }
            Picker("Language", selection: $language) {
                ForEach(languages, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.menu).frame(maxWidth: 280)
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Preferred spelling").font(.callout).fontWeight(.medium)
                    TextField("e.g. SwiftUI", text: $replacement).onSubmit { addEntry() }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Often heard as · Optional").font(.callout).fontWeight(.medium)
                    TextField("The spelling you want to correct", text: $heard).onSubmit { addEntry() }
                }
                HStack {
                    Text("Exact phrases are replaced before Polish, including in Raw mode. Leave this empty for vocabulary guidance.").font(.caption).foregroundStyle(ConsoleTheme.secondaryText)
                    Spacer()
                    Button("Add entry") { addEntry() }
                        .disabled(replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !library.canWrite)
                }
            }.textFieldStyle(.roundedBorder).padding(18).consoleCard()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(library.data.dictionary.filter { $0.language == language }) { entry in
                        HStack {
                            Text(entry.heard.isEmpty ? "Vocabulary" : entry.heard).foregroundStyle(ConsoleTheme.secondaryText)
                            Image(systemName: "arrow.right").foregroundStyle(ConsoleTheme.secondaryText)
                            Text(entry.replacement).textSelection(.enabled)
                            Spacer()
                            Button("Remove", systemImage: "trash") { removing = entry }.labelStyle(.iconOnly).help("Remove entry")
                        }.padding(.vertical, 14)
                        Divider()
                    }
                    if library.data.dictionary.filter({ $0.language == language }).isEmpty {
                        ConsoleEmptyState(title: "No entries yet", symbol: "character.book.closed", detail: "Add names, technical terms, or preferred spellings above.")
                    }
                }
            }
            }.frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: languages, initial: true) { _, choices in
            if !choices.contains(language), let first = choices.first { language = first }
        }
        .confirmationDialog("Remove dictionary entry?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            if let entry = removing {
                Button("Remove “\(entry.replacement)”", role: .destructive) { library.update { $0.dictionary.removeAll { $0.id == entry.id } }; removing = nil }
            }
        }
    }
    private func addEntry() {
        let preferred = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preferred.isEmpty, library.canWrite else { return }
        let entry = DictionaryEntry(language: language, heard: heard.trimmingCharacters(in: .whitespacesAndNewlines), replacement: preferred)
        if library.update({ $0.dictionary.append(entry) }) { heard = ""; replacement = "" }
    }
}

struct LLMView: View {
    @ObservedObject var model: AppModel
    private var currentHost: Bool { model.checkedHost == model.host.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        ConsolePage(title: "LLM", subtitle: "Run Dictation on this Mac or connect your own server.") {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Run Dictation").font(.headline)
                        Spacer()
                        Picker("Run Dictation", selection: $model.engineSettings.source) {
                            Text("On this Mac").tag(DictationEngineSettings.Source.onDevice)
                            Text("Server").tag(DictationEngineSettings.Source.server)
                        }.labelsHidden().fixedSize().disabled(model.phase != .idle)
                    }.padding(18).consoleCard()
                    if model.engineSettings.source == .onDevice {
                        LocalModelsView(model: model, store: model.localModels)
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Use server for Polish", isOn: $model.engineSettings.serverPolish).disabled(model.phase != .idle)
                            Text(model.engineSettings.serverPolish ? "Light and Polished modes send your transcript to the server below. Audio stays on this Mac. Raw mode stays local." : "Polish is off. Dictation and dictionary corrections run entirely on this Mac. No model endpoint is needed.")
                                .font(.caption).foregroundStyle(ConsoleTheme.secondaryText)
                        }.padding(18).consoleCard()
                    }
                    if model.engineSettings.source == .server || model.engineSettings.serverPolish {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("SERVER").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.2).foregroundStyle(ConsoleTheme.secondaryText)
                            HStack {
                                TextField("IP address or hostname", text: $model.host)
                                    .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                                    .accessibilityLabel("Server host").disabled(model.phase != .idle)
                                    .onSubmit { model.checkModels() }
                                Button(model.checkingHealth ? "Checking…" : "Check connection") { model.checkModels() }.disabled(model.checkingHealth)
                            }
                            Text("IP address or hostname. Changes save automatically.").font(.caption).foregroundStyle(ConsoleTheme.secondaryText)
                        }.padding(18).consoleCard()
                        if model.engineSettings.source == .server {
                            service("Dictation", symbol: "waveform", info: model.speechService, duration: model.speechSeconds, polish: false)
                        }
                        service("Polish", symbol: "wand.and.stars", info: model.cleanupService, duration: model.cleanupSeconds, polish: true)
                        if !currentHost {
                            Text("Host changed. Check the connection to load its models.").font(.caption).foregroundStyle(ConsoleTheme.secondaryText)
                        } else if let date = model.healthDate {
                            Text("Last checked \(date.formatted(date: .omitted, time: .standard)).").font(.caption).foregroundStyle(ConsoleTheme.secondaryText)
                        }
                        Text("Models reported by your server. Raw mode skips Polish.").font(.callout).foregroundStyle(ConsoleTheme.secondaryText)
                    }
                    Button("Try dictation") { model.showSetup() }
                }.padding(.bottom, 16).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.onAppear { model.localModels.refresh(); model.checkModels() }
        .onChange(of: model.engineSettings.source) { _, _ in model.checkModels() }
        .onChange(of: model.engineSettings.serverPolish) { _, _ in model.checkModels() }
    }
    private func service(_ title: String, symbol: String, info: ServiceModels, duration: Double?, polish: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: symbol).foregroundStyle(ConsoleTheme.control)
                Text(title).font(.headline)
                Spacer()
                if model.checkingHealth { ProgressView().controlSize(.small) }
                else if currentHost {
                    let connected = info.error == nil && !info.models.isEmpty
                    let missingModel = polish && connected && !info.models.contains { $0.id == model.preferences.polishModel }
                    Label(connected ? (missingModel ? "Model missing" : "Connected") : "Unavailable", systemImage: connected && !missingModel ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .font(.caption).foregroundStyle(connected && !missingModel ? ConsoleTheme.control : Color.orange)
                }
            }
            if currentHost && !model.checkingHealth, let error = info.error {
                Text(error).font(.callout).foregroundStyle(ConsoleTheme.secondaryText)
            }
            if polish {
                ModelSelectionField(title: "Polish model", selection: $model.preferences.polishModel, models: currentHost ? info.models : [])
                    .disabled(model.phase != .idle)
                if currentHost && !model.checkingHealth && info.error == nil && !info.models.contains(where: { $0.id == model.preferences.polishModel }) {
                    Text("The configured Polish model was not reported by this server.").font(.caption).foregroundStyle(.orange)
                }
                Text("Shared by all languages. Choose a reported model or enter its exact ID.").font(.caption).foregroundStyle(ConsoleTheme.secondaryText)
            } else {
                LanguageModelsView(model: model, models: currentHost ? info.models : [], checked: currentHost && !model.checkingHealth && info.error == nil)
            }
            if let duration { Text(String(format: "Last %@ · %.2f s", title.lowercased(), duration)).font(.caption).foregroundStyle(ConsoleTheme.secondaryText) }
            if polish {
                Divider()
                PolishPromptEditor(model: model, library: model.library)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).consoleCard()
    }
}

struct PolishPromptEditor: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LibraryStore
    @State private var style: CleanupStyle = .light
    @State private var previewLanguage: DictationLanguage = .english
    @State private var drafts = PolishPrompts()
    private var draft: String { style == .light ? drafts.light : drafts.polished }
    private var changed: Bool { draft != model.polishPrompts.instruction(for: style) }
    private var preview: String {
        (try? Backend.systemPrompt(style: style, instruction: draft, dictionary: library.data.dictionary.filter { $0.language == previewLanguage })) ?? ""
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Polish instructions").font(.callout).fontWeight(.medium)
            Picker("Mode", selection: $style) {
                Text("Light").tag(CleanupStyle.light)
                Text("Polished").tag(CleanupStyle.polished)
            }.pickerStyle(.segmented).tint(ConsoleTheme.selectionTint).frame(maxWidth: 260)
            Text("Keep instructions short. Each mode is shared by all languages. Raw skips Polish.")
                .font(.caption).foregroundStyle(ConsoleTheme.secondaryText)
            TextEditor(text: Binding(get: { draft }, set: { value in
                let limited = String(value.prefix(PolishPrompts.limit))
                if style == .light { drafts.light = limited } else { drafts.polished = limited }
            }))
            .font(.system(size: 12)).scrollContentBackground(.hidden)
            .padding(8).frame(height: 112)
            .background(ConsoleTheme.paper, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ConsoleTheme.edge, lineWidth: 0.75))
            .accessibilityLabel("\(style.title) instructions")
            HStack {
                Text("\(draft.count)/\(PolishPrompts.limit) characters")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(draft.count == PolishPrompts.limit ? Color.orange : ConsoleTheme.secondaryText)
                if draft.count == PolishPrompts.limit { Text("Limit reached").font(.caption).foregroundStyle(.orange) }
                Spacer()
                Button("Reset") {
                    let original = PolishPrompts.defaultPrompt(for: style)
                    drafts.set(original, for: style)
                    model.polishPrompts.set(original, for: style)
                }.help("Restore the default \(style.title) prompt")
                Button(changed ? "Save" : "Saved") { model.polishPrompts.set(draft, for: style); drafts.set(draft, for: style) }
                    .disabled(!changed || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            DisclosureGroup(changed ? "Full prompt preview · unsaved" : "Full prompt sent to Polish") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Dictionary", selection: $previewLanguage) {
                        ForEach(Array(Set(model.preferences.languages + library.data.dictionary.map(\.language))).sorted { $0.title < $1.title }, id: \.self) { Text($0.title).tag($0) }
                    }.frame(maxWidth: 260)
                    Text(preview).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Dictionary entries are appended separately and are not part of the 500-character limit. Your transcript is sent as a separate user message.")
                        .font(.caption).foregroundStyle(ConsoleTheme.secondaryText)
                }.padding(.top, 8)
            }.font(.caption)
            Text(changed ? "Unsaved changes. Save to use these instructions in your next dictation." : "Saved instructions apply to new recordings.")
                .font(.caption).foregroundStyle(ConsoleTheme.secondaryText)
        }.onAppear {
            drafts = model.polishPrompts
            if !model.preferences.languages.contains(previewLanguage), let first = model.preferences.languages.first { previewLanguage = first }
        }
    }
}
