import AppKit
import AVFoundation
import SwiftUI
import ServiceManagement
import Combine

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable { case idle, recording, transcribing, cleaning, pasting, failed }
    @Published var phase: Phase = .idle
    @Published var level: Double = 0
    @Published var feedback: DictationFeedback?
    @Published var recoveryNotice: String?
    @Published var status = "Ready." { didSet { writeDiagnostics() } }
    @Published var appearance: ConsoleAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: "appearance")
            NSApplication.shared.appearance = appearance.native
        }
    }
    @Published var polishPrompts: PolishPrompts {
        didSet {
            if let data = try? JSONEncoder().encode(polishPrompts) { defaults.set(data, forKey: "polishPrompts") }
        }
    }
    @Published var latest = ""
    @Published var repolishingID: UUID?
    var backendFactory: (String) -> Backend = { Backend(host: $0) }
    let localModels: LocalModelStore
    var localTranscribe: ((URL, LocalSpeechModel, String) async throws -> String)?
    @Published var engineSettings: DictationEngineSettings {
        didSet {
            if let data = try? JSONEncoder().encode(engineSettings) { defaults.set(data, forKey: "dictationEngine") }
            healthTask?.cancel(); checkingHealth = false; checkedHost = ""; healthDate = nil
            if engineSettings.source == .onDevice { self.localModels.prepare(engineSettings.model) }
            else { Task { await localModels.engine.releaseIfIdle() } }
        }
    }
    @Published var host: String { didSet { defaults.set(host, forKey: "host") } }
    @Published var preferences: DictationPreferences {
        didSet {
            if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: "dictationPreferences") }
            if oldValue.shortcuts != preferences.shortcuts {
                monitor.shortcuts = preferences.shortcuts
                handsFreeTrigger.reset()
                sharedGesture.reset()
                verifiedHotkeys.removeAll()
            }
            stopHotkeyCheck()
            if phase == .idle && !preferences.languages.contains(activeLanguage), let first = preferences.languages.first { activeLanguage = first }
            if previewingWave { previewWave() }
        }
    }
    @Published var verifiedHotkeys = Set<ShortcutAction>()
    @Published var testAction: ShortcutAction = .englishHold
    @Published var editingShortcut: ShortcutAction?
    @Published var activeLanguage: DictationLanguage = .english
    @Published var microphoneAllowed = false
    @Published var inputAllowed = false
    @Published var accessibilityAllowed = false
    @Published var hotkeyListening = false
    @Published var hotkeyCheck = HotkeyCheck()
    var keyName: String { preferences.shortcut(for: testAction)?.title ?? "Not assigned" }
    @Published var selectedPage: AppPage? = .dictation
    @Published var settingsTarget: SettingsAnchor?
    @Published var testText = ""
    let library: LibraryStore
    @Published var microphones = Microphone.available()
    @Published private var defaultMicrophoneID = Microphone.defaultInputID()
    var microphoneProblem: MicrophoneInputError? { if recordingInput.isFixture { return nil }; return Microphone.inputProblem(uid: preferences.microphoneUID, devices: microphones, defaultID: defaultMicrophoneID) }
    private var microphoneObserver: MicrophoneObserver?
    @Published var testingMicrophone = false
    @Published var microphoneTestStatus = ""
    @Published var speechService = ServiceModels()
    @Published var cleanupService = ServiceModels()
    @Published var checkingHealth = false
    @Published var checkedHost = ""
    @Published var healthDate: Date?
    @Published var speechSeconds: Double?
    @Published var cleanupSeconds: Double?
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var loginMessage = ""
    private var healthTask: Task<Void, Never>?
    private var sessionStyle: CleanupStyle = .light
    private var sessionSkipSilence = true
    private var sessionInstruction = PolishPrompts.defaultPrompt(for: .light)
    private var sessionDictionary: [DictionaryEntry] = []
    private var handsFreeTrigger = HandsFreeTrigger()
    private var sharedGesture = SharedShortcutGesture()
    private var sessionAction: ShortcutAction = .englishHold
    var sessionMode: RecordingMode { sessionAction.mode ?? .hold }
    private var maintenanceTimer: Timer?
    private var appWindow: NSWindow?
    private var hotkeyCheckTask: Task<Void, Never>?
    private let monitor = HotkeyMonitor()
    private let monitorKeyboard: Bool
    private let defaults: UserDefaults
    private let recordingInput: RecordingInput
    var recordingFactory: ((URL?, String) throws -> any AudioRecording)?
    private var recorder: (any AudioRecording)?
    @Published private(set) var recordingInterrupted = false
    private var recordingRecovered = false
    var retryTitle: String { recordingInterrupted ? "Transcribe captured audio" : "Retry dictation" }
    private var timer: Timer?
    private var file: URL?
    private var target: PasteTarget?
    private var pasteTargetInvalidated = false
    private var session = UUID()
    private var task: Task<Void, Never>?
    private var panel: NSPanel?
    @Published var previewingWave = false
    private var wavePreviewTask: Task<Void, Never>?
    private var sessionHost = ""
    private var sessionEngine = DictationEngineSettings()
    private var sessionLanguage = "en"
    private var sessionDictationModel = ""
    private var sessionPolishModel = Backend.cleanupModel

    init(library: LibraryStore? = nil, appearance: ConsoleAppearance? = nil, monitorKeyboard: Bool = true, defaults: UserDefaults = .standard, recordingInput: RecordingInput = .microphone, localModels: LocalModelStore? = nil) {
        self.defaults = defaults
        self.localModels = localModels ?? LocalModelStore()
        self.recordingInput = recordingInput
        _engineSettings = Published(initialValue: DictationEngineSettings.load(defaults))
        _preferences = Published(initialValue: DictationPreferences.load(defaults))
        _polishPrompts = Published(initialValue: PolishPrompts.load(defaults))
        _host = Published(initialValue: defaults.string(forKey: "host") ?? "127.0.0.1")
        self.monitorKeyboard = monitorKeyboard
        self.library = library ?? LibraryStore()
        _appearance = Published(initialValue: appearance ?? ConsoleAppearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system)
        NSApplication.shared.appearance = self.appearance.native
        recoveryNotice = defaults.string(forKey: DictationPreferences.recoveryNoticeKey)
        monitor.shortcuts = preferences.shortcuts
        activeLanguage = preferences.languages.first ?? .english
        monitor.onDown = { [weak self] action, timestamp in
            guard let self else { return }
            if self.hotkeyCheck.isActive {
                if self.preferences.shortcut(for: action) == self.preferences.shortcut(for: self.testAction) { _ = self.hotkeyCheck.press() }
                return
            }
            self.handleDictationKey(action: action, down: true, now: timestamp)
        }
        monitor.onUp = { [weak self] action, timestamp in
            guard let self else { return }
            if self.hotkeyCheck.isActive {
                if self.preferences.shortcut(for: action) == self.preferences.shortcut(for: self.testAction) {
                    _ = self.hotkeyCheck.release()
                    if self.hotkeyCheck.state == .passed { self.verifiedHotkeys.insert(self.testAction) }
                }
                return
            }
            self.handleDictationKey(action: action, down: false, now: timestamp)
        }
        monitor.onCancel = { [weak self] in self?.cancelFromKeyboard() }
        monitor.onInteraction = { [weak self] in
            guard let self, self.phase == .recording || self.phase == .transcribing || self.phase == .cleaning || self.phase == .pasting else { return }
            self.pasteTargetInvalidated = true
        }
        if monitorKeyboard && !monitor.start() { status = "Open Setup & test to enable keyboard access." }
        refreshPermissions()
        microphoneObserver = MicrophoneObserver { [weak self] in self?.refreshMicrophones() }
        self.library.$data.map { $0.transcripts.first?.text ?? "" }.assign(to: &$latest)
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.library.prune() }
        }
        if engineSettings.source == .onDevice { self.localModels.prepare(engineSettings.model) }
        if CommandLine.arguments.contains("--app") {
            DispatchQueue.main.async { [weak self] in
                self?.showPage(CommandLine.arguments.contains("--llm") ? .llm : .dictation)
            }
        }
        if CommandLine.arguments.contains("--setup") {
            DispatchQueue.main.async { [weak self] in self?.showSetup() }
        }
    }

    func checkModels() {
        healthTask?.cancel()
        guard engineSettings.source == .server || engineSettings.serverPolish else {
            checkingHealth = false; checkedHost = ""; healthDate = nil
            return
        }
        let source = engineSettings.source
        let checked = host.trimmingCharacters(in: .whitespacesAndNewlines)
        checkedHost = checked; checkingHealth = true
        speechService = ServiceModels(); cleanupService = ServiceModels()
        healthTask = Task {
            let backend = Backend(host: checked)
            async let speech = source == .server ? backend.models(port: 8090) : ServiceModels()
            async let cleanup = backend.models(port: 8080)
            let results = await (speech, cleanup)
            guard !Task.isCancelled else { return }
            speechService = results.0; cleanupService = results.1
            healthDate = Date(); checkingHealth = false
        }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginMessage = SMAppService.mainApp.status == .requiresApproval ? "Allow local-wispr in System Settings → General → Login Items." : ""
        } catch { loginMessage = error.localizedDescription }
    }
    func refreshMicrophones() {
        microphones = Microphone.available()
        defaultMicrophoneID = Microphone.defaultInputID()
        if let problem = microphoneProblem, phase == .recording { recoverMicrophone(problem) }
        if let problem = microphoneProblem, testingMicrophone {
            stopMicrophoneTest()
            microphoneTestStatus = problem.localizedDescription
        }
        writeDiagnostics()
    }
    func testMicrophone() {
        if testingMicrophone { stopMicrophoneTest(); return }
        guard phase == .idle, microphoneAllowed else { requestMicrophone(); return }
        do {
            recorder = try openRecording(nil)
            testingMicrophone = true
            microphoneTestStatus = "Listening. Speak to check the level."
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.testingMicrophone, let recorder = self.recorder else { return }
                    if let error = recorder.recordingError {
                        do { if try recorder.recover() { self.microphoneTestStatus = "Microphone reconnected."; return } } catch {}
                        self.stopMicrophoneTest(); self.microphoneTestStatus = error.localizedDescription; return
                    }
                    self.level = Double(max(0, min(1, (recorder.averagePower + 55) / 45)))
                    if recorder.currentTime >= 15 { self.stopMicrophoneTest() }
                }
            }
        } catch { microphoneTestStatus = "Could not test microphone: " + error.localizedDescription }
    }
    func stopMicrophoneTest() {
        guard testingMicrophone else { return }
        timer?.invalidate(); timer = nil
        recorder?.stop(); recorder = nil
        testingMicrophone = false; level = 0
        microphoneTestStatus = "Microphone test finished."
    }

    func showApp() { showPage(.dictation) }
    func showSettings() { settingsTarget = nil; showPage(.settings) }
    func showLanguageSettings(_ language: DictationLanguage) { settingsTarget = .language(language); showPage(.settings) }
    func showHistorySettings() { settingsTarget = .history; showPage(.settings) }
    func showSetup() { showPage(.setup) }

    private func showPage(_ page: AppPage) {
        selectedPage = page
        if appWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "local-wispr"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.backgroundColor = NSColor(ConsoleTheme.paper)
            window.identifier = NSUserInterfaceItemIdentifier("main")
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AppWorkspaceView(model: self))
            window.center()
            appWindow = window
        }
        refreshPermissions()
        appWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        writeDiagnostics()
    }

    func refreshPermissions() {
        microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        inputAllowed = CGPreflightListenEventAccess()
        accessibilityAllowed = AXIsProcessTrusted()
        if monitorKeyboard && (inputAllowed || accessibilityAllowed) { _ = monitor.start() }
        hotkeyListening = monitor.isRunning
        if hotkeyListening && status == "Open Setup & test to enable keyboard access." {
            status = microphoneAllowed ? "Ready." : "Open Setup & test to enable the microphone."
        }
        if microphoneAllowed && hotkeyListening && status == "Open Setup & test to enable the microphone." {
            status = "Ready."
        }
        writeDiagnostics()
    }

    func restartApp() {
        guard phase == .idle || phase == .failed else { return }
        cancel()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--setup"]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error { self.status = "Could not restart: \(error.localizedDescription)" }
                else { NSApplication.shared.terminate(nil) }
            }
        }
    }

    func revealApp() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }

    func requestMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in self?.refreshPermissions() }
            }
        } else { openSettings("com.apple.preference.security?Privacy_Microphone") }
    }

    func requestInput() {
        _ = CGRequestListenEventAccess()
        openSettings("com.apple.preference.security?Privacy_ListenEvent")
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openSettings("com.apple.preference.security?Privacy_Accessibility")
    }

    func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:" + pane) { NSWorkspace.shared.open(url) }
    }

    func startHotkeyCheck(for action: ShortcutAction) {
        guard phase == .idle, monitor.isRunning, preferences.shortcut(for: action) != nil else { return }
        hotkeyCheckTask?.cancel()
        handsFreeTrigger.reset()
        sharedGesture.reset()
        testAction = action
        verifiedHotkeys.remove(action)
        hotkeyCheck.start()
        hotkeyCheckTask = Task {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            hotkeyCheck.timeout()
        }
    }

    func stopHotkeyCheck() { hotkeyCheckTask?.cancel(); hotkeyCheck.cancel() }

    private func writeDiagnostics() {
        let diagnostics: [String: Any] = [
            "version": AppVersion.display,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "shortcuts": Dictionary(uniqueKeysWithValues: preferences.actions.map { ($0.rawValue, preferences.shortcut(for: $0)?.title ?? "Not assigned") }),
            "activeLanguage": activeLanguage.rawValue,
            "microphoneInputs": microphones.map(\.name),
            "microphoneProblem": microphoneProblem?.localizedDescription ?? "",
            "accessibility": AXIsProcessTrusted(),
            "inputMonitoring": CGPreflightListenEventAccess(),
            "microphone": AVCaptureDevice.authorizationStatus(for: .audio).rawValue,
            "eventTap": monitor.isRunning,
            "setupWindowVisible": appWindow?.isVisible == true && selectedPage == .setup,
            "appWindowVisible": appWindow?.isVisible ?? false,
            "status": status,
            "updated": Date().timeIntervalSince1970
        ]
        if let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("localstt-diagnostics.json"), options: .atomic)
        }
    }

    func editShortcut(_ action: ShortcutAction) {
        guard phase == .idle else { return }
        stopHotkeyCheck()
        stopMicrophoneTest()
        monitor.suspended = true
        handsFreeTrigger.reset()
        sharedGesture.reset()
        editingShortcut = action
    }
    func finishEditingShortcut() {
        editingShortcut = nil
        monitor.suspended = false
    }

    private func handleDictationKey(action: ShortcutAction, down: Bool, now: TimeInterval) {
        guard editingShortcut == nil else { return }
        if action == .pasteLast { if !down { pasteLast() }; return }
        guard let language = action.language, let mode = action.mode else { return }
        if preferences.sharesShortcut(for: language) {
            guard phase == .idle || (phase == .recording && activeLanguage == language) else { return }
            handsFreeTrigger.reset()
            let holdAction = ShortcutAction.action(for: language, mode: .hold)
            switch sharedGesture.update(action: holdAction, down: down, now: now) {
            case .startHold:
                begin(action: holdAction)
                if phase != .recording { sharedGesture.reset() }
            case .startHandsFree:
                begin(action: .action(for: language, mode: .toggle))
                if phase != .recording { sharedGesture.reset() }
            case .discardTap: cancel(resetSharedGesture: false)
            case .finish: finish()
            case .none: break
            }
            return
        }
        if phase == .recording {
            handsFreeTrigger.reset()
            if mode.action(down: down, recording: true, sameLanguage: action == sessionAction) == .finish { finish() }
            return
        }
        guard phase == .idle else { handsFreeTrigger.reset(); return }
        sharedGesture.reset()
        if action.mode == .hold {
            handsFreeTrigger.reset()
            if down { begin(action: action) }
        } else if handsFreeTrigger.update(action: action, down: down, now: now) {
            begin(action: action)
        }
    }

    func begin(action: ShortcutAction) {
        guard let language = action.language else { return }
        guard phase == .idle, let profile = preferences.profile(for: language) else { return }
        guard (recordingInput.isFixture || AVCaptureDevice.authorizationStatus(for: .audio) == .authorized) else {
            status = "Microphone permission required. Open Setup & test to enable it."
            showFeedback(.permission)
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return
        }
        if engineSettings.source == .onDevice {
            guard LocalSpeechModel.supported, LocalSpeechModel.languageCode(language.rawValue) != nil else {
                status = LocalSpeechModel.supported ? LocalModelError.unsupportedLanguage.localizedDescription : LocalModelError.unsupported.localizedDescription
                showFeedback(.configuration); return
            }
            guard localModels.working == nil, localTranscribe != nil || localModels.installed.contains(engineSettings.model) else {
                status = LocalModelError.missing.localizedDescription
                showFeedback(.configuration); return
            }
        }
        guard engineSettings.source == .onDevice || ModelID.isValid(profile.dictationModel) else {
            status = "Choose a dictation model for \(language.title) in LLM."
            showFeedback(.configuration)
            return
        }
        stopMicrophoneTest()
        stopWavePreview()
        feedback = nil
        recordingInterrupted = false
        recordingRecovered = false
        session = UUID()
        target = recordingInput.isFixture ? nil : PasteTarget.capture()
        pasteTargetInvalidated = false
        sessionHost = host
        sessionEngine = engineSettings
        activeLanguage = language
        sessionLanguage = language.rawValue
        sessionDictationModel = profile.dictationModel
        sessionPolishModel = preferences.polishModel
        sessionStyle = sessionEngine.style(preferences.cleanup(for: language))
        sessionSkipSilence = preferences.skipSilence
        sessionInstruction = polishPrompts.instruction(for: sessionStyle)
        sessionAction = action
        sessionDictionary = library.data.dictionary.filter { $0.language == language }
        speechSeconds = nil; cleanupSeconds = nil
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("localstt-\(session).m4a")
        file = url
        do {
            recorder = try openRecording(url)
            phase = .recording
            if sessionEngine.source == .onDevice { localModels.prepare(sessionEngine.model) }
            status = "Listening in \(language.title). \(sessionMode == .hold ? "Release" : "Tap the same key again") to transcribe; Escape cancels."
            showOverlay()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.phase == .recording, let recorder = self.recorder else { return }
                    let target = Double(max(0, min(1, (recorder.averagePower + 55) / 45)))
                    self.level += (target - self.level) * 0.3
                    if let error = recorder.recordingError { self.recoverMicrophone(error); return }
                    if recorder.currentTime >= 120 { self.finish() }
                }
            }
        } catch { cancel(); status = "Could not record: \(error.localizedDescription)"; showFeedback(.recordingFailed) }
    }

    private func openRecording(_ url: URL?) throws -> any AudioRecording {
        if let recordingFactory { return try recordingFactory(url, preferences.microphoneUID) }
        return try recordingInput.open(output: url, uid: preferences.microphoneUID)
    }

    private func recoverMicrophone(_ error: Error) {
        guard phase == .recording, let recorder else { return }
        do {
            if try recorder.recover() {
                recordingRecovered = true
                status = "Microphone reconnected. Continue speaking; some audio may be missing."
                pasteTargetInvalidated = true
                return
            }
        } catch {
            recorder.stop()
            retainInterruptedRecording(error, snapshot: recorder.snapshot)
            return
        }
        recorder.stop()
        retainInterruptedRecording(error, snapshot: recorder.snapshot)
    }

    private func retainInterruptedRecording(_ error: Error, snapshot: RecordingSnapshot) {
        timer?.invalidate(); timer = nil
        recorder?.stop(); recorder = nil
        sharedGesture.reset(); handsFreeTrigger.reset()
        if snapshot.hasAudio && file != nil {
            recordingInterrupted = true
            pasteTargetInvalidated = true
            phase = .failed
            status = "Recording interrupted: \(error.localizedDescription) Transcribe captured audio or discard it from the menu bar."
            showFeedback(.interrupted)
        } else {
            cancel()
            status = "Could not record: " + error.localizedDescription
            showFeedback(.recordingFailed)
        }
    }

    func finish() {
        guard phase == .recording else { return }
        sharedGesture.reset()
        timer?.invalidate(); timer = nil
        recorder?.stop()
        let snapshot = recorder?.snapshot ?? RecordingSnapshot()
        let error = recorder?.recordingError
        recorder = nil
        if let error { retainInterruptedRecording(error, snapshot: snapshot); return }
        if sessionSkipSilence && snapshot.isSilent {
            complete(text: "", message: "Silent recording skipped. Turn off Skip silent recordings for very quiet speech.", feedback: .noSpeech)
            return
        }
        process()
    }

    func retry() { guard phase == .failed else { return }; feedback = nil; showOverlay(); process() }

    private func process() {
        guard let file else { return }
        let id = session
        let backend = backendFactory(sessionHost)
        let language = sessionLanguage
        phase = .transcribing
        status = "Transcribing…"
        task = Task {
            do {
                let speechStart = ProcessInfo.processInfo.systemUptime
                let raw: String
                if sessionEngine.source == .onDevice {
                    status = "Transcribing on this Mac…"
                    if let localTranscribe {
                        raw = try await localTranscribe(file, sessionEngine.model, language)
                    } else {
                        raw = try await localModels.engine.transcribe(file: file, model: sessionEngine.model, language: language)
                    }
                } else {
                    raw = try await backend.transcribe(file: file, language: language, model: sessionDictationModel)
                }
                guard session == id, !Task.isCancelled else { return }
                speechSeconds = ProcessInfo.processInfo.systemUptime - speechStart
                if raw.isEmpty { complete(text: "", message: "No speech heard.", feedback: .noSpeech); return }
                if sessionStyle != .raw { phase = .cleaning; status = "Polishing…" }
                let cleanupStart = ProcessInfo.processInfo.systemUptime
                let result = try await backend.clean(raw, style: sessionStyle, dictionary: sessionDictionary, instruction: sessionInstruction, model: sessionPolishModel)
                guard session == id, !Task.isCancelled else { return }
                cleanupSeconds = sessionStyle == .raw ? 0 : ProcessInfo.processInfo.systemUptime - cleanupStart
                library.add(Transcript(language: activeLanguage, raw: raw, text: result.text, style: sessionStyle, cleaned: result.cleaned, speechSeconds: speechSeconds ?? 0, cleanupSeconds: cleanupSeconds ?? 0))
                if recordingInput.isFixture {
                    complete(text: result.text, message: "Audio fixture processed. Nothing was pasted.")
                    return
                }
                let outcome: PasteOutcome
                if pasteTargetInvalidated {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.text, forType: .string)
                    outcome = .copied(recordingInterrupted || recordingRecovered ? "The microphone was interrupted. Review the text, then press Command-V to paste." : "You clicked or typed during dictation. Press Command-V in the intended field.")
                } else {
                    outcome = await target?.paste(result.text, stillValid: { !self.pasteTargetInvalidated && self.session == id }) ?? .copied("Use Copy text to copy this result.")
                }
                guard session == id, !Task.isCancelled else { return }
                let message: String
                let feedback: DictationFeedback?
                switch outcome {
                case .requested: message = "Paste requested in the original app."; feedback = nil
                case .copied(let reason): message = "Text ready. " + reason; feedback = .copied
                case .cancelled: return
                }
                complete(text: result.text, message: message + (result.cleaned || sessionStyle == .raw ? "" : " Polish unavailable; using raw transcript.") + (library.error == nil ? "" : " History could not be saved. See Dictation for details."), feedback: feedback)
            } catch {
                guard session == id, !Task.isCancelled else { return }
                phase = .failed
                status = "Transcription failed: \(error.localizedDescription) Retry or discard from the menu bar."
                showFeedback(.failed)
            }
        }
    }

    private func complete(text: String, message: String, feedback: DictationFeedback? = nil) {
        recordingInterrupted = false
        if !text.isEmpty { latest = text }
        phase = .idle
        status = message
        deleteAudio()
        if let feedback { showFeedback(feedback) }
        else {
            let id = session
            Task { try? await Task.sleep(for: .milliseconds(250)); if session == id && !previewingWave { hideOverlay() } }
        }
    }

    func cancelFromKeyboard() {
        if hotkeyCheck.isActive { stopHotkeyCheck(); return }
        if testingMicrophone { stopMicrophoneTest(); return }
        if previewingWave { stopWavePreview(); return }
        guard phase == .recording || phase == .transcribing || phase == .cleaning || phase == .pasting else { return }
        cancel()
    }

    func cancel(resetSharedGesture: Bool = true) {
        if resetSharedGesture { sharedGesture.reset() }
        handsFreeTrigger.reset()
        stopHotkeyCheck()
        stopMicrophoneTest()
        stopWavePreview()
        session = UUID()
        task?.cancel(); task = nil
        repolishingID = nil
        timer?.invalidate(); timer = nil
        recorder?.stop(); recorder = nil
        deleteAudio()
        phase = .idle
        recordingInterrupted = false
        feedback = nil
        status = "Ready."
        hideOverlay()
    }

    private func deleteAudio() { if let file { try? FileManager.default.removeItem(at: file) }; file = nil }
    func copyLatest() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(latest, forType: .string) }

    func pasteLast() {
        guard phase == .idle, !latest.isEmpty, editingShortcut == nil else { return }
        stopMicrophoneTest(); stopWavePreview()
        session = UUID()
        let id = session
        let text = latest
        let destination = PasteTarget.capture()
        pasteTargetInvalidated = false
        phase = .pasting
        status = "Pasting last dictation…"
        task = Task {
            // Release every physical shortcut key before sending Command-V.
            let keys = preferences.pasteLastShortcut?.keys ?? []
            for _ in 0..<50 {
                if !keys.contains(where: { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0)) }) { break }
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            }
            guard session == id, !Task.isCancelled else { return }
            let held = keys.contains { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0)) }
            let outcome = await destination.paste(text, stillValid: { !held && !self.pasteTargetInvalidated && self.session == id })
            guard session == id, !Task.isCancelled else { return }
            phase = .idle
            switch outcome {
            case .requested: status = "Last dictation pasted."
            case .copied(let reason): status = "Text ready. " + reason; showFeedback(.copied)
            case .cancelled: status = "Paste cancelled."
            }
        }
    }

    func repolish(_ transcriptID: UUID, style: CleanupStyle) {
        guard phase == .idle, style != .raw, let item = library.data.transcripts.first(where: { $0.id == transcriptID }) else { return }
        guard engineSettings.source == .server || engineSettings.serverPolish else {
            status = "Re-Polish needs a server. Enable optional server Polish in LLM first."
            return
        }
        stopMicrophoneTest(); stopWavePreview()
        session = UUID()
        let id = session
        let backend = backendFactory(host)
        let dictionary = library.data.dictionary.filter { $0.language == item.language }
        let instruction = polishPrompts.instruction(for: style)
        let polishModel = preferences.polishModel
        repolishingID = transcriptID
        phase = .cleaning
        status = "Re-polishing saved dictation…"
        task = Task {
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let result = try await backend.clean(item.raw, style: style, dictionary: dictionary, instruction: instruction, model: polishModel)
                guard session == id, !Task.isCancelled else { return }
                if result.cleaned {
                    guard library.data.transcripts.contains(where: { $0.id == transcriptID }) else {
                        phase = .idle; repolishingID = nil; status = "Dictation no longer exists."; return
                    }
                    let saved = library.update { data in
                        if let index = data.transcripts.firstIndex(where: { $0.id == transcriptID }) {
                            data.transcripts[index].revise(text: result.text, style: style, cleaned: true, seconds: ProcessInfo.processInfo.systemUptime - started)
                        }
                    }
                    status = saved ? "Re-Polish saved. The previous version is available in the dictation details." : "Could not save Re-Polish. The previous text is unchanged."
                } else { status = "Polish unavailable. The previous text is unchanged." }
            } catch {
                guard session == id, !Task.isCancelled else { return }
                status = "Could not re-polish. The previous text is unchanged."
            }
            phase = .idle; repolishingID = nil
        }
    }

    func restoreRevision(_ revisionID: UUID, transcriptID: UUID) {
        guard phase == .idle else { return }
        if library.update({ data in
            if let index = data.transcripts.firstIndex(where: { $0.id == transcriptID }) { data.transcripts[index].restore(revisionID) }
        }) { status = "Previous version restored." }
    }

    func previewWave() {
        guard phase == .idle else { return }
        wavePreviewTask?.cancel()
        feedback = nil
        previewingWave = true
        showOverlay(screen: appWindow?.screen ?? NSScreen.main)
        wavePreviewTask = Task {
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            stopWavePreview()
        }
    }
    func stopWavePreview() {
        guard previewingWave else { return }
        wavePreviewTask?.cancel(); wavePreviewTask = nil
        previewingWave = false
        hideOverlay()
    }

    func dismissRecoveryNotice() {
        recoveryNotice = nil
        defaults.removeObject(forKey: DictationPreferences.recoveryNoticeKey)
    }

    private func showFeedback(_ value: DictationFeedback) {
        feedback = value
        showOverlay()
        guard value != .failed && value != .interrupted else { return }
        let id = session
        Task {
            try? await Task.sleep(for: .seconds(6))
            if session == id && feedback == value && !previewingWave { hideOverlay() }
        }
    }

    private func showOverlay(screen: NSScreen? = nil) {
        guard !recordingInput.isFixture else { return }
        hideOverlay()
        let size = feedback == nil ? preferences.waveSize : CGSize(width: 250, height: 54)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if let feedback {
            panel.contentView = NSHostingView(rootView: DictationFeedbackView(feedback: feedback))
        } else {
            panel.contentView = NSHostingView(rootView: InstrumentView(model: self).scaleEffect(preferences.waveWidth / 140).frame(width: size.width, height: size.height))
        }
        let area = (screen ?? target?.screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        panel.setFrameOrigin(preferences.wavePlacement.origin(in: area, size: size, inset: preferences.waveInset))
        panel.orderFrontRegardless()
        self.panel = panel
    }
    private func hideOverlay() { panel?.orderOut(nil); panel = nil }
}
