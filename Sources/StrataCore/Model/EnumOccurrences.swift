import Foundation

// Finds enum values in a query or a payload (docs/manifest.md, Enums): `status = 3200`,
// `status IN (3100, 3200)`, `SET status = 'paid'`, `INSERT INTO orders (…, status) VALUES (…, 10)`
// and `"status": 3200`, wherever the column or key is linked to an enum. One linear pass over a small
// tokenizer; the UI caches the result per text.

/// One value of an enum-linked column found in a text.
public struct EnumOccurrence: Sendable, Hashable {
    /// The literal as written, quotes included: `3200`, `'paid'`, `"paid"`.
    public var range: Range<String.Index>
    /// The literal without its quotes.
    public var literal: String
    /// The column or key it is compared with or assigned to, as written.
    public var key: String
    public var enumID: String
    /// The value's code, also when the literal is its name; nil when the enum has no such value.
    public var value: String?
    /// The table of the column, when the text named one.
    public var table: String?
    public init(range: Range<String.Index>, literal: String, key: String, enumID: String, value: String?, table: String?) {
        self.range = range; self.literal = literal; self.key = key; self.enumID = enumID; self.value = value; self.table = table
    }
}

public extension Manifest {
    /// The enum values in `text`, a query or a payload, in text order. Columns are looked up on
    /// `level` (every level when it has none of that name), narrowed by the table a column is
    /// qualified with (`o.status`), the tables of its SQL statement, the JSON object it sits in
    /// (`"payment": { "status": … }` → `payments`), then `tables` (what the op names), and last by
    /// which enum knows the literal. A literal no candidate knows is still returned, with a nil
    /// `value`, when exactly one enum is left.
    func enumOccurrences(in text: String, level: Level? = nil, tables: [TableRef] = []) -> [EnumOccurrence] {
        guard !enums.isEmpty else { return [] }
        let everywhere = enumColumns()
        guard !everywhere.isEmpty else { return [] }
        let scanner = EnumScanner(text: text, manifest: self, local: level?.enumColumns() ?? [], everywhere: everywhere,
                                  preferred: tables)
        return scanner.scan()
    }

    /// The enum values in an op's text, preferring the tables the op names.
    func enumOccurrences(in text: String, level: Level, op: Operation, on node: String) -> [EnumOccurrence] {
        let tables = level.tables(touchedBy: op, on: node).compactMap { touched in
            touched.node.map { TableRef(node: $0, table: touched.name) }
        }
        return enumOccurrences(in: text, level: level, tables: tables)
    }
}

private struct EnumToken {
    enum Kind: Equatable {
        case word            // identifier or keyword
        case quotedName      // "…": a JSON string or a SQL quoted identifier
        case string          // '…'
        case number
        case parameter       // $1, :name, ?
        case punct(Character)
        case operatorEquals  // =, <>, !=
    }
    let kind: Kind
    let range: Range<String.Index>
    let text: String         // without quotes for strings
}

private struct EnumScanner {
    let text: String
    let manifest: Manifest
    let local: [EnumColumn]
    let everywhere: [EnumColumn]
    let preferred: [TableRef]

    private static let tableKeywords: Set<String> = ["from", "join", "update", "into"]
    private static let clauseWords: Set<String> = [
        "where", "set", "on", "using", "join", "left", "right", "inner", "outer", "full", "cross", "natural", "lateral",
        "group", "order", "having", "limit", "offset", "returning", "values", "select", "union", "for", "as", "and", "or",
        "default", "window", "fetch", "do", "conflict", "when", "then", "else", "end", "into", "with", "only",
    ]

    func scan() -> [EnumOccurrence] {
        let tokens = tokenize()
        guard !tokens.isEmpty else { return [] }
        var results: [EnumOccurrence] = []
        var seen: Set<Range<String.Index>> = []
        func add(_ occurrence: EnumOccurrence?) {
            guard let occurrence, seen.insert(occurrence.range).inserted else { return }
            results.append(occurrence)
        }

        // SQL statements, split on `;`, each with the tables it names and their aliases.
        var statementStart = 0
        var statements: [(range: Range<Int>, tables: [String], aliases: [String: String])] = []
        for index in 0...tokens.count {
            if index == tokens.count || tokens[index].kind == .punct(";") {
                if index > statementStart {
                    let (tables, aliases) = Self.tables(in: tokens[statementStart..<index])
                    statements.append((statementStart..<index, tables, aliases))
                }
                statementStart = index + 1
            }
        }
        func statement(at index: Int) -> (tables: [String], aliases: [String: String]) {
            statements.first { $0.range.contains(index) }.map { ($0.tables, $0.aliases) } ?? ([], [:])
        }

        // JSON nesting: the key that opened each object or array, innermost last.
        var parents: [String?] = []
        var lastKey: String?
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            switch token.kind {
            case .punct("{"), .punct("["):
                parents.append(lastKey)
                lastKey = nil
            case .punct("}"), .punct("]"):
                if !parents.isEmpty { parents.removeLast() }
                lastKey = nil
            case .punct(","):
                lastKey = nil
            default: break
            }

            // `"key": literal`, `key: literal`
            if token.kind == .quotedName || token.kind == .word, index + 2 < tokens.count, tokens[index + 1].kind == .punct(":"),
               !(index + 2 < tokens.count && tokens[index + 2].kind == .punct(":")) {
                let key = token.text
                lastKey = key
                let value = tokens[index + 2]
                if Self.isLiteral(value) || value.kind == .quotedName {
                    add(resolve(key: key, qualifier: nil, literal: value, sql: nil, json: parents.compactMap { $0 }.reversed()))
                }
                index += 2
                continue
            }

            // `[qualifier.]column = literal`, `column <> literal`, `column [NOT] IN (literal, …)`
            if token.kind == .word || token.kind == .quotedName {
                var qualifier: String?
                var column = token
                var next = index + 1
                if next + 1 < tokens.count, tokens[next].kind == .punct("."),
                   tokens[next + 1].kind == .word || tokens[next + 1].kind == .quotedName {
                    qualifier = token.text
                    column = tokens[next + 1]
                    next += 2
                }
                if next < tokens.count, tokens[next].kind == .operatorEquals, next + 1 < tokens.count, Self.isLiteral(tokens[next + 1]) {
                    add(resolve(key: column.text, qualifier: qualifier, literal: tokens[next + 1], sql: statement(at: index), json: []))
                    index = next + 2
                    continue
                }
                var inIndex = next
                if inIndex < tokens.count, tokens[inIndex].kind == .word, tokens[inIndex].text.lowercased() == "not" { inIndex += 1 }
                if inIndex + 1 < tokens.count, tokens[inIndex].kind == .word, tokens[inIndex].text.lowercased() == "in",
                   tokens[inIndex + 1].kind == .punct("(") {
                    var cursor = inIndex + 2
                    let context = statement(at: index)
                    while cursor < tokens.count, tokens[cursor].kind != .punct(")") {
                        if Self.isLiteral(tokens[cursor]) {
                            add(resolve(key: column.text, qualifier: qualifier, literal: tokens[cursor], sql: context, json: []))
                        } else if tokens[cursor].kind != .punct(",") {
                            break   // a subquery or an expression
                        }
                        cursor += 1
                    }
                    index = cursor
                    continue
                }
            }

            // `INSERT INTO table (a, b, c) VALUES (x, y, z), (…)`
            if token.kind == .word, token.text.lowercased() == "insert" {
                for occurrence in insertValues(tokens, from: index, context: statement(at: index)) { add(occurrence) }
            }
            index += 1
        }
        return results.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    // MARK: Resolution

    private func resolve(key: String, qualifier: String?, literal token: EnumToken,
                         sql: (tables: [String], aliases: [String: String])?, json: [String]) -> EnumOccurrence? {
        let name = key.lowercased()
        var candidates = local.filter { $0.column.column.lowercased() == name }
        if candidates.isEmpty { candidates = everywhere.filter { $0.column.column.lowercased() == name } }
        guard !candidates.isEmpty else { return nil }
        // Whether the text itself says which table the column belongs to; only then is a literal
        // the enum doesn't know worth pointing out.
        var named = false
        if let qualifier {
            let table = (sql?.aliases[qualifier.lowercased()] ?? qualifier).lowercased()
            candidates = candidates.filter { $0.column.table.lowercased() == table }
            guard !candidates.isEmpty else { return nil }
            named = true
        } else if let sql, !sql.tables.isEmpty {
            // The statement names its tables: a column of another table isn't this one.
            let tables = Set(sql.tables)
            candidates = candidates.filter { tables.contains($0.column.table.lowercased()) }
            guard !candidates.isEmpty else { return nil }
            named = true
        }
        for parent in json {
            let narrowed = candidates.filter { Self.tableMatches($0.column.table, key: parent) }
            if !narrowed.isEmpty { candidates = narrowed; named = true; break }
        }
        // The op's tables are a preference: a column of another table that knows the literal still wins
        // over one of the op's that doesn't.
        let preferredTables = Set(preferred)
        let byOp = candidates.filter { preferredTables.contains($0.column.tableRef) }
        let literal = token.text
        for candidate in byOp + candidates {
            if let value = manifest.enumDef(candidate.enumID)?.resolve(literal) {
                return EnumOccurrence(range: token.range, literal: literal, key: key, enumID: candidate.enumID,
                                      value: value.value, table: candidate.column.table)
            }
        }
        if !byOp.isEmpty { candidates = byOp; named = true }
        let ids = Set(candidates.map(\.enumID))
        guard named, ids.count == 1, let only = candidates.first, manifest.enumDef(only.enumID) != nil else { return nil }
        let table = Set(candidates.map(\.column.table)).count == 1 ? only.column.table : nil
        return EnumOccurrence(range: token.range, literal: literal, key: key, enumID: only.enumID, value: nil, table: table)
    }

    /// `payment` or `payments` names the table `payments`; `order` names `orders`.
    private static func tableMatches(_ table: String, key: String) -> Bool {
        let t = table.lowercased(), k = key.lowercased()
        return t == k || t == k + "s" || t == k + "es" || k == t + "s" || (t.hasSuffix("ies") && k == String(t.dropLast(3)) + "y")
    }

    private static func isLiteral(_ token: EnumToken) -> Bool {
        token.kind == .number || token.kind == .string
    }

    // MARK: SQL structure

    /// The tables a statement names after FROM, JOIN, UPDATE and INTO, lowercased, with their aliases.
    private static func tables(in tokens: ArraySlice<EnumToken>) -> ([String], [String: String]) {
        var tables: [String] = []
        var aliases: [String: String] = [:]
        let list = Array(tokens)
        var index = 0
        while index < list.count {
            defer { index += 1 }
            guard list[index].kind == .word, tableKeywords.contains(list[index].text.lowercased()) else { continue }
            var cursor = index + 1
            // `FROM a, b`: a list of tables, each with an optional alias.
            while cursor < list.count {
                guard list[cursor].kind == .word || list[cursor].kind == .quotedName else { break }
                var name = list[cursor].text
                cursor += 1
                while cursor + 1 < list.count, list[cursor].kind == .punct("."),
                      list[cursor + 1].kind == .word || list[cursor + 1].kind == .quotedName {
                    name = list[cursor + 1].text   // schema.table → table
                    cursor += 2
                }
                let table = name.lowercased()
                if clauseWords.contains(table) { break }
                tables.append(table)
                aliases[table] = table
                if cursor < list.count, list[cursor].kind == .word, list[cursor].text.lowercased() == "as" { cursor += 1 }
                if cursor < list.count, list[cursor].kind == .word, !clauseWords.contains(list[cursor].text.lowercased()) {
                    aliases[list[cursor].text.lowercased()] = table
                    cursor += 1
                }
                guard cursor < list.count, list[cursor].kind == .punct(",") else { break }
                cursor += 1
            }
        }
        return (tables, aliases)
    }

    /// The literals of `INSERT INTO t (columns) VALUES (row), (row)`, matched to their columns by position.
    private func insertValues(_ tokens: [EnumToken], from start: Int,
                              context: (tables: [String], aliases: [String: String])) -> [EnumOccurrence] {
        var cursor = start + 1
        guard cursor < tokens.count, tokens[cursor].kind == .word, tokens[cursor].text.lowercased() == "into" else { return [] }
        cursor += 1
        while cursor < tokens.count, tokens[cursor].kind != .punct("(") {
            if tokens[cursor].kind == .punct(";") { return [] }
            cursor += 1
        }
        var columns: [String] = []
        cursor += 1
        while cursor < tokens.count, tokens[cursor].kind != .punct(")") {
            if tokens[cursor].kind == .word || tokens[cursor].kind == .quotedName { columns.append(tokens[cursor].text) }
            else if tokens[cursor].kind != .punct(",") { return [] }
            cursor += 1
        }
        cursor += 1
        guard cursor < tokens.count, tokens[cursor].kind == .word, tokens[cursor].text.lowercased() == "values" else { return [] }
        cursor += 1
        var results: [EnumOccurrence] = []
        // Each row: values split on top-level commas; a value that is one literal maps to its column.
        while cursor < tokens.count, tokens[cursor].kind == .punct("(") {
            cursor += 1
            var depth = 0
            var position = 0
            var item: [EnumToken] = []
            func flush() {
                if item.count == 1, Self.isLiteral(item[0]), columns.indices.contains(position),
                   let hit = resolve(key: columns[position], qualifier: nil, literal: item[0], sql: context, json: []) {
                    results.append(hit)
                }
                item.removeAll()
                position += 1
            }
            while cursor < tokens.count {
                let token = tokens[cursor]
                if token.kind == .punct("(") { depth += 1 }
                if token.kind == .punct(")") {
                    if depth == 0 { break }
                    depth -= 1
                }
                if token.kind == .punct(","), depth == 0 { flush() } else { item.append(token) }
                cursor += 1
            }
            flush()
            cursor += 1
            guard cursor < tokens.count, tokens[cursor].kind == .punct(",") else { break }
            cursor += 1
        }
        return results
    }

    // MARK: Tokens

    private func tokenize() -> [EnumToken] {
        var tokens: [EnumToken] = []
        var i = text.startIndex
        let end = text.endIndex
        func peek(_ offset: Int = 1) -> Character? {
            var j = i
            for _ in 0..<offset {
                guard j < end else { return nil }
                j = text.index(after: j)
            }
            return j < end ? text[j] : nil
        }
        while i < end {
            let c = text[i]
            if c.isWhitespace { i = text.index(after: i); continue }
            if c == "-", peek() == "-" {
                while i < end, text[i] != "\n" { i = text.index(after: i) }
                continue
            }
            if c == "/", peek() == "*" {
                i = text.index(i, offsetBy: 2)
                while i < end, !(text[i] == "*" && peek() == "/") { i = text.index(after: i) }
                i = i < end ? text.index(i, offsetBy: 2, limitedBy: end) ?? end : end
                continue
            }
            let start = i
            if c == "'" || c == "\"" {
                var value = ""
                var j = text.index(after: i)
                var closed = false
                while j < end {
                    let d = text[j]
                    if c == "\"", d == "\\" {
                        let k = text.index(after: j)
                        if k < end { value.append(text[k]); j = text.index(after: k) } else { j = k }
                        continue
                    }
                    if d == c {
                        let k = text.index(after: j)
                        if c == "'", k < end, text[k] == "'" { value.append("'"); j = text.index(after: k); continue }
                        j = k
                        closed = true
                        break
                    }
                    value.append(d)
                    j = text.index(after: j)
                }
                guard closed else { break }
                tokens.append(EnumToken(kind: c == "'" ? .string : .quotedName, range: start..<j, text: value))
                i = j
                continue
            }
            if c.isNumber || (c == "-" && (peek()?.isNumber ?? false) && !Self.followsValue(tokens)) {
                var j = text.index(after: i)
                while j < end, text[j].isNumber || text[j] == "." || text[j] == "_" { j = text.index(after: j) }
                // `3200abc` is a word, not a number.
                if j < end, text[j].isLetter {
                    while j < end, text[j].isLetter || text[j].isNumber || text[j] == "_" { j = text.index(after: j) }
                    tokens.append(EnumToken(kind: .word, range: start..<j, text: String(text[start..<j])))
                } else {
                    tokens.append(EnumToken(kind: .number, range: start..<j, text: String(text[start..<j])))
                }
                i = j
                continue
            }
            if c.isLetter || c == "_" {
                var j = text.index(after: i)
                while j < end, text[j].isLetter || text[j].isNumber || text[j] == "_" { j = text.index(after: j) }
                tokens.append(EnumToken(kind: .word, range: start..<j, text: String(text[start..<j])))
                i = j
                continue
            }
            if c == "$" || (c == ":" && (peek()?.isLetter ?? false) && tokens.last?.kind != .punct(":") && !Self.followsKey(tokens)) {
                var j = text.index(after: i)
                while j < end, text[j].isLetter || text[j].isNumber || text[j] == "_" { j = text.index(after: j) }
                tokens.append(EnumToken(kind: .parameter, range: start..<j, text: String(text[start..<j])))
                i = j
                continue
            }
            if c == "?" {
                tokens.append(EnumToken(kind: .parameter, range: start..<text.index(after: i), text: "?"))
                i = text.index(after: i)
                continue
            }
            if c == "=" || (c == "<" && peek() == ">") || (c == "!" && peek() == "=") {
                let j = text.index(i, offsetBy: c == "=" ? 1 : 2)
                tokens.append(EnumToken(kind: .operatorEquals, range: start..<j, text: String(text[start..<j])))
                i = j
                continue
            }
            tokens.append(EnumToken(kind: .punct(c), range: start..<text.index(after: i), text: String(c)))
            i = text.index(after: i)
        }
        return tokens
    }

    /// `a - 1` subtracts: a minus right after a value is an operator, not a sign.
    private static func followsValue(_ tokens: [EnumToken]) -> Bool {
        guard let last = tokens.last else { return false }
        switch last.kind {
        case .word, .number, .string, .quotedName, .parameter, .punct(")"), .punct("]"): return true
        default: return false
        }
    }

    /// `key: value` in a payload: the colon after a key is punctuation, not a `:name` parameter.
    private static func followsKey(_ tokens: [EnumToken]) -> Bool {
        guard let last = tokens.last else { return false }
        return last.kind == .quotedName || last.kind == .word
    }
}
