import Foundation

/// Code references: every `code:` of a node, op, mechanism, step, formula, entity and enum. A reference
/// whose file is gone is an error (with the files of the same name as hints); a line past the end of
/// the file is a warning. When the reference's context names a symbol, the line is checked to still be
/// in it, but only where the symbol is defined in that file, so prose never causes a false alarm.
enum DriftCode {
    struct Reference: Equatable {
        var path: String
        var line: Int?
        /// A symbol written after the path (`internal/lock.go:88 Acquire`, `lock.go (Acquire)`).
        var hint: String?
        var absolute: Bool { path.hasPrefix("/") }
    }

    /// `path`, `path:12`, `path:12-20`, `path:12:5`, `path#L12`, `./path`, `~/x/path`, a path inside the repo
    /// written absolute, and a trailing symbol. nil for URLs and empty text.
    static func parse(_ raw: String, root: String) -> Reference? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("://") else { return nil }
        var head = trimmed
        var rest = ""
        if let space = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "(" }) {
            head = String(trimmed[..<space])
            rest = String(trimmed[space...])
        }
        while let last = head.last, ",;".contains(last) { head.removeLast() }
        var line: Int?
        if let anchor = head.range(of: "#L") {
            line = Int(head[anchor.upperBound...].prefix { $0.isNumber })
            head = String(head[..<anchor.lowerBound])
        }
        // :12, :12-20, :12:5 (column)
        let parts = head.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count >= 2, let number = Int(parts[1].prefix { $0.isNumber }), !parts[1].isEmpty, parts[1].first!.isNumber {
            line = line ?? number
            head = String(parts[0])
        }
        var path = StrataPaths.expand(head)
        if path.hasPrefix(root + "/") { path = String(path.dropFirst(root.count + 1)) }
        while path.hasPrefix("./") { path.removeFirst(2) }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty, path != "." else { return nil }
        var hint: String?
        let words = rest.split(whereSeparator: { c in !(c.isLetter || c.isNumber || c == "_" || c == ".") })
        for word in words {
            let text = String(word)
            guard text != "func", text != "method", text != "type" else { continue }
            guard let last = text.split(separator: ".").last.map(String.init), last.count >= 3, DriftMapFacts.isIdentifier(last) else { continue }
            hint = last
            break
        }
        return Reference(path: path, line: line, hint: hint)
    }

    static func run(_ context: DriftContext) {
        let repo = context.repo
        var missingRefs: [(reference: Reference, fact: DriftMapFacts.CodeRef, strong: [String], key: String)] = []
        defer { reportMissing(missingRefs, context: context) }
        for fact in context.facts.codeRefs {
            guard let reference = parse(fact.ref, root: repo.rootPath) else { continue }
            context.checked(.code)
            let key = "code|\(fact.location)|\(fact.ref)"
            let strong = (reference.hint.map { [$0] } ?? []) + fact.strong
            if reference.path.contains(where: { "*?[".contains($0) }) {
                if !repo.files.contains(where: { fnmatch(reference.path, $0, 0) == 0 }) {
                    context.add(DriftFinding(.error, .code, "missing-file",
                                             message: "no file matches \(reference.path)",
                                             fix: "Update the pattern in code: to where these files are now, or remove it.",
                                             map: fact.location, ref: fact.ref), fact: key)
                }
                continue
            }
            let (exists, directory) = reference.absolute
                ? { var d: ObjCBool = false; return (FileManager.default.fileExists(atPath: reference.path, isDirectory: &d), d.boolValue) }()
                : repo.exists(reference.path)
            guard exists else {
                missingRefs.append((reference, fact, strong, key))
                continue
            }
            guard !directory, !reference.absolute, let line = reference.line, let lines = repo.lines(reference.path) else { continue }
            if line > lines.count || line < 1 {
                let located = locate(strong + fact.weak, near: reference.path, in: repo, definitionsOnly: strong.isEmpty, sameDirectory: true)
                    .first { $0.file == reference.path }
                let found = located.map { "\(reference.path):\($0.line)" }
                context.add(DriftFinding(.warn, .code, "line-past-end",
                                         message: "\(reference.path) has \(lines.count) lines; the map points at line \(line)",
                                         fix: found.map { "Point code at \($0) (\(located!.symbol) is there now)." }
                                            ?? "Point code at the line again (the file has \(lines.count) lines).",
                                         map: fact.location, repo: DriftRepoLocation(file: reference.path), ref: fact.ref, found: found),
                            fact: key)
                continue
            }
            if let moved = symbolMoved(reference, line: line, lines: lines, strong: strong, weak: fact.weak, repo: repo) {
                context.add(DriftFinding(moved.confident ? .warn : .info, .code, "symbol-moved",
                                         message: moved.message,
                                         fix: "Point code at \(moved.found).",
                                         map: fact.location, repo: DriftRepoLocation(file: reference.path, line: line),
                                         ref: fact.ref, found: moved.found),
                            fact: moved.confident ? key : nil)
            }
        }
    }

    // MARK: Missing files

    /// Missing files, each with a guess at where it went; references to the same missing file share the
    /// guess one of them could make (a step without symbols next to its mechanism that has some).
    private static func reportMissing(_ refs: [(reference: Reference, fact: DriftMapFacts.CodeRef, strong: [String], key: String)],
                                      context: DriftContext) {
        let hints = refs.map { hint(for: $0.reference, fact: $0.fact, strong: $0.strong, repo: context.repo) }
        var byPath: [String: String] = [:]
        for (ref, hint) in zip(refs, hints) {
            if let file = hint?.split(separator: ":").first, byPath[ref.reference.path] == nil { byPath[ref.reference.path] = String(file) }
        }
        for (ref, own) in zip(refs, hints) {
            let reference = ref.reference
            var hint = own ?? byPath[reference.path]
            // Only a strong symbol says which line; otherwise keep the reference's own line in the new file
            // (a renamed file keeps its lines).
            if ref.strong.isEmpty, let file = hint?.split(separator: ":").first.map(String.init) {
                let count = context.repo.lines(file)?.count ?? 0
                hint = reference.line.map { $0 <= count ? "\(file):\($0)" : file } ?? file
            }
            let message = hint.map { "\(reference.path) is gone; \($0.split(separator: ":").first.map(String.init) ?? $0) looks like where it went" }
                ?? "\(reference.path) is gone"
            context.add(DriftFinding(.error, .code, "missing-file", message: message,
                                     fix: hint.map { "Point code at \($0)." } ?? "Find where this code lives now and update code:, or remove the reference.",
                                     map: ref.fact.location, repo: DriftRepoLocation(file: reference.path, line: reference.line),
                                     ref: ref.fact.ref, found: hint), fact: ref.key)
        }
    }

    private static func hint(for reference: Reference, fact: DriftMapFacts.CodeRef, strong: [String], repo: DriftRepo) -> String? {
        let name = (reference.path as NSString).lastPathComponent
        var hint: String?
        if !reference.absolute {
            let sameName = rank(repo.byName[name] ?? repo.directoriesByName[name] ?? [], like: reference.path)
            let symbols = strong + fact.weak + fact.context
            // Prefer a same-named file that still defines the symbol; else one where the symbol is defined
            // next to the old path (a renamed file); else the closest same-named file.
            let withSymbol = sameName.first { file in
                guard let text = repo.text(file) else { return false }
                return symbols.contains { symbol in DriftRepo.contains(text, symbol) }
            }
            if let withSymbol {
                let line = locate(symbols, near: withSymbol, in: repo, definitionsOnly: false).first { $0.file == withSymbol }?.line
                hint = line.map { "\(withSymbol):\($0)" } ?? withSymbol
            } else if let located = locate(strong, near: reference.path, in: repo, definitionsOnly: true).first
                        ?? locate(fact.weak + fact.context, near: reference.path, in: repo, definitionsOnly: true, sameDirectory: true).first {
                hint = "\(located.file):\(located.line)"
            } else if let first = sameName.first {
                hint = first
            }
        }
        return hint
    }

    /// Paths ordered by how many trailing directories they share with `path`, then leading ones, then length.
    static func rank(_ candidates: [String], like path: String) -> [String] {
        let target = path.split(separator: "/")
        func score(_ candidate: String) -> (Int, Int, Int) {
            let parts = candidate.split(separator: "/")
            let tail = zip(parts.reversed(), target.reversed()).prefix { $0 == $1 }.count
            let head = zip(parts, target).prefix { $0 == $1 }.count
            return (tail, head, -candidate.count)
        }
        return Array(candidates.filter { $0 != path }.sorted { a, b in
            let x = score(a), y = score(b)
            return x != y ? x > y : a < b
        }.prefix(3))
    }

    // MARK: Symbols

    struct Located { var file: String; var line: Int; var symbol: String }

    /// Where the symbols are: in `path` itself (defined, or when `definitionsOnly` is false, mentioned),
    /// then where the repo defines them (Go funcs, methods and types, sqlc queries), in files of the same
    /// directory first, then (unless `sameDirectory`) with the same extension, nearest path first.
    static func locate(_ symbols: [String], near path: String, in repo: DriftRepo, definitionsOnly: Bool,
                       sameDirectory: Bool = false) -> [Located] {
        guard !symbols.isEmpty else { return [] }
        if repo.exists(path).exists, let lines = repo.lines(path) {
            let here = symbols.compactMap { symbol -> Located? in
                let found = occurrences(symbol, in: lines)
                return (found.definitions.first ?? (definitionsOnly ? nil : found.uses.first)).map { Located(file: path, line: $0, symbol: symbol) }
            }
            if !here.isEmpty { return here }
        }
        let ext = (path as NSString).pathExtension.lowercased()
        let dir = (path as NSString).deletingLastPathComponent
        var out: [Located] = []
        for symbol in symbols {
            let places = (repo.definitions[symbol] ?? []).filter { place in
                place.file != path && ((place.file as NSString).deletingLastPathComponent == dir
                    || !sameDirectory && (place.file as NSString).pathExtension.lowercased() == ext)
            }
            let ranked = rank(places.map(\.file), like: path)
            if let best = ranked.first, let line = places.first(where: { $0.file == best })?.line {
                out.append(Located(file: best, line: line, symbol: symbol))
            }
        }
        let sameDir = out.filter { ($0.file as NSString).deletingLastPathComponent == dir }
        return sameDir.isEmpty ? out : sameDir
    }

    /// 1-based lines where `name` is defined (Go func, method or type, a sqlc `-- name:`, `def`, `function`,
    /// `class`, `fn`) and where it appears as a whole word.
    static func occurrences(_ name: String, in lines: [Substring]) -> (definitions: [Int], uses: [Int]) {
        var definitions: [Int] = [], uses: [Int] = []
        for (index, line) in lines.enumerated() where line.contains(name) {
            guard containsWord(line, name) else { continue }
            uses.append(index + 1)
            if isDefinition(line, name) { definitions.append(index + 1) }
        }
        return (definitions, uses)
    }

    static func containsWord(_ line: Substring, _ word: String) -> Bool {
        var search = line.startIndex
        while let range = line.range(of: word, range: search..<line.endIndex) {
            let before = range.lowerBound == line.startIndex ? nil : line[line.index(before: range.lowerBound)]
            let after = range.upperBound == line.endIndex ? nil : line[range.upperBound]
            let boundary: (Character?) -> Bool = { c in c.map { !($0.isLetter || $0.isNumber || $0 == "_") } ?? true }
            if boundary(before) && boundary(after) { return true }
            search = range.upperBound
        }
        return false
    }

    static func isDefinition(_ line: Substring, _ name: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("-- name:") { return text.dropFirst(8).trimmingCharacters(in: .whitespaces).hasPrefix(name) }
        for keyword in ["func ", "def ", "function ", "class ", "fn ", "type ", "interface ", "struct "] {
            guard let range = text.range(of: keyword), range.lowerBound == text.startIndex || text[text.index(before: range.lowerBound)] == " " else { continue }
            var rest = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if keyword == "func ", rest.hasPrefix("("), let close = rest.firstIndex(of: ")") {
                rest = rest[rest.index(after: close)...].trimmingCharacters(in: .whitespaces)
            }
            if rest.hasPrefix(name) {
                let after = rest.dropFirst(name.count).first
                if after == nil || after == "(" || after == " " || after == "[" || after == "<" || after == ":" || after == "{" { return true }
            }
        }
        return false
    }

    /// The last line of the definition starting at `start`: a Go-style `}` in column one, the line before
    /// the next sqlc `-- name:`, or the next definition; at most 400 lines on.
    static func extent(from start: Int, in lines: [Substring]) -> Int {
        let first = lines[start - 1].trimmingCharacters(in: .whitespaces)
        let sqlc = first.hasPrefix("-- name:")
        var line = start + 1
        while line <= lines.count, line - start < 400 {
            let text = lines[line - 1]
            if sqlc {
                if text.trimmingCharacters(in: .whitespaces).hasPrefix("-- name:") { return line - 1 }
            } else if text.hasPrefix("}") {
                return line
            } else if text.hasPrefix("func ") || text.hasPrefix("def ") || text.hasPrefix("class ") {
                return line - 1
            }
            line += 1
        }
        return min(lines.count, line - 1)
    }

    struct Moved { var message: String; var found: String; var confident: Bool }

    /// Strong symbols: when one appears in the file but none within 3 lines of the reference (or around it
    /// as a definition), the line moved. Weak symbols: only when one is defined in the file and the
    /// reference is in none of their definitions and on no line naming them.
    static func symbolMoved(_ reference: Reference, line: Int, lines: [Substring], strong: [String], weak: [String],
                            repo: DriftRepo) -> Moved? {
        let window = max(1, line - 3)...min(lines.count, line + 3)
        func covers(_ symbol: String, near: Bool) -> (covered: Bool, best: Int?, defined: Bool) {
            let found = occurrences(symbol, in: lines)
            if near, found.uses.contains(where: window.contains) { return (true, nil, !found.definitions.isEmpty) }
            if !near, found.uses.contains(line) { return (true, nil, true) }
            for definition in found.definitions where (definition...extent(from: definition, in: lines)).contains(line) {
                return (true, nil, true)
            }
            let candidates = found.definitions.isEmpty ? (near ? found.uses : []) : found.definitions
            return (false, candidates.min { abs($0 - line) < abs($1 - line) }, !found.definitions.isEmpty)
        }
        let strongHere = strong.filter { s in lines.contains { $0.contains(s) } }
        if !strong.isEmpty {
            if strongHere.isEmpty {
                // Gone from this file: say where it is defined now, if anywhere.
                if let elsewhere = locate(strong, near: reference.path, in: repo, definitionsOnly: true).first(where: { $0.file != reference.path }) {
                    return Moved(message: "\(elsewhere.symbol) is no longer in \(reference.path); it is defined in \(elsewhere.file):\(elsewhere.line)",
                                 found: "\(elsewhere.file):\(elsewhere.line)", confident: true)
                }
            } else {
                var best: (Int, String)?
                for symbol in strongHere {
                    let result = covers(symbol, near: true)
                    if result.covered { return nil }
                    if let line = result.best, best == nil { best = (line, symbol) }
                }
                if let (target, symbol) = best {
                    return Moved(message: "line \(line) of \(reference.path) is no longer at \(symbol); it is at line \(target)",
                                 found: "\(reference.path):\(target)", confident: true)
                }
            }
            return nil
        }
        var best: (Int, String)?
        var anyDefined = false
        for symbol in weak where lines.contains(where: { $0.contains(symbol) }) {
            let result = covers(symbol, near: false)
            if result.covered { return nil }
            if result.defined { anyDefined = true }
            if let target = result.best, best == nil { best = (target, symbol) }
        }
        guard anyDefined, let (target, symbol) = best else { return nil }
        return Moved(message: "line \(line) of \(reference.path) is outside \(symbol), which is at line \(target)",
                     found: "\(reference.path):\(target)", confident: false)
    }
}
