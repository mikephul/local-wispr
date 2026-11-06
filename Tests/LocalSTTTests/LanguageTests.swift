import XCTest
@testable import LocalSTT

final class LanguageTests: XCTestCase {
    private func bilingualPreferences() -> DictationPreferences {
        var preferences = DictationPreferences()
        var thai = LanguageProfile(language: .thai, dictationModel: "custom-thai-model")
        thai.holdShortcut = KeyShortcut([55, 58])
        thai.handsFreeShortcut = thai.holdShortcut
        preferences.profiles.append(thai)
        return preferences
    }

    func testLegacyKeysAndColorsSurviveMigration() throws {
        let old = Data(#"{"shortcuts":["englishHold",{"keys":[58,59]},"englishToggle",{"keys":[56,122]},"thaiHold",{"keys":[55,58]},"thaiToggle",{"keys":[56,120]}],"englishColor":{"red":0.2,"green":0.3,"blue":0.4},"thaiCleanup":"raw","microphoneUID":"custom","waveWidth":224,"wavePlacement":"topLeft"}"#.utf8)
        let prefs = try JSONDecoder().decode(DictationPreferences.self, from: old)
        XCTAssertEqual(prefs.shortcut(for: .englishHold), KeyShortcut([58, 59]))
        XCTAssertEqual(prefs.shortcut(for: .thaiToggle), KeyShortcut([55, 58]))
        XCTAssertEqual(prefs.waveColor(for: .english), WaveColor(red: 0.2, green: 0.3, blue: 0.4))
        XCTAssertEqual(prefs.cleanup(for: .thai), .raw)
        XCTAssertEqual(prefs.profile(for: .english)?.dictationModel, "parakeet-tdt-0.6b-v2")
        XCTAssertEqual(prefs.microphoneUID, "custom")
        XCTAssertEqual(prefs.waveWidth, 224)
        XCTAssertEqual(prefs.wavePlacement, .topLeft)
        XCTAssertTrue(prefs.isValid)
        XCTAssertEqual(try JSONDecoder().decode(DictationPreferences.self, from: JSONEncoder().encode(prefs)), prefs)
    }
    func testLegacyHandsFreeBindingsKeepTheirBehavior() throws {
        let old = Data(#"{"englishKey":122,"thaiKey":120,"recordingMode":"toggle"}"#.utf8)
        let prefs = try JSONDecoder().decode(DictationPreferences.self, from: old)
        XCTAssertEqual(prefs.shortcut(for: .englishToggle), KeyShortcut([122]))
        XCTAssertEqual(prefs.shortcut(for: .thaiToggle), KeyShortcut([120]))
        XCTAssertNotEqual(prefs.shortcut(for: .englishHold), KeyShortcut([122]))
        XCTAssertTrue(prefs.isValid)
    }
    func testDuplicateAndAmbiguousBindingsAreInvalidButUnassignedIsAllowed() {
        var prefs = bilingualPreferences()
        prefs.shortcuts[.thaiHold] = prefs.shortcuts[.englishHold]
        XCTAssertFalse(prefs.isValid)
        prefs = bilingualPreferences()
        prefs.shortcuts.removeValue(forKey: .thaiHold)
        XCTAssertTrue(prefs.isValid)
        XCTAssertFalse(prefs.sharesShortcut(for: .thai))
        prefs.shortcuts.removeValue(forKey: .thaiToggle)
        XCTAssertFalse(prefs.sharesShortcut(for: .thai))
        prefs = bilingualPreferences()
        prefs.shortcuts[.thaiHold] = KeyShortcut([55])
        XCTAssertFalse(prefs.isValid)
        XCTAssertFalse(KeyShortcut([53]).isValid)
        XCTAssertFalse(KeyShortcut([57]).isValid)
        XCTAssertFalse(KeyShortcut([55, 56, 49]).isValid)
        XCTAssertFalse(KeyShortcut([0, 1]).isValid)
    }
    func testLanguageResetPreservesModelsAndOtherSettings() {
        var prefs = bilingualPreferences()
        prefs.shortcuts[.englishHold] = KeyShortcut([59, 58])
        prefs.shortcuts[.englishToggle] = KeyShortcut([59, 58])
        prefs.update(.english) { $0.cleanup = .raw; $0.color = WaveColor(red: 0, green: 1, blue: 0); $0.dictationModel = "new-model" }
        prefs.update(.thai) { $0.cleanup = .polished; $0.color = WaveColor(red: 1, green: 1, blue: 0) }
        prefs.microphoneUID = "custom"; prefs.waveWidth = 224; prefs.wavePlacement = .topLeft
        let reset = prefs.resetting(.english)
        XCTAssertEqual(reset.waveColor(for: .english), .english)
        XCTAssertEqual(reset.cleanup(for: .english), .light)
        XCTAssertEqual(reset.shortcut(for: .englishHold), DictationPreferences.defaultShortcuts[.englishHold])
        XCTAssertEqual(reset.shortcut(for: .englishToggle), DictationPreferences.defaultShortcuts[.englishToggle])
        XCTAssertEqual(reset.profile(for: .thai), prefs.profile(for: .thai))
        XCTAssertEqual(reset.profile(for: .english)?.dictationModel, "new-model")
        XCTAssertEqual(reset.microphoneUID, prefs.microphoneUID)
        XCTAssertEqual(reset.waveWidth, prefs.waveWidth)
        XCTAssertEqual(reset.wavePlacement, prefs.wavePlacement)
        XCTAssertTrue(reset.isValid)
    }
    func testResetDetectsDefaultKeyTakenByOtherLanguage() {
        var prefs = bilingualPreferences()
        prefs.shortcuts[.englishHold] = KeyShortcut([114])
        prefs.shortcuts[.englishToggle] = KeyShortcut([114])
        prefs.shortcuts[.thaiHold] = KeyShortcut([122])
        XCTAssertTrue(prefs.isValid)
        let reset = prefs.resetting(.english)
        XCTAssertFalse(reset.isValid)
        XCTAssertEqual(reset.conflict(for: reset.shortcut(for: .englishHold), excluding: .englishHold), .thaiHold)
    }
    func testPreviousDefaultsMigrateButCustomColorsStay() throws {
        let old = Data(#"{"shortcuts":["englishHold",{"keys":[122]},"englishToggle",{"keys":[56,122]},"thaiHold",{"keys":[120]},"thaiToggle",{"keys":[56,120]}],"englishColor":{"red":0.46,"green":0.59,"blue":0.63},"thaiColor":{"red":0.91,"green":0.58,"blue":0.78}}"#.utf8)
        let migrated = try JSONDecoder().decode(DictationPreferences.self, from: old)
        XCTAssertEqual(migrated.languages, [.english, .thai])
        XCTAssertEqual(migrated.shortcut(for: .thaiHold), KeyShortcut([55, 58]))
        XCTAssertEqual(migrated.waveColor(for: .thai), .thai)
        XCTAssertTrue(migrated.isValid)
        var custom = migrated
        custom.update(.thai) { $0.color = WaveColor(red: 0.91, green: 0.58, blue: 0.78) }
        XCTAssertEqual(try JSONDecoder().decode(DictationPreferences.self, from: JSONEncoder().encode(custom)), custom)
    }
    func testNewLanguagePersistsWithIndependentShortcutsAndModel() throws {
        let japanese = DictationLanguage(rawValue: "ja")
        var prefs = DictationPreferences()
        prefs.profiles.append(LanguageProfile(language: japanese, dictationModel: "whisper-large-v3"))
        let hold = ShortcutAction.action(for: japanese, mode: .hold)
        let toggle = ShortcutAction.action(for: japanese, mode: .toggle)
        XCTAssertNil(prefs.shortcut(for: hold))
        XCTAssertTrue(prefs.isValid)
        prefs.shortcuts[hold] = KeyShortcut([99])
        prefs.shortcuts[toggle] = KeyShortcut([99])
        XCTAssertTrue(prefs.sharesShortcut(for: japanese))
        XCTAssertEqual(prefs.actions.count, 5)
        XCTAssertTrue(prefs.isValid)
        let decoded = try JSONDecoder().decode(DictationPreferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(decoded, prefs)
        var matcher = ShortcutMatcher(shortcuts: decoded.shortcuts)
        XCTAssertEqual(matcher.update(key: 99, down: true)?.action, hold)
        XCTAssertEqual(matcher.update(key: 99, down: false)?.action, hold)
        prefs.shortcuts[hold] = KeyShortcut([122])
        XCTAssertEqual(prefs.conflict(for: prefs.shortcut(for: hold), excluding: hold), .englishHold)
        XCTAssertFalse(prefs.isValid)
    }
    func testRemovingLanguageKeepsHistoricalDataReadable() throws {
        let japanese = DictationLanguage(rawValue: "ja")
        let transcript = Transcript(language: japanese, raw: "こんにちは", text: "こんにちは。", style: .light, cleaned: true, speechSeconds: 1, cleanupSeconds: 1)
        let library = LibraryData(transcripts: [transcript], dictionary: [.init(language: japanese, heard: "", replacement: "東京")])
        let decoded = try JSONDecoder().decode(LibraryData.self, from: JSONEncoder().encode(library))
        XCTAssertEqual(decoded.transcripts.first?.language, japanese)
        XCTAssertEqual(decoded.dictionary.first?.language, japanese)
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(japanese), as: UTF8.self), "\"ja\"")
        var prefs = DictationPreferences()
        prefs.profiles.append(LanguageProfile(language: japanese, dictationModel: "whisper"))
        prefs.shortcuts[.action(for: japanese, mode: .hold)] = KeyShortcut([99])
        prefs.profiles.removeAll { $0.language == japanese }
        XCTAssertEqual(prefs.actions.count, 3)
        XCTAssertNil(prefs.shortcuts[.action(for: japanese, mode: .hold)])
    }
    func testFreshInstallStartsWithEnglishAndNoThaiBindings() throws {
        let suite = "language-defaults-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DictationPreferences.load(defaults)
        XCTAssertEqual(preferences.languages, [.english])
        XCTAssertEqual(preferences.actions.count, 3)
        XCTAssertNil(preferences.shortcut(for: .pasteLast))
        XCTAssertNil(preferences.shortcut(for: .thaiHold))
        XCTAssertEqual(preferences.shortcut(for: .englishHold), KeyShortcut([122]))
        XCTAssertTrue(preferences.sharesShortcut(for: .english))
        XCTAssertEqual(try JSONDecoder().decode(DictationPreferences.self, from: Data("{}".utf8)), preferences)
        let thai = LanguageProfile(language: .thai, dictationModel: "user-chosen-model")
        XCTAssertNil(thai.holdShortcut)
        XCTAssertNil(thai.effectiveHandsFreeShortcut)
    }
    func testSavedThaiSettingsRemainUnchangedAndEnglishCanBeRemoved() throws {
        let suite = "language-saved-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = bilingualPreferences()
        preferences.update(.thai) {
            $0.color = .thai
            $0.cleanup = .polished
            $0.handsFreeFollowsHold = false
            $0.handsFreeShortcut = KeyShortcut([120])
        }
        defaults.set(try JSONEncoder().encode(preferences), forKey: "dictationPreferences")
        XCTAssertEqual(DictationPreferences.load(defaults), preferences)
        preferences.profiles.removeAll { $0.language == .english }
        defaults.set(try JSONEncoder().encode(preferences), forKey: "dictationPreferences")
        XCTAssertTrue(preferences.isValid)
        XCTAssertEqual(DictationPreferences.load(defaults), preferences)
        XCTAssertEqual(DictationPreferences.load(defaults).languages, [.thai])
    }
    func testSingleLegacyHotkeyStillRestoresBothOldProfiles() {
        let preferences = DictationPreferences(legacyKey: 114)
        XCTAssertEqual(preferences.languages, [.english, .thai])
        XCTAssertEqual(preferences.shortcut(for: .englishHold), KeyShortcut([114]))
        XCTAssertTrue(preferences.isValid)
    }
    func testInvalidProfilesAndDefaultLoad() {
        var prefs = DictationPreferences()
        prefs.profiles.append(prefs.profiles[0])
        XCTAssertFalse(prefs.isValid)
        prefs = DictationPreferences()
        prefs.update(.english) { $0.dictationModel = "bad\r\nmodel" }
        XCTAssertFalse(prefs.isValid)
        XCTAssertFalse(DictationLanguage(rawValue: "bad\r\n").isValid)
        XCTAssertTrue(DictationLanguage(rawValue: "zh-cn").isValid)
        XCTAssertFalse(ModelID.isValid(""))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        XCTAssertEqual(DictationPreferences.load(defaults), DictationPreferences())
    }
}


extension LanguageTests {
    func testHandsFreeFollowsHoldByDefaultAndCustomOverridePersists() throws {
        var prefs = DictationPreferences()
        prefs.setShortcut(KeyShortcut([59, 58]), for: .englishHold)
        XCTAssertEqual(prefs.shortcut(for: .englishToggle), KeyShortcut([59, 58]))
        prefs.setShortcut(KeyShortcut([99]), for: .englishToggle)
        prefs.setShortcut(KeyShortcut([114]), for: .englishHold)
        XCTAssertEqual(prefs.shortcut(for: .englishToggle), KeyShortcut([99]))
        prefs.setShortcut(KeyShortcut([56, 122]), for: .englishToggle)
        let decoded = try JSONDecoder().decode(DictationPreferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(decoded.shortcut(for: .englishToggle), KeyShortcut([56, 122]))
        prefs.useHoldShortcutForHandsFree(.english)
        XCTAssertEqual(prefs.shortcut(for: .englishToggle), KeyShortcut([114]))
        let japanese = DictationLanguage(rawValue: "ja")
        prefs.profiles.append(LanguageProfile(language: japanese, dictationModel: "whisper"))
        prefs.setShortcut(KeyShortcut([99]), for: .action(for: japanese, mode: .hold))
        XCTAssertEqual(prefs.shortcut(for: .action(for: japanese, mode: .toggle)), KeyShortcut([99]))
        prefs.setShortcut(nil, for: .action(for: japanese, mode: .toggle))
        prefs.setShortcut(KeyShortcut([118]), for: .action(for: japanese, mode: .hold))
        XCTAssertNil(prefs.shortcut(for: .action(for: japanese, mode: .toggle)))
    }
    func testOldProfileHandsFreeDefaultsFollowCurrentHold() throws {
        let old = Data(#"{"profiles":[{"language":"en","dictationModel":"parakeet","holdShortcut":{"keys":[58,59]},"handsFreeShortcut":{"keys":[56,122]},"cleanup":"light","color":{"red":0.68,"green":0.52,"blue":0.94}}]}"#.utf8)
        let prefs = try JSONDecoder().decode(DictationPreferences.self, from: old)
        XCTAssertEqual(prefs.shortcut(for: .englishToggle), KeyShortcut([58, 59]))
        XCTAssertTrue(prefs.sharesShortcut(for: .english))
    }
}


extension LanguageTests {
    func testInvalidModelRecoveryPreservesLanguagesAndOriginalData() throws {
        let suite = "preference-recovery-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var prefs = bilingualPreferences()
        prefs.update(.english) { $0.dictationModel = String(repeating: "a", count: 201) }
        let original = try JSONEncoder().encode(prefs)
        defaults.set(original, forKey: "dictationPreferences")
        let recovered = DictationPreferences.load(defaults)
        XCTAssertEqual(recovered.languages, [.english, .thai])
        XCTAssertEqual(recovered.profile(for: .thai), prefs.profile(for: .thai))
        XCTAssertEqual(recovered.profile(for: .english)?.dictationModel, "")
        XCTAssertTrue(recovered.isValid)
        XCTAssertEqual(defaults.data(forKey: DictationPreferences.recoveryBackupKey), original)
        XCTAssertNotNil(defaults.string(forKey: DictationPreferences.recoveryNoticeKey))
        XCTAssertEqual(DictationPreferences.load(defaults), recovered)
        XCTAssertEqual(defaults.data(forKey: DictationPreferences.recoveryBackupKey), original)
    }

    func testUnreadableFieldKeepsOtherProfilesAndSettings() throws {
        let suite = "partial-recovery-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var prefs = bilingualPreferences()
        prefs.waveWidth = 224
        var root = try JSONSerialization.jsonObject(with: JSONEncoder().encode(prefs)) as! [String: Any]
        var profiles = root["profiles"] as! [[String: Any]]
        profiles[0]["cleanup"] = "unknown-style"
        root["profiles"] = profiles
        defaults.set(try JSONSerialization.data(withJSONObject: root), forKey: "dictationPreferences")
        let recovered = DictationPreferences.load(defaults)
        XCTAssertEqual(recovered.languages, [.english, .thai])
        XCTAssertEqual(recovered.profile(for: .thai), prefs.profile(for: .thai))
        XCTAssertEqual(recovered.waveWidth, 224)
        XCTAssertTrue(recovered.isValid)
    }
}
