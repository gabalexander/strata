import Foundation

// Fills an op's placeholders with a journey step's binds (docs/manifest.md, Journeys), so the player
// and `strata journey` show the query that really ran: `?` and `$1` take positional binds, `@name`,
// `:name`, `sqlc.arg(name)` and `$1` named ones; `{name}` in a key pattern, a path or a payload too.

public enum JourneyFill {
    /// One placeholder as written, in order of appearance.
    public struct Placeholder: Sendable, Hashable {
        public enum Kind: Sendable, Hashable { case question, numbered(Int), named(String) }
        public var kind: Kind
        public var text: String
        public var range: Range<String.Index>
    }

    public struct Result: Sendable {
        public var text: String
        /// Placeholders in order, each once (`?`, `$1`, `@task_sid`).
        public var placeholders: [String]
        /// Placeholders no bind filled.
        public var unfilled: [String]
        /// Binds no placeholder used: `#3` for a positional one, else its name.
        public var unused: [String]
    }

    /// Placeholders in SQL, skipping strings, quoted identifiers and comments; `::` casts and `@>`
    /// operators aren't placeholders.
    public static func sqlPlaceholders(_ query: String) -> [Placeholder] {
        var found: [Placeholder] = []
        let chars = Array(query.indices)
        var i = 0
        func char(_ k: Int) -> Character? { k < chars.count ? query[chars[k]] : nil }
        func isWord(_ c: Character?) -> Bool { c.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false }
        func end(_ k: Int) -> String.Index { k < chars.count ? chars[k] : query.endIndex }
        while i < chars.count {
            let c = query[chars[i]]
            switch c {
            case "'", "\"":
                var k = i + 1
                while k < chars.count {
                    if query[chars[k]] == c {
                        if char(k + 1) == c { k += 2; continue }
                        break
                    }
                    k += 1
                }
                i = k + 1
            case "-" where char(i + 1) == "-":
                while i < chars.count, query[chars[i]] != "\n" { i += 1 }
            case "/" where char(i + 1) == "*":
                var k = i + 2
                while k < chars.count, !(query[chars[k]] == "*" && char(k + 1) == "/") { k += 1 }
                i = k + 2
            case "?":
                found.append(Placeholder(kind: .question, text: "?", range: chars[i]..<end(i + 1)))
                i += 1
            case "$":
                var k = i + 1
                while let d = char(k), d.isNumber { k += 1 }
                if k > i + 1, !isWord(char(k)), let n = Int(String(query[chars[i + 1]..<end(k)])) {
                    found.append(Placeholder(kind: .numbered(n), text: String(query[chars[i]..<end(k)]), range: chars[i]..<end(k)))
                } else if char(i + 1) == "$" {
                    // A dollar-quoted body: skip to the closing $$.
                    var close = i + 2
                    while close < chars.count, !(query[chars[close]] == "$" && char(close + 1) == "$") { close += 1 }
                    k = close + 2
                }
                i = max(k, i + 1)
            case "@", ":":
                let previous = i > 0 ? query[chars[i - 1]] : nil
                let next = char(i + 1)
                if c == ":" && (previous == ":" || next == ":") { i += 1; continue }
                if isWord(previous) && c == ":" { i += 1; continue }
                guard let first = next, first.isLetter || first == "_" else { i += 1; continue }
                var k = i + 1
                while isWord(char(k)) { k += 1 }
                let name = String(query[chars[i + 1]..<end(k)])
                found.append(Placeholder(kind: .named(name), text: String(query[chars[i]..<end(k)]), range: chars[i]..<end(k)))
                i = k
            case "s" where !isWord(i > 0 ? query[chars[i - 1]] : nil):
                // sqlc.arg(name), sqlc.narg(name), sqlc.slice(name), with or without quotes.
                let rest = query[chars[i]...]
                if let match = rest.range(of: #"^sqlc\.(n?arg|slice)\(\s*'?([A-Za-z_][A-Za-z0-9_]*)'?\s*\)"#, options: .regularExpression) {
                    let text = String(rest[match])
                    let name = text.replacingOccurrences(of: #"^sqlc\.(n?arg|slice)\(\s*'?|'?\s*\)$"#, with: "", options: .regularExpression)
                    found.append(Placeholder(kind: .named(name), text: text, range: match))
                    i += text.count
                } else {
                    i += 1
                }
            default:
                i += 1
            }
        }
        return found
    }

    /// `{name}` segments of a key pattern, a path or a payload.
    public static func bracePlaceholders(_ text: String) -> [Placeholder] {
        guard let regex = try? NSRegularExpression(pattern: #"\{([A-Za-z_][A-Za-z0-9_.-]*)\}"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let whole = Range(match.range, in: text), let name = Range(match.range(at: 1), in: text) else { return nil }
            return Placeholder(kind: .named(String(text[name])), text: String(text[whole]), range: whole)
        }
    }

    /// The query with every placeholder a bind fills replaced by its SQL literal.
    public static func sql(_ query: String, binds: [JourneyBind]) -> Result {
        fill(query, placeholders: sqlPlaceholders(query), binds: binds, render: literal)
    }

    /// A key pattern, path or payload with `{name}` replaced by the bind's text as is.
    public static func braces(_ text: String, binds: [JourneyBind]) -> Result {
        fill(text, placeholders: bracePlaceholders(text), binds: binds) { $0.value ?? "null" }
    }

    private static func fill(_ text: String, placeholders: [Placeholder], binds: [JourneyBind],
                             render: (JourneyBind) -> String) -> Result {
        let positional = binds.filter { $0.name == nil }
        var named: [String: JourneyBind] = [:]
        for bind in binds { if let name = bind.name { named[name] = bind } }
        var output = ""
        var cursor = text.startIndex
        var question = 0
        var usedPositions: Set<Int> = []
        var usedNames: Set<String> = []
        var seen: [String] = []
        var unfilled: [String] = []
        // Unnamed `{}`-less braces fill in order from a positional list too.
        var braceOrder = 0
        for placeholder in placeholders {
            if !seen.contains(placeholder.text) || placeholder.kind == .question { seen.append(placeholder.text) }
            var bind: JourneyBind?
            switch placeholder.kind {
            case .question:
                if question < positional.count { bind = positional[question]; usedPositions.insert(question) }
                question += 1
            case .numbered(let n):
                if let found = named[placeholder.text] ?? named[String(n)] {
                    bind = found; usedNames.insert(named[placeholder.text] != nil ? placeholder.text : String(n))
                } else if n >= 1, n <= positional.count {
                    bind = positional[n - 1]; usedPositions.insert(n - 1)
                }
            case .named(let name):
                if let found = named[name] ?? named[placeholder.text] {
                    bind = found; usedNames.insert(named[name] != nil ? name : placeholder.text)
                } else if named.isEmpty, braceOrder < positional.count, placeholder.text.hasPrefix("{") {
                    bind = positional[braceOrder]; usedPositions.insert(braceOrder)
                }
                if placeholder.text.hasPrefix("{") { braceOrder += 1 }
            }
            output += text[cursor..<placeholder.range.lowerBound]
            if let bind {
                output += render(bind)
            } else {
                output += placeholder.text
                if !unfilled.contains(placeholder.text) { unfilled.append(placeholder.text) }
            }
            cursor = placeholder.range.upperBound
        }
        output += text[cursor...]
        let unused = positional.indices.filter { !usedPositions.contains($0) }.map { "#\($0 + 1)" }
            + binds.compactMap(\.name).filter { !usedNames.contains($0) }
        var unique: [String] = []
        for text in seen where !unique.contains(text) || text == "?" { unique.append(text) }
        return Result(text: output, placeholders: unique, unfilled: unfilled, unused: placeholders.isEmpty ? [] : unused)
    }

    /// A bind as an SQL literal: NULL, a number or boolean as written, a function call (`now()`) as
    /// written, anything else (and anything written quoted) as a quoted string.
    public static func literal(_ bind: JourneyBind) -> String {
        guard let value = bind.value else { return "NULL" }
        if !bind.quoted {
            if Syntax.number(value) != nil { return value }
            switch value.lowercased() {
            case "true", "false": return value.uppercased()
            case "null": return "NULL"
            default: break
            }
            if value.range(of: #"^[A-Za-z_][A-Za-z0-9_.]*\(.*\)$"#, options: .regularExpression) != nil { return value }
            if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 { return value }
        }
        return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
