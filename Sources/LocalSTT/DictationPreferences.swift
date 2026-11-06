import AppKit
import SwiftUI

struct DictationLanguage: RawRepresentable, Codable, Hashable, Identifiable {
    let rawValue: String
    var id: String { rawValue }
    static let english = Self(rawValue: "en")
    static let thai = Self(rawValue: "th")
    init(rawValue: String) { self.rawValue = rawValue }
    var title: String { Locale(identifier: "en_US").localizedString(forIdentifier: rawValue) ?? rawValue }
    var isValid: Bool { rawValue.count <= 35 && rawValue.range(of: "^[a-z]{2,3}(-[a-z0-9]{2,8})*$", options: .regularExpression) != nil }
    init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

enum WavePlacement: String, CaseIterable, Codable {
    case bottomLeft, bottomCenter, bottomRight, topLeft, topCenter, topRight
    var title: String {
        switch self {
        case .bottomLeft: return "Bottom left"
        case .bottomCenter: return "Bottom center"
        case .bottomRight: return "Bottom right"
        case .topLeft: return "Top left"
        case .topCenter: return "Top center"
        case .topRight: return "Top right"
        }
    }
    func origin(in area: CGRect, size: CGSize, inset: CGFloat) -> CGPoint {
        let horizontalInset = min(max(0, inset), max(0, (area.width - size.width) / 2))
        let verticalInset = min(max(0, inset), max(0, (area.height - size.height) / 2))
        let x: CGFloat
        switch self {
        case .bottomLeft, .topLeft: x = area.minX + horizontalInset
        case .bottomRight, .topRight: x = area.maxX - size.width - horizontalInset
        case .bottomCenter, .topCenter: x = area.midX - size.width / 2
        }
        let top = self == .topLeft || self == .topCenter || self == .topRight
        return CGPoint(x: x, y: top ? area.maxY - size.height - verticalInset : area.minY + verticalInset)
    }
}

struct WaveColor: Codable, Equatable {
    let red: Double
    let green: Double
    let blue: Double
    static let english = WaveColor(red: 0.68, green: 0.52, blue: 0.94)
    static let thai = WaveColor(red: 0.98, green: 0.76, blue: 0.35)
    var color: Color { Color(red: red, green: green, blue: blue) }
    var isValid: Bool { [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) } }
    init(red: Double, green: Double, blue: Double) { self.red = red; self.green = green; self.blue = blue }
    init(_ color: Color) {
        let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .white
        red = rgb.redComponent; green = rgb.greenComponent; blue = rgb.blueComponent
    }
}

struct LanguageProfile: Codable, Equatable, Identifiable {
    let language: DictationLanguage
    var id: DictationLanguage { language }
    var dictationModel: String
    var holdShortcut: KeyShortcut?
    var handsFreeShortcut: KeyShortcut?
    var handsFreeFollowsHold = true
    var effectiveHandsFreeShortcut: KeyShortcut? { handsFreeFollowsHold ? holdShortcut : handsFreeShortcut }
    var cleanup: CleanupStyle = .light
    var color: WaveColor

    init(language: DictationLanguage, dictationModel: String = "") {
        self.language = language
        self.dictationModel = dictationModel
        holdShortcut = DictationPreferences.defaultShortcuts[.action(for: language, mode: .hold)]
        handsFreeShortcut = DictationPreferences.defaultShortcuts[.action(for: language, mode: .toggle)]
        color = Self.defaultColor(for: language)
    }
    private enum CodingKeys: String, CodingKey { case language, dictationModel, holdShortcut, handsFreeShortcut, handsFreeFollowsHold, cleanup, color }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = try c.decode(DictationLanguage.self, forKey: .language)
        dictationModel = try c.decode(String.self, forKey: .dictationModel)
        holdShortcut = try c.decodeIfPresent(KeyShortcut.self, forKey: .holdShortcut)
        handsFreeShortcut = try c.decodeIfPresent(KeyShortcut.self, forKey: .handsFreeShortcut)
        cleanup = try c.decodeIfPresent(CleanupStyle.self, forKey: .cleanup) ?? .light
        color = try c.decode(WaveColor.self, forKey: .color)
        handsFreeFollowsHold = try c.decodeIfPresent(Bool.self, forKey: .handsFreeFollowsHold) ?? (handsFreeShortcut == holdShortcut || usesPreviousHandsFreeDefault)
    }
    var usesPreviousHandsFreeDefault: Bool {
        (language == .english && handsFreeShortcut == KeyShortcut([56, 122])) ||
        (language == .thai && handsFreeShortcut == KeyShortcut([56, 120]))
    }
    static func defaultColor(for language: DictationLanguage) -> WaveColor {
        if language == .english { return .english }
        let palette = [WaveColor(red: 0.35, green: 0.78, blue: 0.72), WaveColor(red: 0.92, green: 0.50, blue: 0.57), WaveColor(red: 0.42, green: 0.66, blue: 0.97)]
        return palette[language.rawValue.utf8.reduce(0) { $0 + Int($1) } % palette.count]
    }
    static var defaults: [Self] {
        [Self(language: .english, dictationModel: "parakeet-tdt-0.6b-v2")]
    }
    var isValid: Bool { language.isValid && (dictationModel.isEmpty || ModelID.isValid(dictationModel)) && color.isValid && (holdShortcut?.isValid ?? true) && (handsFreeShortcut?.isValid ?? true) }
}

enum ModelID {
    static func isValid(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 200 && value == value.trimmingCharacters(in: .whitespacesAndNewlines) && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

struct DictationPreferences: Codable, Equatable {
    static let defaultShortcuts: [ShortcutAction: KeyShortcut] = [
        .englishHold: KeyShortcut([122]), .englishToggle: KeyShortcut([122])
    ]
    private static let legacyShortcuts = defaultShortcuts.merging([
        ShortcutAction.thaiHold: KeyShortcut([55, 58]), .thaiToggle: KeyShortcut([55, 58])
    ]) { _, legacy in legacy }
    private static var legacyProfiles: [LanguageProfile] {
        var thai = LanguageProfile(language: .thai, dictationModel: "typhoon-whisper-turbo")
        thai.holdShortcut = legacyShortcuts[.thaiHold]
        thai.handsFreeShortcut = legacyShortcuts[.thaiToggle]
        thai.color = .thai
        return LanguageProfile.defaults + [thai]
    }
    var profiles = LanguageProfile.defaults
    var pasteLastShortcut: KeyShortcut?
    var skipSilence = true
    var polishModel = Backend.cleanupModel
    var microphoneUID = ""
    var waveWidth: Double = 140
    var waveInset: Double = 16
    var wavePlacement: WavePlacement = .bottomCenter
    var waveSize: CGSize { CGSize(width: waveWidth, height: waveWidth * 44 / 140) }
    var languages: [DictationLanguage] { profiles.map(\.language) }
    var actions: [ShortcutAction] { languages.flatMap { language in RecordingMode.allCases.map { .action(for: language, mode: $0) } } + [.pasteLast] }
    var shortcuts: [ShortcutAction: KeyShortcut] {
        get { Dictionary(uniqueKeysWithValues: actions.compactMap { action in shortcut(for: action).map { (action, $0) } }) }
        set {
            pasteLastShortcut = newValue[.pasteLast]
            for index in profiles.indices {
                let language = profiles[index].language
                profiles[index].holdShortcut = newValue[.action(for: language, mode: .hold)]
                profiles[index].handsFreeShortcut = newValue[.action(for: language, mode: .toggle)]
                profiles[index].handsFreeFollowsHold = profiles[index].handsFreeShortcut == profiles[index].holdShortcut
            }
        }
    }
    func profile(for language: DictationLanguage) -> LanguageProfile? { profiles.first { $0.language == language } }
    mutating func update(_ language: DictationLanguage, _ change: (inout LanguageProfile) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.language == language }) else { return }
        change(&profiles[index])
    }
    func cleanup(for language: DictationLanguage) -> CleanupStyle { profile(for: language)?.cleanup ?? .light }
    func shortcut(for action: ShortcutAction) -> KeyShortcut? {
        guard let language = action.language else { return pasteLastShortcut }
        let profile = profile(for: language)
        return action.mode == .hold ? profile?.holdShortcut : profile?.effectiveHandsFreeShortcut
    }
    mutating func setShortcut(_ shortcut: KeyShortcut?, for action: ShortcutAction) {
        guard let language = action.language else { pasteLastShortcut = shortcut; return }
        update(language) { profile in
            if action.mode == .hold { profile.holdShortcut = shortcut }
            else { profile.handsFreeFollowsHold = false; profile.handsFreeShortcut = shortcut }
        }
    }
    mutating func useHoldShortcutForHandsFree(_ language: DictationLanguage) {
        update(language) { $0.handsFreeFollowsHold = true }
    }
    func conflict(for shortcut: KeyShortcut?, excluding action: ShortcutAction) -> ShortcutAction? {
        guard let shortcut else { return nil }
        return actions.first { other in
            guard other != action, let existing = self.shortcut(for: other) else { return false }
            if other.language == action.language && shortcut == existing { return false }
            return shortcut.conflicts(with: existing)
        }
    }
    func resetting(_ language: DictationLanguage) -> Self {
        var result = self
        result.update(language) { profile in
            profile.holdShortcut = Self.defaultShortcuts[.action(for: language, mode: .hold)]
            profile.handsFreeShortcut = Self.defaultShortcuts[.action(for: language, mode: .toggle)]
            profile.handsFreeFollowsHold = true
            profile.cleanup = .light
            profile.color = LanguageProfile.defaultColor(for: language)
        }
        return result
    }
    func sharesShortcut(for language: DictationLanguage) -> Bool {
        guard let hold = shortcut(for: .action(for: language, mode: .hold)) else { return false }
        return hold == shortcut(for: .action(for: language, mode: .toggle))
    }
    func waveColor(for language: DictationLanguage) -> WaveColor { profile(for: language)?.color ?? LanguageProfile.defaultColor(for: language) }
    var isValid: Bool {
        !profiles.isEmpty && Set(languages).count == profiles.count && profiles.allSatisfy(\.isValid) && (pasteLastShortcut?.isValid ?? true) && ModelID.isValid(polishModel) && actions.allSatisfy { conflict(for: shortcut(for: $0), excluding: $0) == nil } && waveWidth.isFinite && (112...280).contains(waveWidth) && waveInset.isFinite && (0...100).contains(waveInset)
    }
    enum CodingKeys: String, CodingKey { case profiles, pasteLastShortcut, skipSilence, polishModel, microphoneUID, waveWidth, waveInset, wavePlacement }
    private enum LegacyKeys: String, CodingKey { case shortcuts, englishKey, thaiKey, recordingMode, englishColor, thaiColor, englishCleanup, thaiCleanup }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let saved = try c.decodeIfPresent([LanguageProfile].self, forKey: .profiles) { profiles = saved }
        else {
            let old = try decoder.container(keyedBy: LegacyKeys.self)
            if !old.allKeys.isEmpty {
                profiles = Self.legacyProfiles
                if let saved = try old.decodeIfPresent([ShortcutAction: KeyShortcut].self, forKey: .shortcuts) {
                    let previousDefaults: [ShortcutAction: KeyShortcut] = [.englishHold: KeyShortcut([122]), .englishToggle: KeyShortcut([56, 122]), .thaiHold: KeyShortcut([120]), .thaiToggle: KeyShortcut([56, 120])]
                    shortcuts = saved == previousDefaults ? Self.legacyShortcuts : saved
                } else if old.contains(.englishKey) || old.contains(.thaiKey) || old.contains(.recordingMode) {
                    migrate(english: try old.decodeIfPresent(Int.self, forKey: .englishKey) ?? 122, thai: try old.decodeIfPresent(Int.self, forKey: .thaiKey) ?? 120, mode: try old.decodeIfPresent(RecordingMode.self, forKey: .recordingMode) ?? .hold)
                }
                var englishColor = try old.decodeIfPresent(WaveColor.self, forKey: .englishColor) ?? .english
                var thaiColor = try old.decodeIfPresent(WaveColor.self, forKey: .thaiColor) ?? .thai
                if englishColor == WaveColor(red: 0.46, green: 0.59, blue: 0.63) { englishColor = .english }
                if thaiColor == WaveColor(red: 0.70, green: 0.59, blue: 0.44) || thaiColor == WaveColor(red: 0.91, green: 0.58, blue: 0.78) { thaiColor = .thai }
                profiles[0].color = englishColor; profiles[1].color = thaiColor
                profiles[0].cleanup = try old.decodeIfPresent(CleanupStyle.self, forKey: .englishCleanup) ?? .light
                profiles[1].cleanup = try old.decodeIfPresent(CleanupStyle.self, forKey: .thaiCleanup) ?? .light
            }
        }
        if !c.contains(.profiles) {
            for index in profiles.indices where profiles[index].usesPreviousHandsFreeDefault { profiles[index].handsFreeFollowsHold = true }
        }
        pasteLastShortcut = try c.decodeIfPresent(KeyShortcut.self, forKey: .pasteLastShortcut)
        skipSilence = try c.decodeIfPresent(Bool.self, forKey: .skipSilence) ?? true
        polishModel = try c.decodeIfPresent(String.self, forKey: .polishModel) ?? Backend.cleanupModel
        microphoneUID = try c.decodeIfPresent(String.self, forKey: .microphoneUID) ?? ""
        waveWidth = try c.decodeIfPresent(Double.self, forKey: .waveWidth) ?? 140
        waveInset = try c.decodeIfPresent(Double.self, forKey: .waveInset) ?? 16
        wavePlacement = try c.decodeIfPresent(WavePlacement.self, forKey: .wavePlacement) ?? .bottomCenter
    }
    init(legacyKey: Int? = nil) {
        if let legacyKey { migrate(english: legacyKey == 0 ? 122 : legacyKey, thai: legacyKey == 120 ? 61 : 120, mode: .hold) }
    }
    private mutating func migrate(english: Int, thai: Int, mode: RecordingMode) {
        profiles = Self.legacyProfiles
        var saved: [ShortcutAction: KeyShortcut] = [.action(for: .english, mode: mode): KeyShortcut([english]), .action(for: .thai, mode: mode): KeyShortcut([thai])]
        for action in actions where action != .pasteLast && saved[action] == nil {
            let candidates = [Self.legacyShortcuts[action]!] + [56, 59, 58, 55].flatMap { modifier in [122, 120, 118, 99, 96].map { KeyShortcut([modifier, $0]) } }
            saved[action] = candidates.first { candidate in !saved.values.contains { candidate.conflicts(with: $0) } }
        }
        shortcuts = saved
    }
    private static func recoverFields(from data: Data) -> Self {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Self() }
        func field<T: Decodable>(_ value: Any?) -> T? {
            guard let value, let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return nil }
            return try? JSONDecoder().decode(T.self, from: bytes)
        }
        var value = Self()
        if let profiles = root["profiles"] as? [[String: Any]] {
            value.profiles = profiles.compactMap { saved in
                guard let language: DictationLanguage = field(saved["language"]), language.isValid else { return nil }
                var profile = LanguageProfile(language: language, dictationModel: saved["dictationModel"] as? String ?? "")
                profile.holdShortcut = field(saved["holdShortcut"])
                profile.handsFreeShortcut = field(saved["handsFreeShortcut"])
                profile.handsFreeFollowsHold = saved["handsFreeFollowsHold"] as? Bool ?? (profile.handsFreeShortcut == profile.holdShortcut || profile.usesPreviousHandsFreeDefault)
                profile.color = field(saved["color"]) ?? LanguageProfile.defaultColor(for: language)
                profile.cleanup = field(saved["cleanup"]) ?? .light
                return profile
            }
        }
        value.pasteLastShortcut = field(root["pasteLastShortcut"])
        value.skipSilence = root["skipSilence"] as? Bool ?? true
        value.polishModel = root["polishModel"] as? String ?? value.polishModel
        value.microphoneUID = root["microphoneUID"] as? String ?? value.microphoneUID
        value.waveWidth = root["waveWidth"] as? Double ?? value.waveWidth
        value.waveInset = root["waveInset"] as? Double ?? value.waveInset
        value.wavePlacement = field(root["wavePlacement"]) ?? value.wavePlacement
        return value
    }

    static let recoveryBackupKey = "dictationPreferencesRecoveryBackup"
    static let recoveryNoticeKey = "dictationPreferencesRecoveryNotice"

    static func load(_ defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: "dictationPreferences") else {
            return Self(legacyKey: defaults.object(forKey: "holdKey") == nil ? nil : defaults.integer(forKey: "holdKey"))
        }
        let decoded = try? JSONDecoder().decode(Self.self, from: data)
        if let decoded, decoded.isValid { return decoded }
        // Keep the original bytes even after the recovered configuration is edited.
        if defaults.data(forKey: recoveryBackupKey) == nil { defaults.set(data, forKey: recoveryBackupKey) }
        var recovered = decoded ?? recoverFields(from: data)
        var seen = Set<DictationLanguage>()
        recovered.profiles = recovered.profiles.filter { $0.language.isValid && seen.insert($0.language).inserted }
        for index in recovered.profiles.indices {
            if !ModelID.isValid(recovered.profiles[index].dictationModel) { recovered.profiles[index].dictationModel = "" }
            if !recovered.profiles[index].color.isValid { recovered.profiles[index].color = LanguageProfile.defaultColor(for: recovered.profiles[index].language) }
            if recovered.profiles[index].holdShortcut?.isValid == false { recovered.profiles[index].holdShortcut = nil }
            if recovered.profiles[index].handsFreeShortcut?.isValid == false { recovered.profiles[index].handsFreeShortcut = nil }
        }
        if recovered.profiles.isEmpty { recovered.profiles = LanguageProfile.defaults }
        if recovered.pasteLastShortcut?.isValid == false { recovered.pasteLastShortcut = nil }
        for action in recovered.actions where recovered.conflict(for: recovered.shortcut(for: action), excluding: action) != nil {
            recovered.setShortcut(nil, for: action)
        }
        if !ModelID.isValid(recovered.polishModel) { recovered.polishModel = Backend.cleanupModel }
        if !recovered.waveWidth.isFinite || !(112...280).contains(recovered.waveWidth) { recovered.waveWidth = 140 }
        if !recovered.waveInset.isFinite || !(0...100).contains(recovered.waveInset) { recovered.waveInset = 16 }
        defaults.set(decoded == nil
            ? "Some saved settings could not be read. Recovered fields were kept; the original data is backed up. Review LLM and Settings."
            : "Some saved settings were invalid and have been repaired. Review LLM models and shortcuts. The original data is backed up.", forKey: recoveryNoticeKey)
        if let repaired = try? JSONEncoder().encode(recovered) { defaults.set(repaired, forKey: "dictationPreferences") }
        return recovered
    }
}
