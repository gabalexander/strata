import Foundation

/// Brief first, detail on demand (docs/manifest.md, Briefs). A node, op, flow, mechanism or level shows
/// its one-line `brief` and keeps its `doc` (narration, summary, a step's note) behind "More". Without a
/// brief, a long text shows an automatic short form: its first sentence, about two lines at most.
/// Shared by the validator (the long-text warning), the CLI and the UI.
public enum Brief {
    /// A text longer than this reads as a paragraph: more characters, or more non-empty lines.
    public static let longCharacters = 280
    public static let longLines = 3
    /// The automatic short form stops here (about two lines of the inspector) and ends in an ellipsis.
    public static let shortFormCharacters = 100
    /// A brief longer than this, or on several lines, is a warning: aim for about 100 characters.
    public static let briefCharacters = 120

    /// What an item shows: `lead` always, `more` behind the disclosure (nil: nothing more to show).
    public struct Parts: Sendable, Equatable {
        public var lead: String
        public var more: String?
        /// The lead is the author's brief, which stays above `more` when expanded. Otherwise it is the
        /// short form of `more`, which `more` replaces.
        public var leadIsBrief: Bool
        public init(lead: String, more: String?, leadIsBrief: Bool) {
            self.lead = lead; self.more = more; self.leadIsBrief = leadIsBrief
        }
    }

    /// The parts to show for an item with an optional brief and an optional longer text. nil when both
    /// are empty. A brief leads and the text waits behind "More"; without one, a short text shows as it
    /// is and a long one leads with its short form.
    public static func parts(brief: String?, detail: String?) -> Parts? {
        let brief = brief.map(trimmed).flatMap { $0.isEmpty ? nil : $0 }
        let detail = detail.map(trimmed).flatMap { $0.isEmpty ? nil : $0 }
        if let brief {
            let more = detail.flatMap { flattened($0) == flattened(brief) ? nil : $0 }
            return Parts(lead: brief, more: more, leadIsBrief: true)
        }
        guard let detail else { return nil }
        guard isLong(detail) else { return Parts(lead: detail, more: nil, leadIsBrief: false) }
        let short = shortForm(detail)
        if flattened(short) == flattened(detail) { return Parts(lead: detail, more: nil, leadIsBrief: false) }
        return Parts(lead: short, more: detail, leadIsBrief: false)
    }

    /// The one line to show where there is room for nothing more (a hover card, the stage's narration
    /// strip): the brief, else the text's short form (the text itself when it is short and on one line).
    public static func line(brief: String?, detail: String?) -> String? {
        if let brief = brief.map(trimmed), !brief.isEmpty { return brief }
        guard let detail = detail.map(trimmed), !detail.isEmpty else { return nil }
        return shortForm(detail)
    }

    /// More than `longCharacters` characters or more than `longLines` non-empty lines.
    public static func isLong(_ text: String) -> Bool {
        let text = trimmed(text)
        return text.count > longCharacters || lineCount(text) > longLines
    }

    /// Non-empty lines, as written.
    public static func lineCount(_ text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    /// What is wrong with a brief, or nil: on several lines, or longer than `briefCharacters`.
    public static func briefProblem(_ brief: String) -> String? {
        let text = trimmed(brief)
        if lineCount(text) > 1 { return "brief is on \(lineCount(text)) lines; keep it to one line of about 100 characters" }
        if text.count > briefCharacters {
            return "brief is \(text.count) characters; keep it to one line of about 100 characters (15 words or so)"
        }
        return nil
    }

    /// The first sentence, its whitespace folded to single spaces, cut at a word to `limit` characters
    /// with an ellipsis. A sentence ends at `.`, `!` or `?` before a space or the end, at a blank line, or
    /// before a list item, but not at a dot inside `code`, a link, a number (0.5, v1.2) or an
    /// abbreviation (e.g., i.e., vs.). A leading list marker or heading mark is dropped, and a sentence
    /// that ends in a colon (an introduction to a list) ends in an ellipsis instead.
    public static func shortForm(_ text: String, limit: Int = shortFormCharacters) -> String {
        var sentence = flattened(firstSentence(text))
        if sentence.hasSuffix(":") { sentence = String(sentence.dropLast()).trimmingCharacters(in: .whitespaces) + "…" }
        guard sentence.count > limit else { return sentence }
        return cut(sentence, to: limit)
    }

    /// The first sentence as written (line breaks kept), with a leading list marker or heading mark dropped.
    public static func firstSentence(_ text: String) -> String {
        let chars = Array(dropMarker(trimmed(text)))
        var index = 0
        var code = false, wiki = false, url = false
        while index < chars.count {
            let c = chars[index]
            if c == "`" { code.toggle(); index += 1; continue }
            if code { index += 1; continue }
            if c == "[", index + 1 < chars.count, chars[index + 1] == "[" { wiki = true; index += 2; continue }
            if wiki {
                if c == "]", index + 1 < chars.count, chars[index + 1] == "]" { wiki = false; index += 2 } else { index += 1 }
                continue
            }
            if c == "]", index + 1 < chars.count, chars[index + 1] == "(" { url = true; index += 2; continue }
            if url {
                if c == ")" { url = false }
                index += 1
                continue
            }
            if c == "\n" {
                // A blank line or a list item on the next line ends the sentence.
                var next = index + 1
                while next < chars.count, chars[next] == " " || chars[next] == "\t" { next += 1 }
                if next >= chars.count || chars[next] == "\n" || startsListItem(chars, at: next) {
                    return String(chars[..<index])
                }
            }
            if c == "." || c == "!" || c == "?" || c == "。" {
                var end = index + 1
                // Closing quotes, brackets and emphasis belong to the sentence.
                while end < chars.count, "\"'”’)]*_".contains(chars[end]) { end += 1 }
                let atBreak = end >= chars.count || chars[end].isWhitespace
                if atBreak, c != "." || endsSentence(chars, dot: index, next: end) {
                    return String(chars[..<end])
                }
            }
            index += 1
        }
        return String(chars)
    }

    // MARK: Helpers

    /// Words that end in a dot but rarely end a sentence.
    /// Not `min`, `max` or `ms`: in a technical text those end sentences ("a TTL of 10 min.").
    private static let abbreviations: Set<String> = [
        "e.g", "i.e", "vs", "cf", "approx", "incl", "excl", "al", "fig", "mr", "mrs", "dr",
        "inc", "ltd", "jr", "sr", "resp", "esp", "viz", "w.r.t", "a.k.a", "aka",
    ]

    /// A dot before whitespace ends a sentence unless it ends an abbreviation, an initial, or an ellipsis.
    /// `etc.` ends one only when a capital letter follows.
    private static func endsSentence(_ chars: [Character], dot: Int, next: Int) -> Bool {
        if dot > 0, chars[dot - 1] == "." { return false }     // "..." is a pause
        var start = dot
        while start > 0, chars[start - 1].isLetter || chars[start - 1] == "." { start -= 1 }
        let word = String(chars[start..<dot]).lowercased()
        if word.isEmpty { return true }                        // after a number, `code` or a bracket
        if abbreviations.contains(word) { return false }
        if word.count == 1, chars[start].isUppercase { return false }   // an initial: "J. Smith"
        if word.contains(".") { return false }                 // "U.S.", "e.g." spelled oddly
        if word == "etc" {
            var after = next
            while after < chars.count, chars[after].isWhitespace { after += 1 }
            return after >= chars.count || chars[after].isUppercase
        }
        return true
    }

    private static func startsListItem(_ chars: [Character], at index: Int) -> Bool {
        guard index < chars.count else { return false }
        if "-*+•".contains(chars[index]) { return index + 1 < chars.count && chars[index + 1] == " " }
        var digit = index
        while digit < chars.count, chars[digit].isNumber { digit += 1 }
        return digit > index && digit + 1 < chars.count && (chars[digit] == "." || chars[digit] == ")") && chars[digit + 1] == " "
    }

    private static func dropMarker(_ text: String) -> String {
        var text = Substring(text)
        if text.hasPrefix("#") {
            text = text.drop { $0 == "#" }
            return text.trimmingCharacters(in: .whitespaces)
        }
        let chars = Array(text.prefix(6))
        if startsListItem(chars, at: 0) {
            text = text.drop { $0 != " " }
            return text.trimmingCharacters(in: .whitespaces)
        }
        if text.hasPrefix("> ") { return String(text.dropFirst(2)) }
        return String(text)
    }

    /// Cuts at the last space before `limit`, never inside `code`, a [[link]], a [link](url) or **bold**,
    /// drops trailing punctuation and adds an ellipsis.
    private static func cut(_ text: String, to limit: Int) -> String {
        var cutPoint = String(text.prefix(limit))
        if let space = cutPoint.lastIndex(of: " ") { cutPoint = String(cutPoint[..<space]) }
        // Back out of anything left open.
        while true {
            if cutPoint.filter({ $0 == "`" }).count % 2 == 1, let tick = cutPoint.lastIndex(of: "`") {
                cutPoint = String(cutPoint[..<tick]); continue
            }
            if let open = cutPoint.range(of: "[[", options: .backwards),
               cutPoint.range(of: "]]", options: .backwards).map({ $0.lowerBound < open.lowerBound }) ?? true {
                cutPoint = String(cutPoint[..<open.lowerBound]); continue
            }
            if let open = linkOpener(in: cutPoint) {
                let rest = cutPoint[open...]
                let target = rest.range(of: "](")
                if !rest.contains("]") || target.map({ !rest[$0.upperBound...].contains(")") }) == true {
                    cutPoint = String(cutPoint[..<open]); continue
                }
            }
            if cutPoint.components(separatedBy: "**").count % 2 == 0, let bold = cutPoint.range(of: "**", options: .backwards) {
                cutPoint = String(cutPoint[..<bold.lowerBound]); continue
            }
            break
        }
        // An aside cut open reads badly: end before its bracket when that keeps most of the text.
        let outside = cutPoint.split(separator: "`", omittingEmptySubsequences: false).enumerated()
            .filter { $0.offset % 2 == 0 }.map(\.element).joined()
        if outside.filter({ $0 == "(" }).count > outside.filter({ $0 == ")" }).count,
           let paren = cutPoint.lastIndex(of: "("), cutPoint.distance(from: cutPoint.startIndex, to: paren) >= limit / 2 {
            cutPoint = String(cutPoint[..<paren])
        }
        let trimmedEnd = cutPoint.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;:—–-(")))
        guard !trimmedEnd.isEmpty else { return String(text.prefix(limit - 1)) + "…" }
        return trimmedEnd + "…"
    }

    /// The last `[` that may open a markdown link: not part of a `[[wiki link]]`.
    private static func linkOpener(in text: String) -> String.Index? {
        var index = text.endIndex
        while index > text.startIndex {
            index = text.index(before: index)
            guard text[index] == "[" else { continue }
            let before = index > text.startIndex ? text[text.index(before: index)] : nil
            let after = text.index(after: index) < text.endIndex ? text[text.index(after: index)] : nil
            if before != "[", after != "[" { return index }
        }
        return nil
    }

    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Whitespace runs, line breaks included, as single spaces.
    static func flattened(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
