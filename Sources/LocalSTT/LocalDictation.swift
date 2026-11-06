import Foundation
import CryptoKit
import WhisperKit
import Tokenizers

// Server settings remain independent when switching to on-device dictation.
struct DictationEngineSettings: Codable, Equatable {
    enum Source: String, Codable, CaseIterable { case server, onDevice }
    var source: Source = .server
    var model: LocalSpeechModel = .base
    var serverPolish = false
    static func load(_ defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: "dictationEngine"), let settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return settings
    }
    func style(_ selected: CleanupStyle) -> CleanupStyle {
        source == .onDevice && !serverPolish ? .raw : selected
    }
}

enum LocalSpeechModel: String, Codable, CaseIterable, Identifiable {
    case base, small
    var id: String { rawValue }
    var title: String { "Whisper " + rawValue.capitalized }
    var detail: String { self == .base ? "Fast and compact · multilingual · 150 MB" : "Better accuracy · multilingual · 490 MB" }
    static var supported: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }
    static func languageCode(_ code: String) -> String? {
        let code = code.lowercased().split(separator: "-").first.map(String.init) ?? code
        return code != "yue" && Constants.languages.values.contains(code) ? code : nil
    }
}

struct LocalModelFile: Decodable {
    let path: String
    let url: URL
    let bytes: Int64
    let sha256: String
}

enum LocalModelError: LocalizedError {
    case unsupported, missing, corrupt, busy, unsupportedLanguage
    var errorDescription: String? {
        switch self {
        case .unsupported: return "On-device Dictation requires an Apple silicon Mac. You can use a server on this Mac instead."
        case .missing: return "Download a speech model in LLM → On this Mac first."
        case .corrupt: return "The model files are incomplete or damaged. Remove the model and download it again."
        case .busy: return "The local model is still finishing its previous operation. Try again shortly."
        case .unsupportedLanguage: return "This language is not supported by Whisper. Use a server model for this language."
        }
    }
}

struct LocalModelFiles {
    let root: URL
    static var applicationRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LocalSTT/Models", isDirectory: true)
    }
    static let catalog: [String: [LocalModelFile]] = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "LocalModels", withExtension: "json"), let data = try? Data(contentsOf: url), let catalog = try? JSONDecoder().decode([String: [LocalModelFile]].self, from: data) else { return [:] }
        return catalog
    }()
    func folder(_ model: LocalSpeechModel) -> URL { root.appendingPathComponent(model.rawValue, isDirectory: true) }
    func isInstalled(_ model: LocalSpeechModel) -> Bool {
        let directory = folder(model)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready").path), let files = Self.catalog[model.rawValue], !files.isEmpty else { return false }
        return files.allSatisfy { file in
            let size = (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(file.path).path)[.size]) as? NSNumber
            return size?.int64Value == file.bytes
        }
    }
    static func verify(_ url: URL, file: LocalModelFile) throws {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256(); var count: Int64 = 0
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            count += Int64(chunk.count); hash.update(data: chunk)
        }
        guard count == file.bytes, hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else { throw LocalModelError.corrupt }
    }
}

struct LocalSpeechTimings {
    var verification: Double = 0
    var loading: Double = 0
    var decoding: Double = 0
}

// Only explicit downloads use the network. Inference constructs its tokenizer from local files.
actor LocalSpeechEngine {
    let files: LocalModelFiles
    private var active = false
    private(set) var timings = LocalSpeechTimings()
    private var cached: (model: LocalSpeechModel, kit: WhisperKit)?
    private var loading: (model: LocalSpeechModel, id: UUID, task: Task<WhisperKit, Error>)?
    private var idleRelease: Task<Void, Never>?
    private let idleSeconds: Double
    private(set) var modelLoadCount = 0
    var loadedModelID: LocalSpeechModel? { cached?.model }
    init(root: URL = LocalModelFiles.applicationRoot, idleSeconds: Double = 300) {
        files = LocalModelFiles(root: root)
        self.idleSeconds = idleSeconds
    }

    func prepare(_ model: LocalSpeechModel) async throws {
        guard !active else { return }
        idleRelease?.cancel()
        _ = try await loadedModel(model, preparing: true)
        if !active { scheduleRelease() }
    }

    private func loadedModel(_ model: LocalSpeechModel, preparing: Bool = false) async throws -> WhisperKit {
        if preparing && active { throw LocalModelError.busy }
        guard files.isInstalled(model) else { throw LocalModelError.missing }
        if let cached, cached.model == model { return cached.kit }
        if let loading {
            // A short recording can finish before background preparation does.
            // Join that load instead of opening a second model or failing as busy.
            let kit = try await loading.task.value
            if self.loading?.id == loading.id {
                cached = (loading.model, kit); self.loading = nil
            }
            try Task.checkCancellation()
            if loading.model == model { return kit }
            return try await loadedModel(model, preparing: preparing)
        }
        let previous = cached; cached = nil
        if let previous { await previous.kit.unloadModels() }
        // Unloading suspends this actor; another caller may have started the load.
        if preparing && active { throw LocalModelError.busy }
        if loading != nil || cached != nil { return try await loadedModel(model, preparing: preparing) }
        let folder = files.folder(model)
        let id = UUID()
        let task = Task { () throws -> WhisperKit in
            let started = ProcessInfo.processInfo.systemUptime
            for entry in LocalModelFiles.catalog[model.rawValue] ?? [] {
                try LocalModelFiles.verify(folder.appendingPathComponent(entry.path), file: entry)
            }
            timings.verification = ProcessInfo.processInfo.systemUptime - started
            let loadStart = ProcessInfo.processInfo.systemUptime
            let kit = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, verbose: false, prewarm: false, load: false, download: false))
            do {
                let tokenizer = try await AutoTokenizer.from(modelFolder: folder)
                kit.tokenizer = try OfflineWhisperTokenizer(tokenizer)
                kit.textDecoder.isModelMultilingual = true
                try await kit.loadModels()
                timings.loading = ProcessInfo.processInfo.systemUptime - loadStart
                modelLoadCount += 1
                return kit
            } catch {
                await kit.unloadModels()
                throw error
            }
        }
        loading = (model, id, task)
        do {
            let kit = try await task.value
            if loading?.id == id { cached = (model, kit); loading = nil }
            try Task.checkCancellation()
            return kit
        } catch {
            if loading?.id == id { loading = nil }
            throw error
        }
    }

    private func scheduleRelease() {
        idleRelease?.cancel()
        idleRelease = Task { [weak self, idleSeconds] in
            do { try await Task.sleep(for: .seconds(idleSeconds)) } catch { return }
            guard let self else { return }
            await self.releaseIfIdle()
        }
    }

    func releaseIfIdle() async {
        guard !active, loading == nil else { return }
        idleRelease?.cancel(); idleRelease = nil
        let previous = cached; cached = nil
        if let previous { await previous.kit.unloadModels() }
    }

    func install(_ model: LocalSpeechModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !active, loading == nil else { throw LocalModelError.busy }
        active = true; defer { active = false }
        idleRelease?.cancel()
        let previous = cached; cached = nil
        if let previous { await previous.kit.unloadModels() }
        guard LocalSpeechModel.supported else { throw LocalModelError.unsupported }
        guard let manifest = LocalModelFiles.catalog[model.rawValue], !manifest.isEmpty else { throw LocalModelError.corrupt }
        let directory = files.folder(model)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("ready"))
        let total = Double(manifest.reduce(Int64(0)) { $0 + $1.bytes })
        var completed: Int64 = 0
        for file in manifest {
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent(file.path)
            if (try? LocalModelFiles.verify(destination, file: file)) == nil {
                let previous = completed
                let temporary = try await ModelDownload().fetch(file.url, expected: file.bytes) { bytes in progress(Double(previous + bytes) / total) }
                defer { try? FileManager.default.removeItem(at: temporary) }
                try LocalModelFiles.verify(temporary, file: file)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            completed += file.bytes; progress(Double(completed) / total)
        }
        try Task.checkCancellation()
        try Data("1".utf8).write(to: directory.appendingPathComponent("ready"), options: .atomic)
    }

    func remove(_ model: LocalSpeechModel) async throws {
        guard !active, loading == nil else { throw LocalModelError.busy }
        active = true; defer { active = false; scheduleRelease() }
        if cached?.model == model {
            let previous = cached; cached = nil
            if let previous { await previous.kit.unloadModels() }
        }
        let folder = files.folder(model)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }

    func transcribe(file: URL, model: LocalSpeechModel, language: String) async throws -> String {
        guard !active else { throw LocalModelError.busy }
        active = true
        idleRelease?.cancel()
        defer { active = false; scheduleRelease() }
        guard LocalSpeechModel.supported else { throw LocalModelError.unsupported }
        guard let code = LocalSpeechModel.languageCode(language) else { throw LocalModelError.unsupportedLanguage }
        timings = LocalSpeechTimings()
        let kit = try await loadedModel(model)
        try Task.checkCancellation()
        let options = DecodingOptions(language: code, temperatureFallbackCount: 2, skipSpecialTokens: true)
        let decodeStart = ProcessInfo.processInfo.systemUptime
        let result = try await kit.transcribe(audioPath: file.path, decodeOptions: options)
        timings.decoding = ProcessInfo.processInfo.systemUptime - decodeStart
        try Task.checkCancellation()
        return result.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class ModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private var cancelled = false
    private var expected: Int64 = 0
    private var progress: (@Sendable (Int64) -> Void)?
    private var session: URLSession?
    func fetch(_ url: URL, expected: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation; self.expected = expected; self.progress = progress
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 1800
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.downloadTask(with: url); self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.lock.lock(); self.cancelled = true; let task = self.task; self.lock.unlock()
            task?.cancel()
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > expected { downloadTask.cancel(); return }
        progress?(totalBytesWritten)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { throw ServiceError.server }
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("local-wispr-model-\(UUID())")
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch { finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
    private func finish(_ result: Result<URL, Error>) {
        lock.lock(); let continuation = self.continuation; self.continuation = nil; let session = self.session; self.session = nil; lock.unlock()
        continuation?.resume(with: result)
        session?.finishTasksAndInvalidate()
    }
}

private struct OfflineWhisperTokenizer: WhisperTokenizer {
    let tokenizer: any Tokenizer
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>
    init(_ tokenizer: any Tokenizer) throws {
        func token(_ text: String) throws -> Int {
            guard let value = tokenizer.convertTokenToId(text) else { throw LocalModelError.corrupt }
            return value
        }
        self.tokenizer = tokenizer
        specialTokens = try SpecialTokens(
            endToken: token("<|endoftext|>"), englishToken: token("<|en|>"),
            noSpeechToken: token("<|nospeech|>"), noTimestampsToken: token("<|notimestamps|>"),
            specialTokenBegin: token("<|endoftext|>"), startOfPreviousToken: token("<|startofprev|>"),
            startOfTranscriptToken: token("<|startoftranscript|>"), timeTokenBegin: token("<|0.00|>"),
            transcribeToken: token("<|transcribe|>"), translateToken: token("<|translate|>"), whitespaceToken: 220)
        allLanguageTokens = Set(Constants.languages.values.compactMap { tokenizer.convertTokenToId("<|\($0)|>") })
    }
    func encode(text: String) -> [Int] { tokenizer.encode(text: text) }
    func decode(tokens: [Int]) -> String { tokenizer.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { tokenizer.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { tokenizer.convertIdToToken(id) }
    // Dictation requests no word timestamps, so the transcript stays one token group.
    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        ([decode(tokens: tokenIds)], [tokenIds])
    }
}
