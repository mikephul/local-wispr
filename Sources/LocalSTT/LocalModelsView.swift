import SwiftUI

@MainActor
final class LocalModelStore: ObservableObject {
    @Published private(set) var installed: Set<LocalSpeechModel> = []
    @Published private(set) var working: LocalSpeechModel?
    @Published private(set) var progress: Double = 0
    @Published private(set) var message = ""
    @Published private(set) var cancelling = false
    @Published private(set) var preparing: LocalSpeechModel?
    private var prepareTask: Task<Void, Never>?
    let engine: LocalSpeechEngine
    private let files: LocalModelFiles
    private var task: Task<Void, Never>?
    init(root: URL = LocalModelFiles.applicationRoot) {
        files = LocalModelFiles(root: root)
        engine = LocalSpeechEngine(root: root)
        refresh()
    }
    func refresh() { installed = Set(LocalSpeechModel.allCases.filter { files.isInstalled($0) }) }
    func prepare(_ model: LocalSpeechModel) {
        guard working == nil, installed.contains(model), preparing != model else { return }
        prepareTask?.cancel()
        preparing = model
        message = "Preparing \(model.title) for fast dictation…"
        prepareTask = Task {
            do {
                try await engine.prepare(model)
                guard !Task.isCancelled else { return }
                message = "\(model.title) ready. Kept in memory for five idle minutes."
            } catch {
                guard !Task.isCancelled else { return }
                message = "Model will prepare when you next dictate."
            }
            preparing = nil; prepareTask = nil
        }
    }
    func install(_ model: LocalSpeechModel) {
        guard working == nil else { return }
        working = model; progress = 0; message = "Downloading from Hugging Face…"; cancelling = false
        task = Task {
            do {
                try await engine.install(model) { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.working == model, !self.cancelling else { return }
                        self.progress = value
                    }
                }
                try Task.checkCancellation()
                message = "\(model.title) is ready. Audio stays on this Mac."
            } catch {
                message = Task.isCancelled ? "Download cancelled. Completed files are kept for the next attempt." : "Download failed: \(error.localizedDescription) Try again to reuse verified files."
            }
            refresh(); working = nil; cancelling = false; task = nil
            if installed.contains(model) { prepare(model) }
        }
    }
    func cancel() { cancelling = true; message = "Cancelling download…"; task?.cancel() }
    func remove(_ model: LocalSpeechModel) {
        guard working == nil else { return }
        working = model; message = "Removing model…"
        task = Task {
            do { try await engine.remove(model); message = "\(model.title) removed." }
            catch { message = error.localizedDescription }
            refresh(); working = nil; task = nil
        }
    }
}

struct LocalModelsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: LocalModelStore
    @State private var removing: LocalSpeechModel?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Dictation on this Mac", systemImage: "desktopcomputer").font(.headline)
            Text("Download once, then dictate without a server or internet. These models support multiple languages. Base is faster; Small is a better choice when accuracy matters.")
                .font(.callout).foregroundStyle(ConsoleTheme.secondaryText)
            if !LocalSpeechModel.supported {
                Text(LocalModelError.unsupported.localizedDescription).foregroundStyle(.orange)
            }
            ForEach(LocalSpeechModel.allCases) { item in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.callout).fontWeight(.semibold)
                            Text(item.detail).font(.caption).foregroundStyle(ConsoleTheme.secondaryText)
                        }
                        Spacer()
                        if store.installed.contains(item) {
                            if store.preparing == item {
                                ProgressView().controlSize(.small)
                                Text("Preparing…").font(.caption)
                            } else if model.engineSettings.model == item {
                                Label("Selected", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(ConsoleTheme.control)
                            } else {
                                Button("Use model") { model.engineSettings.model = item }
                            }
                            Button { removing = item } label: { Image(systemName: "trash") }
                                .accessibilityLabel("Remove \(item.title)").disabled(store.preparing != nil)
                        } else if store.working == item {
                            Button(store.cancelling ? "Cancelling…" : "Cancel") { store.cancel() }.disabled(store.cancelling)
                        } else {
                            Button("Download") { model.engineSettings.model = item; store.install(item) }
                                .disabled(store.working != nil || store.preparing != nil || !LocalSpeechModel.supported)
                        }
                    }
                    if store.working == item {
                        ProgressView(value: store.progress)
                        Text("\(Int(store.progress * 100))% · \(store.message)").font(.caption).foregroundStyle(ConsoleTheme.secondaryText)
                    }
                }
                if item != LocalSpeechModel.allCases.last { Divider() }
            }
            if store.working == nil && !store.message.isEmpty {
                Text(store.message).font(.caption).foregroundStyle(ConsoleTheme.secondaryText)
            }
            Text("Downloads are checked against SHA-256 hashes. You can cancel, retry, or remove models here. The selected model stays ready in memory and unloads after five idle minutes.")
                .font(.caption).foregroundStyle(ConsoleTheme.secondaryText)
            Divider()
            LanguageModelsView(model: model, models: [], checked: false)
        }
        .padding(18).consoleCard().disabled(model.phase != .idle)
        .confirmationDialog("Remove \(removing?.title ?? "model")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            if let item = removing {
                Button("Remove download", role: .destructive) { guard model.phase == .idle else { return }; store.remove(item); removing = nil }
            }
        } message: { Text("You will need to download it again before using it. Your transcripts and server settings will stay available.") }
    }
}
