import AppKit

enum ShortcutAction: Codable, Identifiable, Hashable {
    case dictation(language: DictationLanguage, mode: RecordingMode)
    case pasteLast
    var language: DictationLanguage? { if case .dictation(let language, _) = self { return language }; return nil }
    var mode: RecordingMode? { if case .dictation(_, let mode) = self { return mode }; return nil }
    var id: String { rawValue }
    var rawValue: String {
        guard case .dictation(let language, let mode) = self else { return "pasteLast" }
        if language == .english { return mode == .hold ? "englishHold" : "englishToggle" }
        if language == .thai { return mode == .hold ? "thaiHold" : "thaiToggle" }
        return language.rawValue + ":" + mode.rawValue
    }
    static let englishHold = Self(language: .english, mode: .hold)
    static let englishToggle = Self(language: .english, mode: .toggle)
    static let thaiHold = Self(language: .thai, mode: .hold)
    static let thaiToggle = Self(language: .thai, mode: .toggle)
    var title: String { if case .dictation(let language, let mode) = self { return "\(language.title) · \(mode.title)" }; return "Paste last dictation" }
    static func action(for language: DictationLanguage, mode: RecordingMode) -> Self { Self(language: language, mode: mode) }
    init(language: DictationLanguage, mode: RecordingMode) { self = .dictation(language: language, mode: mode) }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let value = try c.decode(String.self)
        switch value {
        case "pasteLast": self = .pasteLast
        case "englishHold": self = .englishHold
        case "englishToggle": self = .englishToggle
        case "thaiHold": self = .thaiHold
        case "thaiToggle": self = .thaiToggle
        default:
            let parts = value.split(separator: ":")
            guard parts.count == 2, let mode = RecordingMode(rawValue: String(parts[1])) else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid shortcut action") }
            self.init(language: DictationLanguage(rawValue: String(parts[0])), mode: mode)
        }
    }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

struct KeyShortcut: Codable, Equatable, Hashable {
    let keys: [Int]
    init(_ keys: [Int]) { self.keys = Array(Set(keys)).sorted() }
    static let modifiers: Set<Int> = [54, 55, 56, 60, 58, 61, 59, 62, 63]
    var isValid: Bool { (1...2).contains(keys.count) && (keys.count == 1 || keys.contains { Self.modifiers.contains($0) }) && Set(keys).count == keys.count && keys.allSatisfy { (0...126).contains($0) && $0 != 53 && $0 != 57 } }
    var displayKeys: [String] {
        keys.sorted { (Self.modifiers.contains($0) ? 0 : 1, $0) < (Self.modifiers.contains($1) ? 0 : 1, $1) }.map(Self.name)
    }
    var title: String { displayKeys.joined(separator: " + ") }
    func conflicts(with other: Self) -> Bool {
        let a = Set(keys), b = Set(other.keys)
        return a == b || (a.isSubset(of: b) && a.isSubset(of: Self.modifiers)) || (b.isSubset(of: a) && b.isSubset(of: Self.modifiers))
    }
    static func name(_ key: Int) -> String {
        let names: [Int: String] = [
            0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",
            18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"−",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",
            36:"Return",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",48:"Tab",49:"Space",50:"`",51:"Delete",
            54:"Right ⌘",55:"⌘",56:"⇧",58:"⌥",59:"⌃",60:"Right ⇧",61:"Right ⌥",62:"Right ⌃",63:"Fn",
            64:"F17",65:"Keypad .",67:"Keypad *",69:"Keypad +",71:"Clear",75:"Keypad /",76:"Enter",78:"Keypad −",79:"F18",80:"F19",81:"Keypad =",
            82:"Keypad 0",83:"Keypad 1",84:"Keypad 2",85:"Keypad 3",86:"Keypad 4",87:"Keypad 5",88:"Keypad 6",89:"Keypad 7",91:"Keypad 8",92:"Keypad 9",
            96:"F5",97:"F6",98:"F7",99:"F3",100:"F8",101:"F9",103:"F11",105:"F13",106:"F16",107:"F14",109:"F10",111:"F12",113:"F15",114:"Insert",115:"Home",116:"Page Up",117:"Forward Delete",118:"F4",119:"End",120:"F2",121:"Page Down",122:"F1",123:"←",124:"→",125:"↓",126:"↑"
        ]
        return names[key] ?? "Key \(key)"
    }
    static func modifierFlag(for code: Int) -> CGEventFlags {
        switch code {
        case 54, 55: return .maskCommand
        case 56, 60: return .maskShift
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        case 63: return .maskSecondaryFn
        default: return []
        }
    }
    static func modifierKeys(flags: CGEventFlags) -> Set<Int> {
        var result = Set<Int>()
        for family in [[55, 54], [56, 60], [58, 61], [59, 62], [63]] where flags.contains(modifierFlag(for: family[0])) {
            let physical = family.filter { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0)) }
            if family[0] != 63 || !physical.isEmpty { result.formUnion(physical.isEmpty ? [family[0]] : physical) }
        }
        return result
    }
}

struct ShortcutMatcher {
    var shortcuts: [ShortcutAction: KeyShortcut]
    private(set) var held = Set<Int>()
    private(set) var active: ShortcutAction?
    mutating func update(key: Int, down: Bool) -> (action: ShortcutAction, down: Bool)? {
        let changed = down ? held.insert(key).inserted : held.remove(key) != nil
        guard changed else { return nil }
        if let active {
            if !Set(shortcuts[active]?.keys ?? []).isSubset(of: held) {
                self.active = nil
                return (active, false)
            }
            return nil
        }
        guard down, let action = shortcuts.keys.sorted(by: { ($0.mode == .hold ? 0 : 1, $0.rawValue) < ($1.mode == .hold ? 0 : 1, $1.rawValue) }).first(where: { Set(shortcuts[$0]?.keys ?? []) == held }) else { return nil }
        active = action
        return (action, true)
    }
    mutating func synchronizeModifiers(_ keys: Set<Int>) { held.subtract(KeyShortcut.modifiers); held.formUnion(keys) }
    mutating func reset() { held.removeAll(); active = nil }
}

struct HandsFreeTrigger {
    static let interval: TimeInterval = 0.45
    private var press: (ShortcutAction, TimeInterval)?
    private var lastTap: (ShortcutAction, TimeInterval)?
    mutating func update(action: ShortcutAction, down: Bool, now: TimeInterval) -> Bool {
        if down {
            if let lastTap, lastTap.0 == action, now - lastTap.1 <= Self.interval {
                reset()
                return true
            }
            lastTap = nil
            press = (action, now)
        } else if let press, press.0 == action {
            lastTap = now - press.1 <= Self.interval ? (action, now) : nil
            self.press = nil
        }
        return false
    }
    mutating func reset() { press = nil; lastTap = nil }
}

struct SharedShortcutGesture {
    enum Effect: Equatable { case startHold, discardTap, startHandsFree, finish, none }
    static let tapDuration: TimeInterval = 0.25
    private enum State { case idle, holding(ShortcutAction, TimeInterval), handsFree(ShortcutAction) }
    private var state = State.idle
    private var lastTap: (ShortcutAction, TimeInterval)?

    mutating func update(action: ShortcutAction, down: Bool, now: TimeInterval) -> Effect {
        switch state {
        case .idle:
            guard down else { return .none }
            if let lastTap, lastTap.0 == action, now - lastTap.1 <= HandsFreeTrigger.interval {
                self.lastTap = nil
                state = .handsFree(action)
                return .startHandsFree
            }
            lastTap = nil
            state = .holding(action, now)
            return .startHold
        case .holding(let current, let started):
            guard action == current, !down else { return .none }
            state = .idle
            if now - started <= Self.tapDuration {
                lastTap = (action, now)
                return .discardTap
            }
            lastTap = nil
            return .finish
        case .handsFree(let current):
            guard action == current, down else { return .none }
            reset()
            return .finish
        }
    }
    mutating func reset() { state = .idle; lastTap = nil }
}
