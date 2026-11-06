import SwiftUI

struct ModelSelectionField: View {
    let title: String
    @Binding var selection: String
    let models: [ReportedModel]
    @State private var draft = ""
    private var normalized: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        HStack(spacing: 8) {
            TextField("Model ID", text: $draft)
                .font(.system(size: 12, design: .monospaced)).textFieldStyle(.roundedBorder)
                .accessibilityLabel(title)
                .onSubmit { save() }
            if !models.isEmpty {
                Menu {
                    ForEach(models) { item in Button(item.id) { guard ModelID.isValid(item.id) else { return }; draft = item.id; save() } }
                } label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24).help("Choose a model reported by the server")
                .accessibilityLabel("Choose \(title)")
            }
            Button(draft == selection ? "Saved" : "Save") { save() }
                .disabled(draft == selection || !ModelID.isValid(normalized))
        }
        .onAppear { draft = selection }
        .onChange(of: selection) { _, value in draft = value }
    }
    private func save() {
        guard ModelID.isValid(normalized) else { return }
        selection = normalized; draft = normalized
    }
}

struct LanguageModelsView: View {
    @ObservedObject var model: AppModel
    let models: [ReportedModel]
    let checked: Bool
    @State private var adding = false
    @State private var removing: DictationLanguage?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.engineSettings.source == .onDevice ? "Languages use the selected local Whisper model. Server model choices are kept for when you switch back." : "Choose a dictation model for each language. Models must already be running on your server and support that language.")
                .font(.caption).foregroundStyle(ConsoleTheme.secondaryText)
            ForEach(model.preferences.profiles) { profile in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Circle().fill(profile.color.color).frame(width: 7, height: 7)
                        Text(profile.language.title).font(.callout).fontWeight(.medium)
                        Text(profile.language.rawValue.uppercased()).font(.system(.caption, design: .monospaced)).foregroundStyle(ConsoleTheme.secondaryText)
                        Spacer()
                        Button { removing = profile.language } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(ConsoleTheme.secondaryText)
                            .disabled(model.preferences.profiles.count == 1)
                            .accessibilityLabel("Remove \(profile.language.title)")
                    }
                    if model.engineSettings.source == .server {
                        ModelSelectionField(title: "\(profile.language.title) dictation model", selection: Binding(get: {
                            model.preferences.profile(for: profile.language)?.dictationModel ?? profile.dictationModel
                        }, set: { value in model.preferences.update(profile.language) { $0.dictationModel = value } }), models: models)
                        if checked && !models.contains(where: { $0.id == profile.dictationModel }) {
                            Text("This model was not reported by the server. Check the model ID and server configuration.").font(.caption).foregroundStyle(.orange)
                        }
                    } else if LocalSpeechModel.languageCode(profile.language.rawValue) == nil {
                        Text("Whisper does not support this language. Switch to a server to use it.").font(.caption).foregroundStyle(.orange)
                    }
                    if profile.holdShortcut == nil && profile.effectiveHandsFreeShortcut == nil {
                        Button("Set \(profile.language.title) shortcuts…") { model.showLanguageSettings(profile.language) }.font(.caption)
                    }
                }
                if profile.id != model.preferences.profiles.last?.id { Divider() }
            }
            Button { adding = true } label: { Label("Add language", systemImage: "plus") }
        }
        .disabled(model.phase != .idle)
        .sheet(isPresented: $adding) { AddLanguageView(model: model, models: models) }
        .confirmationDialog("Remove \(removing?.title ?? "language")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            if let language = removing {
                Button("Remove language", role: .destructive) {
                    guard model.phase == .idle, model.preferences.profiles.count > 1 else { return }
                    model.preferences.profiles.removeAll { $0.language == language }
                    removing = nil
                }
            }
        } message: { Text("This removes its shortcuts and configuration. Saved transcripts and dictionary entries stay available.") }
    }
}

struct AddLanguageView: View {
    @ObservedObject var model: AppModel
    let models: [ReportedModel]
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var code = ""
    @State private var modelID = ""
    private var language: DictationLanguage { DictationLanguage(rawValue: code) }
    private var available: [DictationLanguage] {
        Locale.LanguageCode.isoLanguageCodes.map { DictationLanguage(rawValue: $0.identifier) }
            .filter { model.engineSettings.source == .server || LocalSpeechModel.languageCode($0.rawValue) != nil }
            .filter { !model.preferences.languages.contains($0) && (query.isEmpty || $0.title.localizedStandardContains(query) || $0.rawValue.localizedStandardContains(query)) }
            .sorted { $0.title < $1.title }
    }
    private var canAdd: Bool {
        language.isValid && !model.preferences.languages.contains(language) && (model.engineSettings.source == .onDevice ? LocalSpeechModel.languageCode(code) != nil : ModelID.isValid(modelID.trimmingCharacters(in: .whitespacesAndNewlines))) && model.phase == .idle
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add language").font(.title2).fontWeight(.semibold)
            TextField("Search languages", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(available) { item in
                        Button {
                            code = item.rawValue
                            if let suggested = models.first(where: { $0.language == code }) { modelID = suggested.id }
                        } label: {
                            HStack {
                                Text(item.title)
                                Spacer()
                                Text(item.rawValue).font(.system(.caption, design: .monospaced)).foregroundStyle(ConsoleTheme.secondaryText)
                                if code == item.rawValue { Image(systemName: "checkmark") }
                            }.padding(8).contentShape(Rectangle())
                                .background(code == item.rawValue ? ConsoleTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(height: 180).padding(4).consoleCard()
            HStack {
                Text("Language code")
                TextField("e.g. ja or zh-cn", text: $code)
                    .textFieldStyle(.roundedBorder).onChange(of: code) { _, value in code = value.lowercased().replacingOccurrences(of: "_", with: "-").trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            if model.preferences.languages.contains(language) {
                Text("This language is already configured.").font(.caption).foregroundStyle(.orange)
            } else if !code.isEmpty && !language.isValid {
                Text("Use a language code such as ja, fr, or zh-cn.").font(.caption).foregroundStyle(.orange)
            }
            if model.engineSettings.source == .server {
            Text("Dictation model").font(.callout).fontWeight(.medium)
            HStack {
                TextField("Model ID on your server", text: $modelID).textFieldStyle(.roundedBorder)
                if !models.isEmpty {
                    Menu("Choose…") { ForEach(models) { item in Button(item.id) { modelID = item.id } } }.fixedSize()
                }
            }
            Text("Adding a language does not install a model. Set its shortcuts in Settings after adding it.").font(.caption).foregroundStyle(ConsoleTheme.secondaryText)
            } else {
                Text("Uses the selected local Whisper model. Set this language's shortcuts in Settings.").font(.caption).foregroundStyle(ConsoleTheme.secondaryText)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add language") {
                    guard canAdd else { return }
                    var profile = LanguageProfile(language: language, dictationModel: modelID.trimmingCharacters(in: .whitespacesAndNewlines))
                    profile.holdShortcut = nil; profile.handsFreeShortcut = nil
                    model.preferences.profiles.append(profile)
                    dismiss()
                }.disabled(!canAdd)
            }
        }.padding(24).frame(width: 440).background(ConsoleTheme.paper).tint(ConsoleTheme.control)
    }
}
