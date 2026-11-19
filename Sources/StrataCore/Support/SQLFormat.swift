import Foundation

/// Formats the SQL an op carries so it reads well: one statement per block, major clauses on their own
/// lines, `AND`/`OR` indented under `WHERE`, subqueries and CTE bodies indented, long lists one item
/// per line, keywords in upper case.
///
/// It only ever changes whitespace and the case of keywords. Strings, comments, quoted identifiers,
/// dollar-quoted bodies and parameters (`$1`, `?`, `:name`, `@name`, `sqlc.arg(name)`) are copied as
/// written, so a formatted query means exactly what its source meant. Formatting formatted SQL returns
/// it unchanged.
public enum SQLFormat {
    public enum TokenKind: Sendable, Hashable {
        case word            // identifier or keyword
        case quoted          // "identifier", `identifier`
        case string          // 'text', E'te\'xt', $tag$ body $tag$
        case number
        case parameter       // $1, ?, :name, @name
        case lineComment     // -- to the end of the line
        case blockComment    // /* … */ (nested)
        case open, close     // ( )
        case comma, semicolon
        case dot             // .
        case cast            // ::
        case bracket         // [ ]
        case symbol          // operators and anything else: = <> >= || -> @> …
    }

    public struct Token: Sendable, Hashable {
        public var kind: TokenKind
        public var text: String
        /// Whitespace separated it from the token before, and whether that whitespace held a newline.
        public var spaceBefore: Bool
        public var newlineBefore: Bool

        public var isComment: Bool { kind == .lineComment || kind == .blockComment }
        var upper: String { kind == .word ? text.uppercased() : "" }
    }

    /// One statement of a query, formatted, with its source text.
    public struct Statement: Sendable, Hashable {
        public var text: String
        public var raw: String
        /// `BEGIN`, `COMMIT`, `ROLLBACK`, `SAVEPOINT` and friends: the transaction around the real work.
        public var isTransactionControl: Bool
    }

    /// The width long lists and parenthesised groups are measured against before they break.
    public static let defaultWidth = 72

    // MARK: - API

    /// The query formatted, statements separated by a blank line.
    public static func format(_ source: String, width: Int = defaultWidth) -> String {
        statements(source, width: width).map(\.text).joined(separator: "\n\n")
    }

    /// Each statement (split on top-level `;`) formatted on its own.
    public static func statements(_ source: String, width: Int = defaultWidth) -> [Statement] {
        split(tokens(source)).map { tokens in
            var formatter = StatementFormatter(tokens: tokens, width: width)
            return Statement(text: formatter.run(),
                      raw: rawText(tokens),
                      isTransactionControl: isTransactionControl(tokens))
        }
    }

    /// Reads as SQL: the first word (comments aside) starts a statement. JSON and prose do not.
    public static func looksLikeSQL(_ source: String) -> Bool {
        let significant = tokens(source).filter { !$0.isComment }
        guard let first = significant.first else { return false }
        if first.kind == .open, significant.count > 1 { return statementVerbs.contains(significant[1].upper) }
        return first.kind == .word && statementVerbs.contains(first.upper)
    }

    /// What makes a query look elided rather than copied from the code: `...`, `…`, a `<placeholder>`,
    /// `TODO`, outside strings and comments. Nil when there is none.
    public static func placeholder(in source: String) -> String? {
        let all = tokens(source).filter { !$0.isComment }
        for (i, token) in all.enumerated() {
            if token.kind != .string, token.kind != .quoted, token.text.contains("…") { return "…" }
            if token.kind == .dot, i + 2 < all.count, all[i + 1].kind == .dot, all[i + 2].kind == .dot,
               !all[i + 1].spaceBefore, !all[i + 2].spaceBefore { return "..." }
            if token.kind == .word, ["TODO", "FIXME", "TBD"].contains(token.text) { return token.text }
            // `<query>`, `<column list>`: a word right after `<` that does not follow a value (`a<b` compares).
            if token.text == "<", i + 1 < all.count, all[i + 1].kind == .word, !all[i + 1].spaceBefore,
               i == 0 || token.spaceBefore || ![.word, .number, .parameter, .close, .quoted].contains(all[i - 1].kind) {
                var j = i + 1
                while j < all.count, j - i <= 4, all[j].kind == .word { j += 1 }
                if j < all.count, all[j].text == ">", !all[j].spaceBefore {
                    return all[i...j].enumerated().map { $0.offset > 0 && $0.element.spaceBefore ? " " + $0.element.text : $0.element.text }.joined()
                }
            }
        }
        return nil
    }

    /// Statements that aren't whole: a SELECT without FROM that computes nothing, an UPDATE without SET,
    /// an INSERT without INTO, a DELETE without FROM, or a description in words ("update the order
    /// status"). `SELECT 1`, `SELECT pg_advisory_lock($1)`, `TRUNCATE t` and `BEGIN` are whole. Empty
    /// when every statement is.
    public static func incompleteStatements(_ source: String) -> [String] {
        split(tokens(source)).compactMap { statement in
            let significant = statement.filter { !$0.isComment && $0.kind != .semicolon }
            guard let first = significant.first else { return nil }
            let words = Set(significant.filter { $0.kind == .word }.map(\.upper))
            let verb = first.kind == .open && significant.count > 1 ? significant[1].upper : first.upper
            // A SELECT without FROM is whole when it computes something: a literal, a parameter, a call.
            let computes = significant.enumerated().contains { i, token in
                [.number, .string, .parameter].contains(token.kind)
                    || token.kind == .word && i + 1 < significant.count && significant[i + 1].kind == .open
                        && !statementVerbs.contains(token.upper)
            }
            let whole: Bool
            if words.contains("THE") {
                whole = false
            } else {
                switch verb {
                case "SELECT", "VALUES": whole = words.contains("FROM") || computes
                case "WITH": whole = !words.isDisjoint(with: ["FROM", "INTO", "SET"]) || computes
                case "INSERT", "REPLACE", "UPSERT": whole = words.contains("INTO") || words.contains("VALUES")
                case "UPDATE": whole = words.contains("SET")
                case "DELETE": whole = words.contains("FROM")
                case "MERGE": whole = words.contains("INTO") || words.contains("USING")
                case "FETCH", "MOVE": whole = words.contains("FROM") || words.contains("IN")
                case "START": whole = words.contains("TRANSACTION")
                default: whole = targetFreeVerbs.contains(verb)
                }
            }
            return whole ? nil : rawText(statement)
        }
    }

    // MARK: - Tokens

    public static func tokens(_ source: String) -> [Token] {
        let c = Array(source)
        var out: [Token] = []
        var i = 0
        var space = false, newline = false
        func at(_ k: Int) -> Character? { k < c.count ? c[k] : nil }
        func emit(_ kind: TokenKind, to end: Int) {
            let end = min(max(end, i + 1), c.count)
            var text = String(c[i..<end])
            if kind == .lineComment { while let last = text.last, last.isWhitespace { text.removeLast() } }
            out.append(Token(kind: kind, text: text, spaceBefore: space, newlineBefore: newline))
            space = false
            newline = false
            i = end
        }
        while i < c.count {
            let ch = c[i]
            if ch.isWhitespace {
                space = true
                if ch.isNewline { newline = true }
                i += 1
                continue
            }
            let next = at(i + 1)
            switch ch {
            case "-" where next == "-":
                var j = i
                while j < c.count, !c[j].isNewline { j += 1 }
                emit(.lineComment, to: j)
            case "/" where next == "*": emit(.blockComment, to: blockCommentEnd(c, i))
            case "'": emit(.string, to: quoteEnd(c, i, backslash: false))
            case "\"", "`": emit(.quoted, to: quoteEnd(c, i, backslash: false))
            case "$":
                if let next, isDigit(next) {
                    var j = i + 1
                    while let d = at(j), isDigit(d) { j += 1 }
                    emit(.parameter, to: j)
                } else if let end = dollarEnd(c, i) {
                    emit(.string, to: end)
                } else {
                    emit(.symbol, to: i + 1)
                }
            case "(": emit(.open, to: i + 1)
            case ")": emit(.close, to: i + 1)
            case ",": emit(.comma, to: i + 1)
            case ";": emit(.semicolon, to: i + 1)
            case "[", "]": emit(.bracket, to: i + 1)
            case ":":
                if next == ":" { emit(.cast, to: i + 2) }
                else if let next, next.isLetter || next == "_" { emit(.parameter, to: wordEnd(c, i + 1)) }
                else { emit(.symbol, to: i + 1) }
            case "@" where next.map { $0.isLetter || $0 == "_" } ?? false:
                emit(.parameter, to: wordEnd(c, i + 1))
            case "?" where !(next.map(operatorChars.contains) ?? false):
                emit(.parameter, to: i + 1)
            case ".":
                let afterValue = out.last.map { [.word, .quoted, .close, .parameter, .bracket].contains($0.kind) && !space } ?? false
                if let next, isDigit(next), !afterValue { emit(.number, to: numberEnd(c, i)) }
                else { emit(.dot, to: i + 1) }
            default:
                if ch.isLetter || ch == "_" {
                    if next == "'", "EeNnBbXx".contains(ch) {
                        emit(.string, to: quoteEnd(c, i + 1, backslash: ch == "E" || ch == "e"))
                    } else if "Uu".contains(ch), next == "&", let quote = at(i + 2), quote == "'" || quote == "\"" {
                        emit(quote == "'" ? .string : .quoted, to: quoteEnd(c, i + 2, backslash: false))
                    } else {
                        emit(.word, to: wordEnd(c, i))
                    }
                } else if isDigit(ch) {
                    emit(.number, to: numberEnd(c, i))
                } else if operatorChars.contains(ch) {
                    var j = i + 1
                    while let d = at(j), operatorChars.contains(d) {
                        if d == "-" && at(j + 1) == "-" || d == "/" && at(j + 1) == "*" { break }
                        if d == "@", let e = at(j + 1), e.isLetter || e == "_" { break }
                        if d == "?", !(at(j + 1).map(operatorChars.contains) ?? false) { break }
                        j += 1
                    }
                    emit(.symbol, to: j)
                } else {
                    emit(.symbol, to: i + 1)
                }
            }
        }
        return out
    }

    private static let operatorChars: Set<Character> = ["+", "-", "*", "/", "<", ">", "=", "~", "!", "@", "#", "%", "^", "&", "|", "?"]

    private static func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }

    private static func wordEnd(_ c: [Character], _ start: Int) -> Int {
        var j = start
        while j < c.count, c[j].isLetter || c[j].isNumber || c[j] == "_" || c[j] == "$" { j += 1 }
        return max(j, start + 1)
    }

    private static func numberEnd(_ c: [Character], _ start: Int) -> Int {
        var j = start
        if c[j] == "0", j + 1 < c.count, c[j + 1] == "x" || c[j + 1] == "X" {
            j += 2
            while j < c.count, c[j].isHexDigit || c[j] == "_" { j += 1 }
            return j
        }
        while j < c.count, isDigit(c[j]) || c[j] == "_" { j += 1 }
        if j < c.count, c[j] == ".", !(j + 1 < c.count && c[j + 1] == ".") {
            j += 1
            while j < c.count, isDigit(c[j]) || c[j] == "_" { j += 1 }
        }
        if j < c.count, c[j] == "e" || c[j] == "E" {
            var k = j + 1
            if k < c.count, c[k] == "+" || c[k] == "-" { k += 1 }
            if k < c.count, isDigit(c[k]) {
                j = k
                while j < c.count, isDigit(c[j]) { j += 1 }
            }
        }
        return j
    }

    /// The end of a quoted run starting at `start` (the quote), with the quote doubled to escape it.
    private static func quoteEnd(_ c: [Character], _ start: Int, backslash: Bool) -> Int {
        let quote = c[start]
        var j = start + 1
        while j < c.count {
            if backslash, c[j] == "\\" { j += 2; continue }
            if c[j] == quote {
                if j + 1 < c.count, c[j + 1] == quote { j += 2; continue }
                return j + 1
            }
            j += 1
        }
        return c.count
    }

    private static func blockCommentEnd(_ c: [Character], _ start: Int) -> Int {
        var depth = 0
        var j = start
        while j + 1 < c.count {
            if c[j] == "/", c[j + 1] == "*" { depth += 1; j += 2; continue }
            if c[j] == "*", c[j + 1] == "/" {
                depth -= 1
                j += 2
                if depth == 0 { return j }
                continue
            }
            j += 1
        }
        return c.count
    }

    /// `$$ … $$` or `$tag$ … $tag$`; nil when `$` doesn't open a tag.
    private static func dollarEnd(_ c: [Character], _ start: Int) -> Int? {
        var j = start + 1
        if j < c.count, c[j].isLetter || c[j] == "_" {
            while j < c.count, c[j].isLetter || c[j].isNumber || c[j] == "_" { j += 1 }
        }
        guard j < c.count, c[j] == "$" else { return nil }
        let tag = Array(c[start...j])
        var k = j + 1
        while k + tag.count <= c.count {
            if c[k] == "$", Array(c[k..<(k + tag.count)]) == tag { return k + tag.count }
            k += 1
        }
        return c.count
    }

    // MARK: - Statements

    /// Splits on top-level `;`. A comment on the line of a `;` stays with the statement it ends, and a
    /// stray `;` or a trailing comment joins the statement before it.
    static func split(_ tokens: [Token]) -> [[Token]] {
        var statements: [[Token]] = []
        var current: [Token] = []
        var depth = 0
        func finish() {
            guard !current.isEmpty else { return }
            if !statements.isEmpty, current.allSatisfy({ $0.isComment || $0.kind == .semicolon }) {
                statements[statements.count - 1] += current
            } else {
                statements.append(current)
            }
            current = []
        }
        for token in tokens {
            if token.kind == .open { depth += 1 }
            if token.kind == .close { depth = max(0, depth - 1) }
            if current.isEmpty, !statements.isEmpty, token.isComment, !token.newlineBefore {
                statements[statements.count - 1].append(token)
                continue
            }
            current.append(token)
            if token.kind == .semicolon, depth == 0 { finish() }
        }
        finish()
        return statements
    }

    /// The statement's tokens re-joined with their source spacing (runs of whitespace as one space or newline).
    private static func rawText(_ tokens: [Token]) -> String {
        var out = ""
        for (i, token) in tokens.enumerated() {
            if i > 0 { out += token.newlineBefore ? "\n" : token.spaceBefore ? " " : "" }
            out += token.text
        }
        return out
    }

    private static func isTransactionControl(_ tokens: [Token]) -> Bool {
        guard let first = tokens.first(where: { !$0.isComment }) else { return false }
        return ["BEGIN", "COMMIT", "ROLLBACK", "END", "SAVEPOINT", "RELEASE", "ABORT"].contains(first.upper)
            || first.upper == "START" && tokens.contains { $0.upper == "TRANSACTION" }
    }

    static let statementVerbs: Set<String> = [
        "SELECT", "WITH", "INSERT", "UPDATE", "DELETE", "MERGE", "VALUES", "UPSERT", "REPLACE", "TABLE",
        "BEGIN", "START", "COMMIT", "ROLLBACK", "END", "SAVEPOINT", "RELEASE", "ABORT",
        "CREATE", "ALTER", "DROP", "TRUNCATE", "LOCK", "CALL", "EXPLAIN", "SET", "SHOW", "COPY", "GRANT",
        "REVOKE", "REFRESH", "VACUUM", "ANALYZE", "NOTIFY", "LISTEN", "UNLISTEN", "DO", "DECLARE", "PREPARE",
        "EXECUTE", "EXEC", "DEALLOCATE", "FETCH", "MOVE", "CLOSE", "RESET", "DISCARD", "CLUSTER", "REINDEX",
        "COMMENT", "USE",
    ]

    /// Verbs whose statements are whole without FROM, INTO or SET.
    private static let targetFreeVerbs: Set<String> = statementVerbs.subtracting(
        ["SELECT", "VALUES", "WITH", "INSERT", "UPDATE", "DELETE", "MERGE", "UPSERT", "REPLACE", "FETCH", "MOVE", "START"])
}

// MARK: - Layout

private enum Gap: Equatable {
    case none, space
    case newline(Int)
}

private enum Clause {
    case none, select, from, whereClause, join, groupBy, orderBy, having, limit, set, update, insert, delete
    case values, returning, with, setOperation, conflict, lock, other

    /// Clauses whose comma-separated items go one per line when they don't fit.
    var isList: Bool { [.select, .from, .groupBy, .orderBy, .set, .values, .returning].contains(self) }
    /// Clauses whose top-level `AND`/`OR` start an indented line.
    var breaksConditions: Bool { [.whereClause, .having, .join].contains(self) }
}

/// A significant token with the comments around it: `leading` on their own lines before it,
/// `trailing` after it on the same line.
private struct Item {
    var token: SQLFormat.Token
    var leading: [SQLFormat.Token] = []
    var trailing: [SQLFormat.Token] = []
}

/// A statement, a subquery or CTE body, or a parenthesised group.
private struct Context {
    var statement: Bool
    /// Statements: the indent of their clauses. Groups: the indent of their items when broken.
    var base: Int
    /// The indent of the line that closes it.
    var close: Int
    var broken = false
    /// A `[ … ]` subscript or array: kept as written.
    var bracket = false
    var clause: Clause = .none
    var listBroken = false
    /// A JOIN too long for one line puts its ON on the next.
    var onBreaks = false
    /// The next item of a broken list starts the list, on its own line.
    var listPending = false
    var between = 0
    var caseDepth = 0
    var first = true
}

private struct Writer {
    var lines: [String] = []
    var line = ""
    var indent = 0
    /// The indent of the last line the layout started; wrapped lines continue 4 deeper than it.
    var base = 0
    var fresh = true

    /// Characters on the current line (after any newline inside a multi-line token).
    var column: Int {
        if let newline = line.lastIndex(where: \.isNewline) { return line.distance(from: line.index(after: newline), to: line.endIndex) }
        return line.count
    }

    /// Starts a line at `indent`; at the very start it only sets the indent.
    mutating func newline(_ indent: Int, wrapped: Bool = false) {
        if !(lines.isEmpty && fresh) { lines.append(line) }
        line = String(repeating: " ", count: indent)
        self.indent = indent
        if !wrapped { base = indent }
        fresh = true
    }

    mutating func write(_ text: String, space: Bool) {
        if space, !fresh { line += " " }
        line += text
        fresh = false
    }

    func finish() -> String {
        (lines + [line]).map { line in
            var line = line
            while let last = line.last, last == " " { line.removeLast() }
            return line
        }
        .drop { $0.isEmpty }
        .joined(separator: "\n")
    }
}

private struct StatementFormatter {
    let items: [Item]
    let tail: [SQLFormat.Token]
    let width: Int
    let match: [Int: Int]
    var stack: [Context] = [Context(statement: true, base: 0, close: 0)]
    var writer = Writer()
    var forceBreak = false

    init(tokens: [SQLFormat.Token], width: Int) {
        var items: [Item] = []
        var pending: [SQLFormat.Token] = []
        for token in tokens {
            if token.isComment {
                if items.isEmpty || token.newlineBefore || !pending.isEmpty { pending.append(token) }
                else { items[items.count - 1].trailing.append(token) }
            } else {
                items.append(Item(token: token, leading: pending))
                pending = []
            }
        }
        self.items = items
        tail = pending
        self.width = width
        var match: [Int: Int] = [:]
        var opens: [Int] = []
        for (i, item) in items.enumerated() {
            if item.token.kind == .open { opens.append(i) }
            if item.token.kind == .close, let open = opens.popLast() { match[open] = i }
        }
        self.match = match
    }

    mutating func run() -> String {
        for i in items.indices { step(i) }
        for comment in tail {
            writer.newline(0)
            writer.write(comment.text, space: false)
        }
        return writer.finish()
    }

    // MARK: Tokens

    private func token(_ i: Int) -> SQLFormat.Token? { i >= 0 && i < items.count ? items[i].token : nil }
    private func word(_ i: Int) -> String { token(i)?.upper ?? "" }

    private mutating func step(_ i: Int) {
        let t = items[i].token
        if t.kind == .close {
            while stack.count > 1, stack[stack.count - 1].bracket { stack.removeLast() }
            let closing = stack.count > 1 ? stack.removeLast() : Context(statement: false, base: 0, close: 0)
            emit(i, gap: closing.statement || closing.broken ? .newline(closing.close) : .none)
            return
        }
        if t.text == "]" {
            if stack.count > 1, stack[stack.count - 1].bracket { stack.removeLast() }
            emit(i, gap: inlineGap(i) == 1 ? .space : .none)
            return
        }
        var ctx = stack[stack.count - 1]
        let clause = ctx.statement ? clauseStart(i, ctx) : nil
        let gap: Gap
        if i == 0 {
            gap = .none
        } else if t.kind == .comma || t.kind == .semicolon {
            gap = .none
        } else if t.kind == .string, token(i - 1)?.kind == .string, t.newlineBefore {
            // 'a'
            // 'b' continues the string 'a' only across a newline.
            gap = .newline(writer.indent + 2)
        } else if token(i - 1)?.kind == .open {
            gap = ctx.statement || ctx.broken ? .newline(ctx.base) : .none
        } else if clause != nil {
            gap = .newline(ctx.base)
        } else if token(i - 1)?.kind == .comma {
            if ctx.statement {
                gap = ctx.clause == .with ? .newline(ctx.base) : ctx.listBroken ? .newline(ctx.base + 2) : .space
            } else {
                gap = ctx.broken ? .newline(ctx.base) : .space
            }
        } else if ctx.listPending, !isListModifier(i, ctx.clause) {
            gap = .newline(ctx.base + 2)
        } else if ctx.statement, ctx.clause == .join, ctx.onBreaks, ctx.caseDepth == 0, word(i) == "ON" {
            gap = .newline(ctx.base + 2)
        } else if ctx.statement, ctx.clause.breaksConditions, ctx.caseDepth == 0, word(i) == "AND" || word(i) == "OR",
                  !(word(i) == "AND" && ctx.between > 0) {
            gap = .newline(ctx.base + 2)
        } else {
            gap = inlineGap(i) == 1 ? .space : .none
        }

        // State after this token.
        if ctx.listPending, !isListModifier(i, ctx.clause) { ctx.listPending = false }
        if let clause {
            ctx.clause = clause
            ctx.between = 0
            ctx.caseDepth = 0
            ctx.listBroken = clause.isList && listBreaks(from: i, base: ctx.base)
            ctx.listPending = ctx.listBroken
            ctx.onBreaks = clause == .join && ctx.base + inlineLength(i...clauseExtent(from: i).end) > width
        }
        switch word(i) {
        case "BETWEEN": ctx.between += 1
        case "AND" where ctx.between > 0: ctx.between -= 1
        case "CASE": ctx.caseDepth += 1
        case "END" where ctx.caseDepth > 0: ctx.caseDepth -= 1
        default: break
        }
        ctx.first = false
        stack[stack.count - 1] = ctx

        emit(i, gap: gap, keyword: clause != nil)

        if t.text == "[" {
            stack.append(Context(statement: false, base: writer.indent + 2, close: writer.indent, bracket: true))
        }
        if t.kind == .open, let close = match[i] {
            let indent = writer.indent
            if startsSubquery(i + 1) {
                stack.append(Context(statement: true, base: indent + 2, close: indent))
            } else {
                let commas = topLevelCommas(i + 1, close)
                let long = writer.column - 1 + inlineLength(i...close) > width
                stack.append(Context(statement: false, base: indent + 2, close: indent,
                                     broken: commas > 0 && (long || hasComments(i...close))))
            }
        }
    }

    private mutating func emit(_ i: Int, gap: Gap, keyword: Bool = false) {
        let item = items[i]
        var gap = gap
        let continuation = writer.indent + 2
        if forceBreak {
            if case .newline = gap {} else { gap = .newline(continuation) }
            forceBreak = false
        }
        if !item.leading.isEmpty {
            var indent = continuation
            if case .newline(let n) = gap { indent = n } else if i == 0 { indent = 0 }
            for comment in item.leading {
                writer.newline(indent)
                writer.write(comment.text, space: false)
            }
            gap = .newline(indent)
        }
        let text = cased(i, keyword: keyword)
        switch gap {
        case .none: writer.write(text, space: false)
        case .space where wraps(i):
            writer.newline(writer.base + 4, wrapped: true)
            writer.write(text, space: false)
        case .space: writer.write(text, space: true)
        case .newline(let indent):
            writer.newline(indent)
            writer.write(text, space: false)
        }
        for comment in item.trailing {
            writer.write(comment.text, space: true)
            if comment.kind == .lineComment { forceBreak = true }
        }
    }

    // MARK: Spacing

    /// A line the layout could not shorten breaks at a space before the run of tokens that would cross
    /// the width, and continues 4 deeper than the line it came from.
    private func wraps(_ i: Int) -> Bool {
        guard writer.column > writer.indent, writer.column + 1 > writer.base + 4 else { return false }
        if items[i].token.kind == .string, token(i - 1)?.kind == .string { return false }
        return writer.column + 1 + runLength(i) > width
    }

    /// Characters from token `i` to the next place a line could break.
    private func runLength(_ i: Int) -> Int {
        var n = items[i].token.text.count
        var k = i
        while k + 1 < items.count, items[k].token.kind != .open || !startsSubquery(k + 1),
              items[k].trailing.isEmpty, items[k + 1].leading.isEmpty, inlineGap(k + 1) == 0 {
            k += 1
            n += items[k].token.text.count
        }
        return n
    }

    /// The gap between token `i - 1` and `i` when they share a line: 1 for a space, else 0. Brackets and
    /// commas are tidied; everything else keeps whether the source had a space there.
    private func inlineGap(_ i: Int) -> Int {
        guard let t = token(i), let p = token(i - 1) else { return 0 }
        if [.close, .comma, .semicolon].contains(t.kind) || p.kind == .open { return 0 }
        if p.kind == .comma { return 1 }
        if t.kind == .open, p.kind == .word, Self.spacedBeforeParen.contains(p.upper) { return 1 }
        // A line comment between them forces a break; a block comment needs space around it.
        if !items[i - 1].trailing.isEmpty || !items[i].leading.isEmpty { return 1 }
        // A clause keyword or AND/OR may start a line after a value; measured as a space either way.
        if t.kind == .word, Self.lineStarters.contains(t.upper),
           [.close, .string, .number, .quoted, .parameter, .bracket].contains(p.kind) { return 1 }
        // Strings continued over lines must stay on separate lines; a space is the closest inline.
        return t.spaceBefore ? 1 : 0
    }

    private static let lineStarters: Set<String> = [
        "SELECT", "FROM", "WHERE", "GROUP", "ORDER", "HAVING", "WINDOW", "LIMIT", "OFFSET", "FETCH", "RETURNING",
        "VALUES", "SET", "UPDATE", "INSERT", "DELETE", "MERGE", "UNION", "INTERSECT", "EXCEPT", "ON", "FOR", "JOIN",
        "LEFT", "RIGHT", "FULL", "INNER", "CROSS", "NATURAL", "AND", "OR",
    ]

    private static let spacedBeforeParen: Set<String> = [
        "IN", "VALUES", "AS", "ON", "USING", "EXISTS", "FROM", "JOIN", "WHERE", "AND", "OR", "NOT", "SELECT",
        "INTO", "SET", "CONFLICT", "OVER", "FILTER", "THEN", "ELSE", "WHEN", "RETURNING", "BY", "LATERAL", "WITH",
        "HAVING", "UNION", "ALL", "INTERSECT", "EXCEPT", "LIMIT", "OFFSET", "IS", "BETWEEN", "LIKE", "ILIKE",
    ]

    private func inlineLength(_ range: ClosedRange<Int>) -> Int {
        var n = 0
        for k in range {
            if k > range.lowerBound { n += inlineGap(k) }
            n += items[k].token.text.count
        }
        return n
    }

    private func hasComments(_ range: ClosedRange<Int>) -> Bool {
        range.contains { k in
            (k > range.lowerBound && !items[k].leading.isEmpty) || (k < range.upperBound && !items[k].trailing.isEmpty)
        }
    }

    private func topLevelCommas(_ start: Int, _ end: Int) -> Int {
        var depth = 0, commas = 0
        var k = start
        while k < end {
            let t = items[k].token
            if t.kind == .open || t.text == "[" { depth += 1 }
            if t.kind == .close || t.text == "]" { depth -= 1 }
            if t.kind == .comma, depth == 0 { commas += 1 }
            k += 1
        }
        return commas
    }

    // MARK: Clauses

    private func startsSubquery(_ i: Int) -> Bool {
        ["SELECT", "WITH", "VALUES", "INSERT", "UPDATE", "DELETE", "MERGE"].contains(word(i))
    }

    /// The clause token `i` starts in a statement, or nil.
    private func clauseStart(_ i: Int, _ ctx: Context) -> Clause? {
        guard let t = token(i), t.kind == .word else { return nil }
        let w = t.upper, p = word(i - 1), n = word(i + 1)
        let joinWords: Set<String> = ["LEFT", "RIGHT", "FULL", "INNER", "CROSS", "NATURAL", "OUTER"]
        switch w {
        case "SELECT": return .select
        case "FROM": return ["DELETE", "DISTINCT"].contains(p) ? nil : .from
        case "WHERE": return .whereClause
        case "GROUP": return n == "BY" ? .groupBy : nil
        case "ORDER": return n == "BY" ? .orderBy : nil
        case "HAVING": return .having
        case "WINDOW": return .other
        case "LIMIT", "OFFSET": return .limit
        case "FETCH": return ["FIRST", "NEXT"].contains(n) ? .limit : nil
        case "RETURNING": return .returning
        case "VALUES": return p == "DEFAULT" ? nil : .values
        case "SET": return ctx.clause == .update || p == "UPDATE" ? .set : nil
        case "UPDATE": return ["DO", "FOR", "KEY", "NO"].contains(p) ? nil : .update
        case "INSERT": return .insert
        case "DELETE": return .delete
        case "MERGE": return .other
        case "WITH": return ctx.first ? .with : nil
        case "UNION", "INTERSECT", "EXCEPT": return .setOperation
        case "ON": return n == "CONFLICT" || n == "DUPLICATE" ? .conflict : nil
        case "FOR": return ["UPDATE", "SHARE", "NO", "KEY"].contains(n) ? .lock : nil
        case "JOIN": return joinWords.contains(p) ? nil : .join
        case "LEFT", "RIGHT", "FULL": return (n == "JOIN" || n == "OUTER") && p != "NATURAL" ? .join : nil
        case "INNER", "CROSS": return n == "JOIN" && p != "NATURAL" ? .join : nil
        case "NATURAL": return n == "JOIN" || joinWords.contains(n) ? .join : nil
        default: return nil
        }
    }

    /// Words between a list clause's keyword and its first item: `DISTINCT`, `ALL`, `DISTINCT ON (…)`, `BY`.
    private func isListModifier(_ i: Int, _ clause: Clause) -> Bool {
        let w = word(i), p = word(i - 1)
        switch clause {
        case .select:
            if w == "DISTINCT" || w == "ALL" { return true }
            if w == "ON", p == "DISTINCT" { return true }
            if token(i)?.kind == .open, p == "ON", word(i - 2) == "DISTINCT" { return true }
            return false
        case .groupBy, .orderBy: return w == "BY"
        default: return false
        }
    }

    /// A list clause starting at `i` goes one item per line when it has several items and doesn't fit
    /// on its line, or holds comments.
    private func listBreaks(from i: Int, base: Int) -> Bool {
        let (end, commas) = clauseExtent(from: i)
        guard commas > 0 else { return false }
        let subquery = (i...end).contains { items[$0].token.kind == .open && startsSubquery($0 + 1) }
        return subquery || base + inlineLength(i...end) > width || hasComments(i...end)
    }

    /// The last token of the clause starting at `i`, and its top-level commas.
    private func clauseExtent(from i: Int) -> (end: Int, commas: Int) {
        var depth = 0, commas = 0
        var end = i
        var k = i + 1
        let probe = Context(statement: true, base: 0, close: 0, first: false)
        while k < items.count {
            let t = items[k].token
            if t.kind == .open || t.text == "[" { depth += 1 }
            if t.kind == .close || t.text == "]" {
                if depth == 0 { break }
                depth -= 1
            }
            if depth == 0 {
                if t.kind == .semicolon { break }
                if t.kind == .comma { commas += 1 }
                if clauseStart(k, probe) != nil { break }
            }
            end = k
            k += 1
        }
        return (end, commas)
    }

    // MARK: Case

    /// Keywords in upper case; identifiers that happen to share a keyword's name (`key`, `status`,
    /// `interval`, `locked`) keep their case unless the words around them make them keywords.
    private func cased(_ i: Int, keyword: Bool) -> String {
        guard let t = token(i), t.kind == .word else { return token(i)?.text ?? "" }
        let w = t.upper
        if keyword || Self.keywords.contains(w) { return w }
        let p = word(i - 1), n = word(i + 1)
        let next = token(i + 1)
        let contextual: Bool = switch w {
        case "KEY": ["NO", "DUPLICATE", "PRIMARY", "FOREIGN"].contains(p) || n == "SHARE"
        case "SHARE": p == "FOR" || p == "KEY"
        case "NO": n == "KEY" || n == "ACTION"
        case "SKIP": n == "LOCKED"
        case "LOCKED": p == "SKIP"
        case "NOTHING": p == "DO"
        case "CONFLICT": p == "ON"
        case "DUPLICATE": p == "ON" && n == "KEY"
        case "FIRST", "LAST": p == "NULLS" || p == "FETCH"
        case "NEXT": p == "FETCH"
        case "ROWS", "ROW": n == "ONLY" || n == "BETWEEN"
        case "ONLY": p == "ROWS" || p == "ROW"
        case "RECURSIVE": p == "WITH"
        case "MATCHED": p == "WHEN" || p == "NOT"
        case "TRANSACTION", "WORK": ["BEGIN", "START", "COMMIT", "ROLLBACK", "END", "ABORT"].contains(p)
        case "START": n == "TRANSACTION"
        case "ISOLATION": p == "TRANSACTION" || n == "LEVEL"
        case "BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT", "RELEASE", "ABORT", "MERGE", "EXPLAIN", "TRUNCATE":
            i == 0 || p == "RELEASE" || p == "TO" || p == "EXPLAIN"
        case "ANALYZE": i == 0 || p == "EXPLAIN"
        case "INDEX": ["CREATE", "UNIQUE", "DROP", "ALTER", "REINDEX"].contains(p)
        case "INTERVAL": next?.kind == .string
        case "ARRAY": next?.kind == .bracket || next?.kind == .open
        case "CAST", "ANY", "SOME", "COALESCE", "NULLIF": next?.kind == .open
        case "EXISTS": next?.kind == .open || p == "IF" || p == "NOT"
        case "IF": n == "NOT" || n == "EXISTS"
        case "FILTER": next?.kind == .open && token(i - 1)?.kind == .close
        case "WITHIN": n == "GROUP"
        case "PARTITION": n == "BY"
        case "OVER": next?.kind == .open
        case "AT": n == "TIME" && word(i + 2) == "ZONE"
        case "TIME": p == "AT" || n == "ZONE" && (p == "WITH" || p == "WITHOUT")
        case "ZONE": p == "TIME"
        case "WITHOUT": n == "TIME"
        case "NULLS": n == "FIRST" || n == "LAST" || p == "ASC" || p == "DESC"
        default: false
        }
        return contextual ? w : t.text
    }

    /// Reserved words that are never bare identifiers, safe to upper-case wherever they appear.
    private static let keywords: Set<String> = [
        "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "IS", "NULL", "AS", "ON", "JOIN", "LEFT", "RIGHT",
        "INNER", "OUTER", "FULL", "CROSS", "NATURAL", "LATERAL", "GROUP", "BY", "ORDER", "HAVING", "LIMIT",
        "OFFSET", "FETCH", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "RETURNING", "WITH", "DISTINCT",
        "UNION", "ALL", "INTERSECT", "EXCEPT", "CASE", "WHEN", "THEN", "ELSE", "END", "FOR", "NOWAIT", "DO",
        "ASC", "DESC", "LIKE", "ILIKE", "SIMILAR", "BETWEEN", "TRUE", "FALSE", "DEFAULT", "USING", "WINDOW",
        "CREATE", "TABLE", "ALTER", "DROP", "PRIMARY", "REFERENCES", "CONSTRAINT", "UNIQUE", "CHECK", "FOREIGN",
        "ESCAPE", "COLLATE",
    ]
}
