import Foundation

// Adapted from Hex's longest, non-overlapping phrase replacement policy (MIT).
struct DictionaryRules {
    private struct Rule { let expression: NSRegularExpression; let replacement: String }
    private let rules: [Rule]

    init(_ entries: [DictionaryEntry]) {
        rules = entries.compactMap { entry in
            let phrase = entry.heard.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phrase.isEmpty, let expression = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: phrase), options: .caseInsensitive) else { return nil }
            return Rule(expression: expression, replacement: entry.replacement)
        }
    }

    func apply(to text: String) -> String {
        struct Match { let range: NSRange; let rule: Int }
        let source = text as NSString
        var matches: [Match] = []
        for (index, rule) in rules.enumerated() {
            var offset = 0
            while offset < source.length, let match = rule.expression.firstMatch(in: text, range: NSRange(location: offset, length: source.length - offset)) {
                if let range = Range(match.range, in: text) {
                    let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
                    let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
                    if !Self.wordCharacter(before) && !Self.wordCharacter(after) { matches.append(Match(range: match.range, rule: index)) }
                    offset = NSRange(text.startIndex..<text.index(after: range.lowerBound), in: text).length
                } else { break }
            }
        }
        matches.sort {
            if $0.range.length != $1.range.length { return $0.range.length > $1.range.length }
            if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
            return $0.rule < $1.rule
        }
        var selected: [Match] = []
        for match in matches where !selected.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) { selected.append(match) }
        let result = NSMutableString(string: text)
        for match in selected.sorted(by: { $0.range.location > $1.range.location }) {
            result.replaceCharacters(in: match.range, with: rules[match.rule].replacement)
        }
        return result as String
    }

    private static let unspaced = try! NSRegularExpression(pattern: "[\\p{Han}\\p{Hiragana}\\p{Katakana}\\p{Hangul}\\p{Thai}\\p{Lao}\\p{Khmer}\\p{Myanmar}\\p{Tibetan}]")
    private static func wordCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        let text = String(character)
        if unspaced.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { return false }
        return text == "_" || text.unicodeScalars.contains { CharacterSet.alphanumerics.union(.nonBaseCharacters).contains($0) }
    }
}
