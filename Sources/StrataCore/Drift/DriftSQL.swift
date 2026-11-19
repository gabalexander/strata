import Foundation

/// SQL: each op's `query` against the repo's queries. A query with a sqlc `-- name:` line is looked up
/// by name and its body compared; any other statement is looked up by its normalised text: comments,
/// whitespace and keyword case don't count, `?`, `$1`, `:name`, `@name` and `sqlc.arg(x)` are the same
/// placeholder, and a second, looser pass treats literals as placeholders too (a map may show example
/// values). Repo queries come from sqlc `.sql` files and from SQL string literals in Go code (with
/// `"…" + "…"` joined); those no op covers are reported as unmapped, by file.
enum DriftSQL {
    struct Named: Equatable { var name: String; var command: String? }

    /// One normalised statement.
    struct Statement {
        /// The source text of the statement.
        var text: String
        var exact: [String]
        var loose: [String]
        var verb: String
        var exactKey: String { exact.joined(separator: " ") }
        var looseKey: String { loose.joined(separator: " ") }
    }

    /// A query in the repo: a sqlc block or a SQL string literal (or a plain statement of a `.sql` file).
    struct RepoQuery {
        var file: String
        var line: Int
        var name: String?
        var command: String?
        var body: String
        var statements: [Statement]
        var origin: Origin
        enum Origin { case sqlc, literal, file }
        var location: DriftRepoLocation { DriftRepoLocation(file: file, line: line) }
        var title: String {
            if let name { return name + (command.map { " " + $0 } ?? "") }
            return statements.first.map { String(DriftSQL.oneLine($0.text).prefix(70)) } ?? "query"
        }
    }

    // MARK: sqlc names

    /// The `-- name: GetX :one` lines of a query.
    static func sqlcNames(in query: String) -> [Named] {
        query.split(separator: "\n").compactMap { sqlcName(String($0)) }
    }

    static func sqlcName(_ line: String) -> Named? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("--") else { return nil }
        let rest = text.dropFirst(2).trimmingCharacters(in: .whitespaces)
        guard rest.lowercased().hasPrefix("name:") else { return nil }
        let words = rest.dropFirst(5).split(separator: " ").map(String.init)
        guard let name = words.first, DriftMapFacts.isIdentifier(name) else { return nil }
        return Named(name: name, command: words.dropFirst().first { $0.hasPrefix(":") })
    }

    /// A query split at its `-- name:` lines: the text before the first one (unnamed), then each named body.
    static func segments(_ query: String) -> [(named: Named?, body: String)] {
        var out: [(Named?, String)] = []
        var current: Named?
        var lines: [Substring] = []
        func flush() {
            let body = lines.joined(separator: "\n")
            if current != nil || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append((current, body)) }
            lines = []
        }
        for line in query.split(separator: "\n", omittingEmptySubsequences: false) {
            if let named = sqlcName(String(line)) {
                flush()
                current = named
            } else {
                lines.append(line)
            }
        }
        flush()
        return out
    }

    // MARK: Normalisation

    /// The statements of a query, transaction control (`BEGIN`, `COMMIT`) and empty ones dropped.
    static func statements(_ source: String) -> [Statement] {
        SQLFormat.split(SQLFormat.tokens(source)).compactMap { tokens in
            let significant = tokens.filter { !$0.isComment && $0.kind != .semicolon }
            guard let first = significant.first(where: { $0.kind == .word }) else { return nil }
            let verb = first.text.lowercased()
            if ["begin", "commit", "rollback", "end", "savepoint", "release", "abort", "start"].contains(verb) && significant.count <= 3 {
                return nil
            }
            let (exact, loose) = canonical(significant)
            guard exact.count >= 2 else { return nil }
            return Statement(text: rawText(tokens), exact: exact, loose: loose, verb: verb)
        }
    }

    static func canonical(_ tokens: [SQLFormat.Token]) -> (exact: [String], loose: [String]) {
        var exact: [String] = [], loose: [String] = []
        var i = 0
        func emit(_ text: String, loose looseText: String? = nil) { exact.append(text); loose.append(looseText ?? text) }
        while i < tokens.count {
            let token = tokens[i]
            switch token.kind {
            case .lineComment, .blockComment, .semicolon:
                break
            case .word:
                let word = token.text.lowercased()
                // sqlc.arg(name), sqlc.narg(name), sqlc.slice(name): one placeholder.
                if word == "sqlc", i + 3 < tokens.count, tokens[i + 1].kind == .dot, tokens[i + 3].kind == .open {
                    var depth = 0, j = i + 3
                    while j < tokens.count {
                        if tokens[j].kind == .open { depth += 1 }
                        if tokens[j].kind == .close { depth -= 1; if depth == 0 { break } }
                        j += 1
                    }
                    emit("?")
                    i = j
                } else {
                    emit(word)
                }
            case .quoted:
                emit(String(token.text.dropFirst().dropLast()).lowercased())
            case .parameter:
                emit("?")
            case .string:
                emit(token.text, loose: "?")
            case .number:
                emit(token.text, loose: "?")
            case .symbol:
                // Go's fmt verbs in dynamic SQL (`%s`) are placeholders too.
                if token.text == "%", i + 1 < tokens.count, tokens[i + 1].kind == .word, !tokens[i + 1].spaceBefore,
                   ["s", "d", "v", "q"].contains(tokens[i + 1].text) {
                    emit("?")
                    i += 1
                } else {
                    emit(token.text == "<>" ? "!=" : token.text)
                }
            default:
                emit(token.text)
            }
            i += 1
        }
        // `IN (?, ?, ?)` and `IN (?)` (sqlc.slice) read the same when literals are placeholders.
        var collapsed: [String] = []
        var k = 0
        while k < loose.count {
            if loose[k] == "(", k + 2 < loose.count, loose[k + 1] == "?" {
                var j = k + 2
                while j + 1 < loose.count, loose[j] == ",", loose[j + 1] == "?" { j += 2 }
                if j < loose.count, loose[j] == ")" {
                    collapsed += ["(", "?", ")"]
                    k = j + 1
                    continue
                }
            }
            collapsed.append(loose[k])
            k += 1
        }
        return (exact, collapsed)
    }

    /// The same statement up to example values: tokens equal, or a literal where the other side has a
    /// placeholder, and lists of values read as one placeholder. Two different literals are a change.
    static func compatible(_ a: [String], _ b: [String]) -> Bool {
        func isLiteral(_ token: String) -> Bool {
            guard let first = token.first else { return false }
            return first == "'" || first.isNumber || token.hasPrefix("$$") || (token.count > 1 && "eEbBxXnN".contains(first) && token.dropFirst().first == "'")
        }
        func collapse(_ tokens: [String]) -> [String] {
            var out: [String] = []
            var k = 0
            while k < tokens.count {
                if tokens[k] == "(", k + 2 < tokens.count, tokens[k + 1] == "?" || isLiteral(tokens[k + 1]) {
                    var j = k + 2
                    while j + 1 < tokens.count, tokens[j] == ",", tokens[j + 1] == "?" || isLiteral(tokens[j + 1]) { j += 2 }
                    if j < tokens.count, tokens[j] == ")", j > k + 2 || tokens[k + 1] == "?" {
                        out += ["(", "?", ")"]
                        k = j + 1
                        continue
                    }
                }
                out.append(tokens[k])
                k += 1
            }
            return out
        }
        let x = collapse(a), y = collapse(b)
        guard x.count == y.count else { return false }
        return zip(x, y).allSatisfy { p, q in p == q || isLiteral(p) && q == "?" || p == "?" && isLiteral(q) }
    }

    private static func rawText(_ tokens: [SQLFormat.Token]) -> String {
        var out = ""
        for (i, token) in tokens.enumerated() {
            if i > 0 { out += token.newlineBefore ? "\n" : token.spaceBefore ? " " : "" }
            out += token.text
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0 == "\n" || $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    // MARK: Repo queries

    private static let verbs: Set<String> = ["select", "insert", "update", "delete", "with", "merge", "upsert"]
    private static let dangling: Set<String> = ["where", "and", "or", "set", "from", "join", "on", "by", "values", "in", "select", "not", "into", "as", "having", "limit", "offset"]
    private static let prose: Set<String> = ["the", "failed", "failure", "error", "could", "cannot", "unable", "please", "should", "would", "couldn't", "can't", "don't"]

    /// A string literal that is a whole DML statement rather than a message that starts with "update".
    static func looksLikeQuery(_ text: String) -> Bool {
        guard text.utf8.count >= 12, text.utf8.count < 40_000 else { return false }
        let start = text.drop { $0.isWhitespace }
        let first = start.prefix { $0.isLetter }.lowercased()
        guard verbs.contains(first) else { return false }
        let tokens = SQLFormat.tokens(String(start)).filter { !$0.isComment }
        // A fragment the code completes (`"SELECT * FROM t WHERE " + cond`) isn't a query of its own.
        if let last = tokens.last(where: { $0.kind != .semicolon }),
           last.kind == .word && dangling.contains(last.text.lowercased()) || [",", "=", "("].contains(last.text) { return false }
        let words = tokens.filter { $0.kind == .word }.map { $0.text.lowercased() }
        let set = Set(words)
        guard set.isDisjoint(with: prose), SQLFormat.incompleteStatements(String(start)).isEmpty else { return false }
        let hasValue = tokens.contains { [.parameter, .number, .string].contains($0.kind) || $0.text == "=" }
        switch first {
        case "select": return set.contains("from") && words.count >= 4 || hasValue && tokens.contains { $0.kind == .open }
        case "insert", "upsert": return set.contains("into") && (set.contains("values") || set.contains("select") || set.contains("default"))
        case "update": return set.contains("set") && tokens.contains { $0.text == "=" }
        case "delete": return set.contains("from") && (!set.isDisjoint(with: ["where", "returning", "using"]) || words.count == 3)
        case "with": return set.contains("as") && tokens.contains { $0.kind == .open } && !set.isDisjoint(with: ["select", "insert", "update", "delete"])
        default: return set.contains("into") || set.contains("using")
        }
    }

    static func repoQueries(_ repo: DriftRepo) -> [RepoQuery] {
        var out: [RepoQuery] = []
        for file in repo.sqlFiles {
            guard let lines = repo.lines(file) else { continue }
            var current: (named: Named, line: Int)?
            var body: [Substring] = []
            var sqlc = false
            func flush() {
                guard let named = current?.named, let line = current?.line else { return }
                let text = body.joined(separator: "\n")
                out.append(RepoQuery(file: file, line: line, name: named.name, command: named.command, body: text,
                                     statements: statements(text), origin: .sqlc))
            }
            for (index, line) in lines.enumerated() {
                if let named = sqlcName(String(line)) {
                    flush()
                    sqlc = true
                    current = (named, index + 1)
                    body = []
                } else {
                    body.append(line)
                }
            }
            flush()
            if !sqlc, let text = repo.text(file) {
                // A plain .sql file (embedded queries, a report): its DML statements can match ops, but
                // aren't reported as unmapped (migrations and seeds live in files like this too).
                for statement in statements(text) where verbs.contains(statement.verb) {
                    let offset = text.range(of: statement.text).map { text[..<$0.lowerBound].filter { $0 == "\n" }.count + 1 } ?? 1
                    out.append(RepoQuery(file: file, line: offset, body: statement.text, statements: [statement], origin: .file))
                }
            }
        }
        let code = repo.goSources + repo.files.filter { DriftRepo.otherCodeExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
        for file in code {
            for literal in repo.literals(file) where looksLikeQuery(literal.text) {
                let parsed = statements(literal.text)
                guard !parsed.isEmpty else { continue }
                let origin: RepoQuery.Origin = file.hasSuffix(".go") ? .literal : .file
                out.append(RepoQuery(file: file, line: literal.line, body: literal.text, statements: parsed, origin: origin))
            }
        }
        return out
    }

    // MARK: Check

    private struct Match {
        var query: Int
        var statement: Int
        var similarity: Double   // 1 for exact and loose matches
    }

    static func run(_ context: DriftContext) {
        let queries = repoQueries(context.repo)
        var exactIndex: [String: [(Int, Int)]] = [:], looseIndex: [String: [(Int, Int)]] = [:]
        var byName: [String: [Int]] = [:]
        var wordSets: [[Set<String>]] = []
        for (q, query) in queries.enumerated() {
            if let name = query.name, query.origin == .sqlc { byName[name, default: []].append(q) }
            for (s, statement) in query.statements.enumerated() {
                exactIndex[statement.exactKey, default: []].append((q, s))
                looseIndex[statement.looseKey, default: []].append((q, s))
            }
            wordSets.append(query.statements.map { Set($0.loose) })
        }
        var covered = Set<Int>()

        func find(_ statement: Statement, preferring files: Set<String>) -> Match? {
            func pick(_ hits: [(Int, Int)]) -> Match? {
                let best = hits.first { files.contains(queries[$0.0].file) } ?? hits.first
                return best.map { Match(query: $0.0, statement: $0.1, similarity: 1) }
            }
            if let hit = pick(exactIndex[statement.exactKey] ?? []) { return hit }
            // Same shape: a match when only example values differ, a change when a literal does.
            let shaped = looseIndex[statement.looseKey] ?? []
            if let hit = pick(shaped.filter { compatible(statement.exact, queries[$0.0].statements[$0.1].exact) }) { return hit }
            if var hit = pick(shaped) { hit.similarity = 0.99; return hit }
            // Closest statement with the same verb: a quick token-set filter, then an ordered comparison.
            let words = Set(statement.loose)
            var shortlist: [(q: Int, s: Int, jaccard: Double)] = []
            for (q, query) in queries.enumerated() {
                for (s, other) in query.statements.enumerated() where other.verb == statement.verb {
                    let set = wordSets[q][s]
                    let union = words.union(set).count
                    guard union > 0 else { continue }
                    let jaccard = Double(words.intersection(set).count) / Double(union) + (files.contains(query.file) ? 0.05 : 0)
                    if jaccard >= 0.5 { shortlist.append((q, s, jaccard)) }
                }
            }
            shortlist.sort { $0.jaccard != $1.jaccard ? $0.jaccard > $1.jaccard : ($0.q, $0.s) < ($1.q, $1.s) }
            var best: Match?
            for candidate in shortlist.prefix(6) {
                let similarity = ratio(statement.loose, queries[candidate.q].statements[candidate.s].loose)
                if similarity >= 0.75, similarity > (best?.similarity ?? 0) { best = Match(query: candidate.q, statement: candidate.s, similarity: similarity) }
            }
            return best
        }

        let haveSQL = !queries.isEmpty
        for fact in context.facts.sql {
            guard let query = fact.op.query else { continue }
            context.checked(.sql)
            let key = "sql|\(fact.location)"
            let files = Set(fact.code.compactMap { DriftCode.parse($0, root: context.repo.rootPath)?.path })
            var reported = false
            for segment in segments(query) where !reported {
                let mapStatements = statements(segment.body)
                if let named = segment.named {
                    if let q = byName[named.name]?.sorted(by: { files.contains(queries[$0].file) && !files.contains(queries[$1].file) }).first {
                        covered.insert(q)
                        let repoQuery = queries[q]
                        let same = mapStatements.count == repoQuery.statements.count
                            && zip(mapStatements, repoQuery.statements).allSatisfy { $0.exactKey == $1.exactKey || compatible($0.exact, $1.exact) }
                        if !same {
                            context.add(DriftFinding(.warn, .sql, "query-changed",
                                                     message: "\(named.name) changed in \(repoQuery.file)",
                                                     fix: "Copy the query from \(repoQuery.location) into query: (keep its -- name: line).",
                                                     map: fact.location, repo: repoQuery.location, ref: named.name,
                                                     diff: diff(segment.body, repoQuery.body)), fact: key)
                            reported = true
                        }
                        continue
                    }
                    // The name is gone: the same text under another name is a rename.
                    let matches = mapStatements.compactMap { find($0, preferring: files) }
                    if let first = matches.first, matches.count == mapStatements.count, matches.allSatisfy({ $0.similarity == 1 }) {
                        matches.forEach { covered.insert($0.query) }
                        let repoQuery = queries[first.query]
                        context.add(DriftFinding(.warn, .sql, "query-renamed",
                                                 message: "\(named.name) is now \(repoQuery.name.map { "sqlc query \($0)" } ?? "an unnamed query") in \(repoQuery.file)",
                                                 fix: repoQuery.name.map { "Change the -- name: line to -- name: \($0)\(repoQuery.command.map { " " + $0 } ?? "")." }
                                                    ?? "Drop the -- name: line, or point code at \(repoQuery.location).",
                                                 map: fact.location, repo: repoQuery.location, ref: named.name, found: repoQuery.name), fact: key)
                    } else if let close = matches.max(by: { $0.similarity < $1.similarity }) {
                        covered.insert(close.query)
                        let repoQuery = queries[close.query]
                        context.add(DriftFinding(.warn, .sql, "query-changed",
                                                 message: "\(named.name) is gone; \(repoQuery.title) in \(repoQuery.file) is the closest query",
                                                 fix: "Copy the query from \(repoQuery.location) into query:, with its name.",
                                                 map: fact.location, repo: repoQuery.location, ref: named.name, found: repoQuery.name,
                                                 diff: diff(segment.body, repoQuery.body)), fact: key)
                    } else {
                        context.add(DriftFinding(.error, .sql, "query-missing",
                                                 message: "sqlc query \(named.name) no longer exists",
                                                 fix: "Remove this op, or copy its replacement from the repo's .sql files.",
                                                 map: fact.location, ref: named.name), fact: key)
                    }
                    reported = true
                    continue
                }
                for statement in mapStatements where !reported {
                    if let match = find(statement, preferring: files) {
                        covered.insert(match.query)
                        guard match.similarity < 1 else { continue }
                        let repoQuery = queries[match.query]
                        let repoStatement = repoQuery.statements[match.statement]
                        context.add(DriftFinding(.warn, .sql, "query-changed",
                                                 message: "the query changed in \(repoQuery.file)",
                                                 fix: "Copy the statement from \(repoQuery.location) into query:.",
                                                 map: fact.location, repo: repoQuery.location, ref: String(oneLine(statement.text).prefix(90)),
                                                 diff: diff(statement.text, repoStatement.text)), fact: key)
                        reported = true
                    } else {
                        let codeHasSQL = queries.contains { files.contains($0.file) }
                        let confident = haveSQL && (files.isEmpty || codeHasSQL)
                        context.add(DriftFinding(confident ? .warn : .info, .sql, "query-missing",
                                                 message: confident ? "no query in the repo matches this statement"
                                                    : "no SQL text in the repo matches this statement (the code may build it)",
                                                 fix: confident ? "Copy the query as the code runs it now, or remove the op if it is gone."
                                                    : "Check the query against the code by hand.",
                                                 map: fact.location, repo: files.sorted().first.map { DriftRepoLocation(file: $0) },
                                                 ref: String(oneLine(statement.text).prefix(90))), fact: key)
                        reported = true
                    }
                }
            }
        }

        for (q, query) in queries.enumerated() where !covered.contains(q) && query.origin != .file {
            let sqlc = query.origin == .sqlc
            context.add(DriftFinding(sqlc ? .warn : .info, .sql, "unmapped-query",
                                     message: sqlc ? "sqlc query \(query.title) is on no op" : "SQL in \(query.file) is on no op: \(query.title)",
                                     fix: "Add a sql op with this query (verbatim) to the node that runs it.",
                                     repo: query.location, ref: query.name ?? String(oneLine(query.statements.first?.text ?? "").prefix(90))))
        }
    }

    // MARK: Similarity and diff

    /// 2·LCS / (|a| + |b|) over tokens.
    static func ratio(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        return 2 * Double(lcs(a, b)) / Double(a.count + b.count)
    }

    private static func lcs(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        var current = previous
        for i in 1...a.count {
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1] ? previous[j - 1] + 1 : max(previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// A compact line diff of the two queries, both formatted one clause per line: changed lines with one
    /// line of context, the rest elided; at most 16 lines.
    static func diff(_ map: String, _ repo: String) -> [String] {
        func lines(_ text: String) -> [String] {
            SQLFormat.format(text.split(separator: "\n").filter { sqlcName(String($0)) == nil }.joined(separator: "\n"))
                .split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        let a = lines(map), b = lines(repo)
        let la = a.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }, lb = b.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        // LCS table over lines.
        var table = [[Int]](repeating: [Int](repeating: 0, count: lb.count + 1), count: la.count + 1)
        if !la.isEmpty && !lb.isEmpty {
            for i in stride(from: la.count - 1, through: 0, by: -1) {
                for j in stride(from: lb.count - 1, through: 0, by: -1) {
                    table[i][j] = la[i] == lb[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        var ops: [(Character, String)] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, la[i] == lb[j] { ops.append((" ", a[i])); i += 1; j += 1 }
            else if i < a.count, j == b.count || table[i + 1][j] >= table[i][j + 1] { ops.append(("-", a[i])); i += 1 }
            else { ops.append(("+", b[j])); j += 1 }
        }
        let changed = Set(ops.indices.filter { ops[$0].0 != " " })
        var out: [String] = []
        var elided = false
        for (index, op) in ops.enumerated() {
            let near = changed.contains(index) || changed.contains(index - 1) || changed.contains(index + 1)
            if near {
                out.append("\(op.0) \(op.1)")
                elided = false
            } else if !elided {
                out.append("  …")
                elided = true
            }
        }
        while out.first == "  …" { out.removeFirst() }
        while out.last == "  …" { out.removeLast() }
        return Array(out.prefix(16))
    }
}
