import SwiftUI
import AppKit

struct AppHomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var library: LibraryStore
    @State private var query = ""
    @State private var expanded: UUID?
    @State private var copied: UUID?
    @State private var hovered: UUID?
    @State private var deleteItem: Transcript?

    init(model: AppModel) {
        self.model = model
        self.library = model.library
    }
    private var filtered: [Transcript] { library.data.transcripts.filter { $0.matches(query.trimmingCharacters(in: .whitespacesAndNewlines)) } }
    private struct Day: Identifiable {
        let id: Date
        let entries: [Transcript]
    }
    private var days: [Day] {
        Dictionary(grouping: filtered, by: { Calendar.current.startOfDay(for: $0.date) })
            .map { Day(id: $0.key, entries: $0.value.sorted { $0.date > $1.date }) }.sorted { $0.id > $1.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ConsoleHeader(title: "Dictation", subtitle: "Hold to talk, or double-tap for hands-free.", accessory: AnyView(
                InstrumentView(model: model).scaleEffect(0.7).frame(width: 98, height: 31)
            ))
            if model.phase != .idle || model.status != "Ready." { statusBar }
            if let problem = model.microphoneProblem {
                HStack {
                    Label(problem.localizedDescription, systemImage: "mic.slash").font(.callout).foregroundStyle(.orange)
                    Spacer()
                    Button("Microphone settings") { model.showSettings() }
                }.padding(12).consoleCard()
            }
            if let error = library.error {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).font(.caption).foregroundStyle(.red)
                    if !model.latest.isEmpty {
                        Text(model.latest).textSelection(.enabled)
                        Button("Copy unsaved result") { model.copyLatest() }
                    }
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(ConsoleTheme.secondaryText)
                TextField("Search your dictations", text: $query).textFieldStyle(.plain)
                    .accessibilityLabel("Search dictations")
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear search") }
                Spacer(minLength: 0)
                Button { model.showHistorySettings() } label: { Image(systemName: "clock.arrow.circlepath").frame(width: 28, height: 28) }
                    .buttonStyle(.plain).help("History settings").accessibilityLabel("History settings")
            }.padding(12).background(ConsoleTheme.screen, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ConsoleTheme.edge, lineWidth: 0.75))
            GeometryReader { area in
                HStack(alignment: .top, spacing: 20) {
                    feed.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if area.size.width >= 820 { summary.frame(width: 150) }
                }
            }
        }
        .padding(30).background(ConsoleTheme.paper)
        .onAppear { library.prune() }
        .task(id: copied) {
            guard copied != nil else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copied = nil
        }
        .confirmationDialog("Delete this dictation?", isPresented: Binding(get: { deleteItem != nil }, set: { if !$0 { deleteItem = nil } })) {
            if let item = deleteItem {
                Button("Delete dictation", role: .destructive) { library.update { $0.transcripts.removeAll { $0.id == item.id } }; deleteItem = nil }
            }
        } message: { Text("The original and cleaned text will both be removed.") }
    }
    private var statusBar: some View {
        HStack(spacing: 10) {
            Image(systemName: model.phase == .failed ? "exclamationmark.circle" : model.phase == .recording ? "waveform" : "circle.dotted")
                .foregroundStyle(model.phase == .failed ? Color.orange : ConsoleTheme.control)
            Text(model.status).font(.caption).foregroundStyle(ConsoleTheme.secondaryText).frame(maxWidth: .infinity, alignment: .leading)
            if model.phase == .failed {
                Button(model.retryTitle) { model.retry() }
                Button("Discard") { model.cancel() }
            } else if model.phase != .idle {
                if model.phase == .recording && model.sessionMode == .toggle { Button("Stop") { model.finish() } }
                Button("Cancel") { model.cancel() }
            }
        }.padding(12).background(ConsoleTheme.sidebar.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }
    private var feed: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if filtered.isEmpty {
                    ConsoleEmptyState(title: query.isEmpty ? "Your words start here" : "No matching dictations", symbol: query.isEmpty ? "waveform" : "text.magnifyingglass", detail: query.isEmpty ? "Use a shortcut from the sidebar to dictate. Your transcripts will appear here." : "Try a word from the original or cleaned text.")
                }
                ForEach(days) { day in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(dayTitle(day.id).uppercased()).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.2).foregroundStyle(ConsoleTheme.secondaryText)
                        VStack(spacing: 0) {
                            ForEach(day.entries) { item in
                                transcriptRow(item)
                                if item.id != day.entries.last?.id { Divider() }
                            }
                        }.clipShape(RoundedRectangle(cornerRadius: 10)).consoleCard()
                    }
                }
            }.padding(.bottom, 20)
        }
    }
    private func transcriptRow(_ item: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(item.date, format: .dateTime.hour().minute()).font(.system(size: 11, design: .monospaced)).foregroundStyle(ConsoleTheme.secondaryText)
                    Text(item.language.rawValue.uppercased()).font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(model.preferences.waveColor(for: item.language).color)
                }.frame(width: 58, alignment: .leading)
                Text(item.text).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled).lineLimit(expanded == item.id ? nil : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 2) {
                    Button { expanded = expanded == item.id ? nil : item.id } label: {
                        Image(systemName: expanded == item.id ? "chevron.up" : "chevron.down").frame(width: 28, height: 28).contentShape(Rectangle())
                    }.help(expanded == item.id ? "Hide details" : "Show full text and original")
                        .accessibilityLabel(expanded == item.id ? "Hide details" : "Show full text and original")
                    Button {
                        copy(item.text); copied = item.id
                    } label: { Image(systemName: copied == item.id ? "checkmark" : "doc.on.doc").frame(width: 28, height: 28).contentShape(Rectangle()) }
                    .help(copied == item.id ? "Copied" : "Copy text").accessibilityLabel(copied == item.id ? "Copied" : "Copy text")
                    Menu {
                        Menu("Re-Polish") {
                            Button("Light") { model.repolish(item.id, style: .light) }
                            Button("Polished") { model.repolish(item.id, style: .polished) }
                        }.disabled(model.phase != .idle || !library.canWrite || (model.engineSettings.source == .onDevice && !model.engineSettings.serverPolish))
                        Button("Copy original") { copy(item.raw) }
                        Divider()
                        Button("Delete dictation…", role: .destructive) { deleteItem = item }
                    } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Dictation actions")
                }.buttonStyle(.plain).foregroundStyle(ConsoleTheme.secondaryText)
            }
            if expanded == item.id {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ORIGINAL TRANSCRIPT").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1).foregroundStyle(ConsoleTheme.secondaryText)
                    Text(item.raw).font(.callout).textSelection(.enabled)
                    Text(String(format: "%@ · Dictation %.1fs · Polish %.1fs", item.style.title, item.speechSeconds, item.cleanupSeconds)).font(.caption).foregroundStyle(ConsoleTheme.secondaryText)
                    if let revisions = item.revisions, !revisions.isEmpty {
                        DisclosureGroup("Previous versions (\(revisions.count))") {
                            ForEach(revisions) { revision in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(revision.text).font(.callout).textSelection(.enabled)
                                    HStack {
                                        Text(revision.style.title).font(.caption).foregroundStyle(ConsoleTheme.secondaryText)
                                        Spacer()
                                        Button("Restore this version") { model.restoreRevision(revision.id, transcriptID: item.id) }
                                            .disabled(model.phase != .idle || !library.canWrite)
                                    }
                                }.padding(.vertical, 6)
                            }
                        }
                    }
                    if item.style != .raw && !item.cleaned { Text("Polish was unavailable. Dictionary-corrected text was kept.").font(.caption).foregroundStyle(ConsoleTheme.secondaryText) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(ConsoleTheme.sidebar.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            }
        }.padding(16)
            .background(hovered == item.id ? ConsoleTheme.sidebar.opacity(0.4) : .clear)
            .onHover { hovered = $0 ? item.id : nil }
    }
    private var summary: some View {
        VStack(alignment: .leading, spacing: 20) {
            metric(library.data.transcripts.count, "saved dictations")
            metric(library.data.transcripts.filter { Calendar.current.isDateInToday($0.date) }.count, "today")
            Divider()
            ForEach(Array(Set(model.preferences.languages + library.data.transcripts.map(\.language))).sorted { $0.title < $1.title }, id: \.self) { language in
                HStack {
                    Circle().fill(model.preferences.waveColor(for: language).color).frame(width: 6, height: 6)
                    Text(language.title).font(.caption)
                    Spacer()
                    Text("\(library.data.transcripts.filter { $0.language == language }.count)").font(.system(.caption, design: .monospaced))
                }
            }
            Divider()
            Text(library.data.retentionDays == 0 ? "History kept until you delete it." : "History kept for \(library.data.retentionDays) days.").font(.caption).foregroundStyle(ConsoleTheme.secondaryText)
        }.padding(18).consoleCard()
    }
    private func metric(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)").font(.system(size: 24, weight: .regular, design: .monospaced))
            Text(label).font(.caption).foregroundStyle(ConsoleTheme.secondaryText)
        }
    }
    private func dayTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}

struct HistorySettingsSection: View {
    @ObservedObject var library: LibraryStore
    @State private var pendingDays: Int?
    @State private var clearConfirmation = false
    var body: some View {
        Section("Dictation history") {
            Picker("Keep text", selection: Binding(get: { library.data.retentionDays }, set: { days in
                var next = library.data; next.retentionDays = days; next.prune()
                if next.transcripts.count < library.data.transcripts.count { pendingDays = days }
                else { library.update { $0.retentionDays = days } }
            })) {
                Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90); Text("Forever").tag(0)
            }
            Text("Search and copy saved transcripts on the Dictation page. History is stored on this Mac.").font(.caption).foregroundStyle(ConsoleTheme.secondaryText)
            Button("Clear history…", role: .destructive) { clearConfirmation = true }.disabled(library.data.transcripts.isEmpty)
            if let error = library.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .confirmationDialog("Delete older dictations?", isPresented: Binding(get: { pendingDays != nil }, set: { if !$0 { pendingDays = nil } })) {
            if let days = pendingDays {
                Button("Keep only the last \(days) days", role: .destructive) { library.update { $0.retentionDays = days }; pendingDays = nil }
            }
        } message: { Text("Transcripts older than the selected period will be permanently removed.") }
        .confirmationDialog("Delete all saved transcripts?", isPresented: $clearConfirmation) {
            Button("Delete all", role: .destructive) { library.update { $0.transcripts.removeAll() } }
        } message: { Text("This cannot be undone. Dictionary entries will stay.") }
    }
}
