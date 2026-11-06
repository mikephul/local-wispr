import Foundation

enum CleanupStyle: String, Codable, CaseIterable {
    case raw, light, polished
    var title: String { rawValue.capitalized }
    var explanation: String {
        switch self {
        case .raw: return "Skips Polish. Exact dictionary corrections still apply."
        case .light: return "Fix punctuation and fillers, keeping your wording."
        case .polished: return "Also improve grammar and flow, keeping your meaning."
        }
    }
}
enum RecordingMode: String, Codable, CaseIterable {
    case hold, toggle
    var title: String { self == .hold ? "Push to talk" : "Hands-free" }
    enum Action: Equatable { case begin, finish, ignore }
    func action(down: Bool, recording: Bool, sameLanguage: Bool) -> Action {
        if !recording { return down ? .begin : .ignore }
        guard sameLanguage else { return .ignore }
        return (self == .toggle ? down : !down) ? .finish : .ignore
    }
}
struct DictionaryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var language: DictationLanguage
    var heard: String
    var replacement: String
}
struct TranscriptRevision: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var text: String
    var style: CleanupStyle
    var cleaned: Bool
    var cleanupSeconds: Double
}

struct Transcript: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var language: DictationLanguage
    var raw: String
    var text: String
    var style: CleanupStyle
    var cleaned: Bool
    var speechSeconds: Double
    var cleanupSeconds: Double
    var revisions: [TranscriptRevision]?
    private var revision: TranscriptRevision { TranscriptRevision(text: text, style: style, cleaned: cleaned, cleanupSeconds: cleanupSeconds) }
    mutating func revise(text: String, style: CleanupStyle, cleaned: Bool, seconds: Double) {
        revisions = Array(([revision] + (revisions ?? [])).prefix(5))
        self.text = text; self.style = style; self.cleaned = cleaned; cleanupSeconds = seconds
    }
    mutating func restore(_ revisionID: UUID) {
        guard let selected = revisions?.first(where: { $0.id == revisionID }) else { return }
        let previous = revision
        revisions = Array(([previous] + (revisions ?? []).filter { $0.id != revisionID }).prefix(5))
        text = selected.text; style = selected.style; cleaned = selected.cleaned; cleanupSeconds = selected.cleanupSeconds
    }
    func matches(_ query: String) -> Bool {
        query.isEmpty || raw.localizedStandardContains(query) || text.localizedStandardContains(query)
    }
}
struct LibraryData: Codable {
    var transcripts: [Transcript] = []
    var dictionary: [DictionaryEntry] = []
    var retentionDays = 30
    mutating func prune(now: Date = Date()) {
        guard retentionDays > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)
        transcripts.removeAll { $0.date < cutoff }
    }
}
@MainActor final class LibraryStore: ObservableObject {
    @Published private(set) var data: LibraryData
    @Published private(set) var error: String?
    private(set) var canWrite = true
    let url: URL
    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LocalSTT/library.json")) {
        self.url = url
        do {
            data = try JSONDecoder().decode(LibraryData.self, from: Data(contentsOf: url))
        } catch {
            data = LibraryData()
            if FileManager.default.fileExists(atPath: url.path) {
                canWrite = false
                self.error = "Could not read the local library. The original file has been kept. \(error.localizedDescription)"
            }
        }
        if error == nil { prune() }
    }
    @discardableResult func update(_ change: (inout LibraryData) -> Void) -> Bool {
        guard canWrite else { return false }
        var next = data
        change(&next)
        next.prune()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: url, options: .atomic)
            data = next
            error = nil
            return true
        } catch { self.error = "Could not save the local library: \(error.localizedDescription)"; return false }
    }
    func prune() {
        var next = data; next.prune()
        if next.transcripts.count != data.transcripts.count { update { $0 = next } }
    }
    func add(_ transcript: Transcript) { update { $0.transcripts.insert(transcript, at: 0) } }
}
