import Foundation

/// Built-in glossary packs (Resources/Glossaries/<pack>.json: an array of Term).
public enum GlossaryPacks {
    private static let files: [String: URL] = {
        guard let directory = StrataResources.url("Glossaries"),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: files.filter { $0.pathExtension == "json" }.map {
            ($0.deletingPathExtension().lastPathComponent, $0)
        })
    }()
    private static let cache = NSCache<NSString, Pack>()

    private final class Pack {
        let terms: [Term]
        init(_ terms: [Term]) { self.terms = terms }
    }

    public static func load(_ pack: String) -> [Term] {
        let key = pack as NSString
        if let cached = cache.object(forKey: key) { return cached.terms }
        guard let file = files[pack], let data = try? Data(contentsOf: file),
              let terms = try? JSONDecoder().decode([Term].self, from: data) else { return [] }
        cache.setObject(Pack(terms), forKey: key)
        return terms
    }

    public static var available: [String] { files.keys.sorted() }
}

/// The terms visible to one manifest: its own, then its imported packs, in order.
public struct TermIndex: Sendable {
    public private(set) var terms: [Term]
    private let byID: [String: Term]
    private let matcher: TermMatcher

    public init(terms: [Term]) {
        self.init(terms: terms, qualified: [:])
    }

    public init(manifest: Manifest) {
        var terms = manifest.terms
        var qualified: [String: Term] = [:]
        var seen: Set<String> = []
        for pack in manifest.glossaries where seen.insert(pack).inserted {
            let imported = GlossaryPacks.load(pack)
            terms += imported
            for term in imported where qualified["\(pack)/\(term.id)"] == nil {
                qualified["\(pack)/\(term.id)"] = term
            }
        }
        self.init(terms: terms, qualified: qualified)
    }

    private init(terms: [Term], qualified: [String: Term]) {
        self.terms = terms
        self.byID = qualified.merging(terms.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.matcher = TermMatcher(terms: terms)
    }

    /// By id, or by `pack/id` for a pack imported by this manifest.
    public func term(_ id: String) -> Term? { byID[id] }

    /// Links only each term's first occurrence, resolving overlap in favor of longer phrases.
    public func matches(in text: String) -> [(range: Range<String.Index>, term: Term)] {
        matcher.matches(in: text)
    }
}

private final class TermMatcher: @unchecked Sendable {
    private struct Phrase {
        let text: String
        let term: Int
    }

    private struct Compiled {
        let regex: NSRegularExpression
        let byText: [String: Phrase]
        let shorter: [String: [Phrase]]
    }

    private struct Candidate {
        let range: NSRange
        let term: Int
    }

    private let terms: [Term]
    private let lock = NSLock()
    private var compiled: Compiled?
    private var attempted = false

    init(terms: [Term]) { self.terms = terms }

    private func expression() -> Compiled? {
        lock.lock()
        defer { lock.unlock() }
        if attempted { return compiled }
        attempted = true

        var byText: [String: Phrase] = [:]
        for (index, term) in terms.enumerated() {
            for text in term.match ?? [term.term] where !text.isEmpty {
                let key = Self.fold(text)
                if byText[key] == nil { byText[key] = Phrase(text: text, term: index) }
            }
        }
        guard !byText.isEmpty else { return nil }

        var shorter: [String: [Phrase]] = [:]
        for key in byText.keys {
            for boundary in key.indices.dropFirst() where !Self.wordCharacter(key[boundary]) {
                if let prefix = byText[String(key[..<boundary])] {
                    shorter[key, default: []].append(prefix)
                }
            }
        }
        let ordered = byText.values.sorted { ($0.text.utf16.count, $0.text) > ($1.text.utf16.count, $1.text) }
        let alternatives = ordered.map { NSRegularExpression.escapedPattern(for: $0.text) }.joined(separator: "|")
        // The lookahead lets a longer term start inside another candidate. Code spans and links
        // consume their entire range, so neither can start a candidate.
        let excluded = #"((?<!\x60)(\x60+)(?!\x60)[\s\S]*?(?<!\x60)\2(?!\x60)|\[\[[\s\S]*?\]\])"#
        let pattern = excluded + #"|(?<![\w-])(?=("# + alternatives + #")(?![\w-]))"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            compiled = Compiled(regex: regex, byText: byText, shorter: shorter)
        }
        return compiled
    }

    func matches(in text: String) -> [(range: Range<String.Index>, term: Term)] {
        guard !text.isEmpty, let compiled = expression() else { return [] }
        let matches = compiled.regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let excluded = matches.compactMap { match -> NSRange? in
            let range = match.range(at: 1)
            return range.location == NSNotFound ? nil : range
        }

        var first: [Int: Candidate] = [:]
        var mask = 0
        for match in matches {
            let range = match.range(at: 3)
            guard let slice = Range(range, in: text) else { continue }
            while mask < excluded.count, NSMaxRange(excluded[mask]) <= range.location { mask += 1 }
            let key = Self.fold(String(text[slice]))
            guard let phrase = compiled.byText[key] else { continue }

            func record(_ phrase: Phrase, range: NSRange) {
                if mask < excluded.count, range.intersection(excluded[mask]) != nil { return }
                if let current = first[phrase.term],
                   current.range.location < range.location || current.range.length >= range.length { return }
                first[phrase.term] = Candidate(range: range, term: phrase.term)
            }

            record(phrase, range: range)
            for shorter in compiled.shorter[key, default: []] {
                if let prefix = text.range(of: shorter.text, options: [.anchored, .caseInsensitive], range: slice) {
                    record(shorter, range: NSRange(prefix, in: text))
                }
            }
        }

        let prioritized = first.values.sorted {
            (-$0.range.length, $0.range.location, $0.term) < (-$1.range.length, $1.range.location, $1.term)
        }
        var selected: [Candidate] = []
        for candidate in prioritized where !selected.contains(where: { $0.range.intersection(candidate.range) != nil }) {
            selected.append(candidate)
        }
        return selected.sorted { $0.range.location < $1.range.location }.compactMap { candidate in
            Range(candidate.range, in: text).map { ($0, terms[candidate.term]) }
        }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: .caseInsensitive, locale: nil)
    }

    private static func wordCharacter(_ character: Character) -> Bool {
        character == "-" || character.unicodeScalars.contains { scalar in
            if scalar.properties.isAlphabetic || scalar == "\u{200C}" || scalar == "\u{200D}" { return true }
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .connectorPunctuation: return true
            default: return false
            }
        }
    }
}
