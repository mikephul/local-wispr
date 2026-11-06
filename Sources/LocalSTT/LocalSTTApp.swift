import SwiftUI
import AppKit
import AVFoundation

enum AppVersion {
    static var display: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return "Development" }
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return version }
        return "\(version) (\(build))"
    }
}

@main
struct LocalSTTApp: App {
    @StateObject private var model = AppModel()
    init() {
        if let index = CommandLine.arguments.firstIndex(of: "--verify-audio-fixture") {
            guard index + 1 < CommandLine.arguments.count else { print("Pass a WAV path after --verify-audio-fixture."); exit(1) }
            let input = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("localstt-fixture-\(UUID()).m4a")
            do {
                let recording = try AudioFixtureRecorder(fixture: input, output: output, realtime: false)
                recording.drain(); recording.stop()
                if let error = recording.recordingError { throw error }
                let audio = try AVAudioFile(forReading: output)
                guard audio.length > 0 else { throw MicrophoneInputError.invalidFormat }
                print("Fixture passed: \(recording.snapshot.frames) input frames; silence gate: \(recording.snapshot.isSilent ? "skip" : "keep"). No microphone or network used.")
                try FileManager.default.removeItem(at: output)
                exit(0)
            } catch {
                try? FileManager.default.removeItem(at: output)
                print("Fixture failed: \(error.localizedDescription)"); exit(1)
            }
        }
        if CommandLine.arguments.contains("--verify-microphone") {
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { print("Microphone permission is required."); exit(1) }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("localstt-check-\(UUID()).m4a")
            do {
                let uid = CommandLine.arguments.contains("--explicit-input") ? Microphone.available().first?.id ?? "" : ""
                let recorder = try MicrophoneRecorder(url: url, uid: uid)
                RunLoop.main.run(until: Date().addingTimeInterval(2))
                recorder.stop()
                if let error = recorder.recordingError { throw error }
                let audio = try AVAudioFile(forReading: url)
                guard audio.length > 0 else { throw CocoaError(.fileReadCorruptFile) }
                print("Microphone verification passed: \(audio.length) frames at \(audio.processingFormat.sampleRate) Hz. Input: \(uid.isEmpty ? "system default" : "explicit device").")
                try FileManager.default.removeItem(at: url)
                exit(0)
            } catch {
                try? FileManager.default.removeItem(at: url)
                print("Microphone verification failed: \(error.localizedDescription)")
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--render-workspace") {
            let fixtureURL = FileManager.default.temporaryDirectory.appendingPathComponent("localstt-preview-\(UUID())/library.json")
            let library = CommandLine.arguments.contains("--sample-transcripts") ? LibraryStore(url: fixtureURL) : nil
            if let library {
                let samples: [(String, DictationLanguage, Int)] = [
                    ("Let's bring dictation and history together in one place.", .english, 0),
                    ("วันนี้ลองใช้การเขียนตามคำบอกภาษาไทย ใช้งานได้สะดวกมากครับ", .thai, 0),
                    ("Please send the project update tomorrow morning. Include the latest changes, the open questions, and what we need to review before the next release.", .english, 0),
                    ("The small waveform at the bottom of the screen works well.", .english, 1),
                    ("ประชุมพรุ่งนี้ตอนสิบโมง แล้วค่อยสรุปงานกันอีกครั้ง", .thai, 1),
                    ("Keep the interface simple and let the transcripts do the talking.", .english, 1)
                ]
                library.update { data in
                    data.transcripts = samples.enumerated().map { index, sample in
                        Transcript(date: Calendar.current.date(byAdding: .day, value: -sample.2, to: Date())!.addingTimeInterval(-Double(index) * 300), language: sample.1, raw: sample.0, text: sample.0, style: .light, cleaned: true, speechSeconds: 0.4, cleanupSeconds: 0.3)
                    }
                }
            }
            defer { if library != nil { try? FileManager.default.removeItem(at: fixtureURL.deletingLastPathComponent()) } }
            let previewAppearance = CommandLine.arguments.first(where: { $0.hasPrefix("--appearance=") }).flatMap { ConsoleAppearance(rawValue: String($0.dropFirst(13))) }
            let model = AppModel(library: library, appearance: previewAppearance)
            let previewWidth: CGFloat = CommandLine.arguments.contains("--compact") ? 820 : 1020
            if CommandLine.arguments.contains("--settings") { model.selectedPage = .settings }
            if CommandLine.arguments.contains("--setup-page") { model.selectedPage = .setup }
            if let pageArg = CommandLine.arguments.first(where: { $0.hasPrefix("--page=") }), let page = AppPage(rawValue: String(pageArg.dropFirst(7))) { model.selectedPage = page }
            let view = NSHostingView(rootView: AppWorkspaceView(model: model).frame(width: previewWidth, height: 780))
            view.frame = NSRect(x: 0, y: 0, width: previewWidth, height: 780)
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let name = model.selectedPage?.rawValue ?? "dictation"
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/localstt-" + name + "-workspace.png"))
            }
            if library != nil { try? FileManager.default.removeItem(at: fixtureURL.deletingLastPathComponent()) }
            exit(0)
        }
        if CommandLine.arguments.contains("--render-settings") || CommandLine.arguments.contains("--render-app") {
            let model = AppModel()
            let settings = CommandLine.arguments.contains("--render-settings")
            let content = settings ? AnyView(AppSettingsView(model: model)) : AnyView(AppHomeView(model: model))
            let size = NSSize(width: settings ? 480 : 560, height: settings ? 600 : 420)
            let view = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
            view.frame = NSRect(origin: .zero, size: size)
            view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let path = settings ? "/tmp/localstt-settings.png" : "/tmp/localstt-app.png"
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            exit(0)
        }
        if CommandLine.arguments.contains("--render-setup") {
            let model = AppModel()
            let view = NSHostingView(rootView: SetupView(model: model).frame(width: 620, height: 920))
            view.frame = NSRect(x: 0, y: 0, width: 620, height: 920)
            view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/localstt-setup.png"))
            }
            exit(0)
        }
        if CommandLine.arguments.contains("--render-preview") {
            let model = AppModel()
            model.phase = .recording
            if CommandLine.arguments.contains("--thai") { model.activeLanguage = .thai }
            model.level = 0.75
            let renderer = ImageRenderer(content: InstrumentView(model: model))
            renderer.scale = 4
            if let image = renderer.cgImage {
                let bitmap = NSBitmapImageRep(cgImage: image)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/localstt-preview.png"))
            }
            exit(0)
        }
    }
    var body: some Scene {
        MenuBarExtra("local-wispr", systemImage: model.phase == .failed ? "exclamationmark.circle.fill" : model.feedback == .copied ? "doc.on.clipboard" : "waveform") {
            if model.phase == .failed {
                Text(model.recordingInterrupted ? "Recording interrupted. Captured audio kept." : "Dictation failed. Audio kept for retry.")
                Button(model.retryTitle) { model.retry() }
                Button("Discard recording", role: .destructive) { model.cancel() }
                Divider()
            } else if model.feedback == .copied {
                Text("Text ready. Paste with Command-V.")
                Button("Copy latest text") { model.copyLatest() }
                Divider()
            }
            Button("Paste last dictation") { model.pasteLast() }.disabled(model.latest.isEmpty || model.phase != .idle)
            Button("Open app") { model.showApp() }
            Button("Settings…") { model.showSettings() }.keyboardShortcut(",")
            Divider()
            Button("Quit") { model.cancel(); NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        }.menuBarExtraStyle(.menu)
    }
}

struct InstrumentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    private var cyan: Color { model.preferences.waveColor(for: model.activeLanguage).color }
    var body: some View {
        ZStack {
            chassis
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || (model.phase == .idle && !model.previewingWave))) { timeline in
                Canvas { context, _ in draw(context, at: timeline.date) }
            }
        }
        .frame(width: 140, height: 44)
        .accessibilityLabel(model.previewingWave ? "Wave preview" : model.phase == .recording ? "Listening" : model.phase == .idle ? "Done" : "Processing dictation")
    }

    private var chassis: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9).fill(LinearGradient(colors: [Color(white: 0.36), Color(white: 0.15), Color(white: 0.22)], startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.22), lineWidth: 0.6).padding(0.7)
            RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.11)).padding(3)
            RoundedRectangle(cornerRadius: 4).fill(Color(red: 0.035, green: 0.065, blue: 0.072)).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.black.opacity(0.7), lineWidth: 1)).padding(.horizontal, 13).padding(.vertical, 8)
        }
    }

    private func draw(_ ctx: GraphicsContext, at date: Date) {
        let t = reduceMotion ? 0 : date.timeIntervalSinceReferenceDate
        let rect = CGRect(x: 18, y: 11, width: 104, height: 22)
        var grid = Path()
        for x in stride(from: rect.minX, through: rect.maxX, by: 13) {
            grid.move(to: CGPoint(x: x, y: rect.minY)); grid.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        for y in [16.5, 22.0, 27.5] {
            grid.move(to: CGPoint(x: 18, y: y)); grid.addLine(to: CGPoint(x: 122, y: y))
        }
        ctx.stroke(grid, with: .color(cyan.opacity(0.09)), lineWidth: 0.5)
        if model.phase == .idle && !model.previewingWave {
            ctx.fill(Path(ellipseIn: CGRect(x: 68.5, y: 20.5, width: 3, height: 3)), with: .color(cyan))
        } else if model.phase == .recording || model.previewingWave {
            var wave = Path()
            for i in 0...104 {
                let u = Double(i) / 104
                let amplitude = reduceMotion ? 0 : (0.5 + (model.previewingWave ? 0.65 : model.level) * 8)
                let fundamental = 0.75 * sin(u * Double.pi * 6 - t * 8)
                let harmonic = 0.25 * sin(u * Double.pi * 12 + t * 5)
                let y = 22 + sin(u * Double.pi) * amplitude * (fundamental + harmonic)
                let point = CGPoint(x: 18 + Double(i), y: y)
                if i == 0 { wave.move(to: point) } else { wave.addLine(to: point) }
            }
            ctx.stroke(wave, with: .color(cyan.opacity(0.16)), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
            ctx.stroke(wave, with: .color(cyan), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        } else {
            var line = Path(); line.move(to: CGPoint(x: 18, y: 22)); line.addLine(to: CGPoint(x: 122, y: 22))
            ctx.stroke(line, with: .color(cyan.opacity(0.25)), lineWidth: 1)
            let x = reduceMotion ? 62 : 18 + t.truncatingRemainder(dividingBy: 1.2) / 1.2 * 88
            var light = Path(); light.move(to: CGPoint(x: x, y: 22)); light.addLine(to: CGPoint(x: x + 16, y: 22))
            ctx.stroke(light, with: .color(cyan), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        for x in [7.0, 133.0] {
            for y in [9.0, 35.0] {
                ctx.fill(Path(ellipseIn: CGRect(x: x - 1.6, y: y - 1.6, width: 3.2, height: 3.2)), with: .color(.black.opacity(0.8)))
                var slot = Path(); slot.move(to: CGPoint(x: x - 0.8, y: y + 0.5)); slot.addLine(to: CGPoint(x: x + 0.8, y: y - 0.5))
                ctx.stroke(slot, with: .color(.white.opacity(0.32)), lineWidth: 0.6)
            }
        }
    }
}


enum DictationFeedback: Equatable {
    case failed, copied, noSpeech, configuration, permission, recordingFailed, interrupted
    var title: String {
        switch self {
        case .failed: return "Dictation failed"
        case .interrupted: return "Recording interrupted"
        case .copied: return "Text ready"
        case .noSpeech: return "No speech heard"
        case .configuration: return "Choose a model"
        case .permission: return "Microphone access needed"
        case .recordingFailed: return "Could not record"
        }
    }
    var detail: String {
        switch self {
        case .failed: return "Retry or discard in the menu bar"
        case .interrupted: return "Captured audio kept · Open menu"
        case .copied: return "Paste with ⌘V · Copy again in menu"
        case .noSpeech: return "Try again when you're ready"
        case .configuration: return "Open the app → LLM"
        case .permission: return "Open the app → Setup & test"
        case .recordingFailed: return "Open the app for details"
        }
    }
    var symbol: String { self == .copied ? "doc.on.clipboard" : self == .noSpeech ? "mic.slash" : "exclamationmark.circle" }
}

struct DictationFeedbackView: View {
    let feedback: DictationFeedback
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: feedback.symbol).font(.system(size: 18)).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 3) {
                Text(feedback.title).font(.system(size: 12, weight: .semibold))
                Text(feedback.detail).font(.system(size: 10)).foregroundStyle(.white.opacity(0.85))
            }
        }
        .foregroundStyle(.white).frame(width: 250, height: 54)
        .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.2)))
        .accessibilityElement(children: .combine)
    }
}
