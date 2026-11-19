import Foundation

/// Enums: each `enums:` entry against the definition in the repo that has its values: a Go const block
/// (explicit values, `iota` and its expressions, typed or not), typed consts spread over a package, a
/// Postgres `CREATE TYPE … AS ENUM` (with later `ALTER TYPE … ADD VALUE`) or a `CHECK (col IN (…))`.
/// The enum's own `code:` picks the definition when it points at one. Values added in the code or gone
/// from it are warnings; a value whose code name changed is one too, but only when the map's names
/// follow the code's for the other values.
enum DriftEnums {
    struct Candidate {
        var name: String
        var file: String
        var line: Int
        var endLine: Int
        /// Value → code name (the const name, or the value itself for SQL).
        var values: [(value: String, name: String)]
    }

    // MARK: Go consts

    enum ConstValue: Equatable { case int(Int), string(String) }

    /// A typed const declared on its own line (`const StatusDraft Status = 3100`), grouped by package and type.
    struct TypedConst { var type: String; var name: String; var value: String; var line: Int }

    static func goCandidates(_ repo: DriftRepo) -> [Candidate] {
        var out: [Candidate] = []
        var loose: [String: Candidate] = [:]   // "dir|Type" → typed consts declared one per line
        for file in repo.goSources {
            let facts = repo.goFacts(file)
            out += facts.constBlocks
            for typed in facts.typedConsts {
                let key = (file as NSString).deletingLastPathComponent + "|" + typed.type
                var group = loose[key] ?? Candidate(name: typed.type, file: file, line: typed.line, endLine: typed.line, values: [])
                group.values.append((typed.value, typed.name))
                loose[key] = group
            }
        }
        out += loose.values.filter { $0.values.count >= 2 }.sorted { ($0.file, $0.line) < ($1.file, $1.line) }
        return out
    }

    /// A Go file's top-level const blocks (one candidate per type in a block) and its single typed consts.
    static func consts(in tokens: [GoToken], file: String) -> ([Candidate], [TypedConst]) {
        var blocks: [Candidate] = []
        var typed: [TypedConst] = []
        var known: [String: ConstValue] = [:]
        var i = 0
        var depth = 0
        while i < tokens.count {
            let token = tokens[i]
            if token.kind == .punct, token.text == "{" { depth += 1 } else if token.kind == .punct, token.text == "}" { depth -= 1 }
            guard depth == 0, token.kind == .ident, token.text == "const" else { i += 1; continue }
            if i + 1 < tokens.count, tokens[i + 1].text == "(" {
                let (block, next) = constBlock(tokens, from: i + 2, known: &known)
                let end = tokens[min(next, tokens.count - 1)].line
                // One candidate per type in the block (and the whole block when it mixes types).
                let types = Array(Set(block.map { $0.type ?? "" })).sorted()
                for type in types {
                    let entries = block.filter { ($0.type ?? "") == type }
                    guard entries.count >= 2 else { continue }
                    blocks.append(candidate(entries, name: type.isEmpty ? "const block" : type, file: file, line: token.line, end: end))
                }
                if types.count > 1, block.count >= 2 {
                    blocks.append(candidate(block, name: "const block", file: file, line: token.line, end: end))
                }
                i = next
            } else {
                let (specs, next) = constSpecs(tokens, from: i + 1, block: false, known: &known)
                for spec in specs {
                    guard let type = spec.type, let value = spec.value else { continue }
                    typed.append(TypedConst(type: type, name: spec.name, value: describe(value), line: spec.line))
                }
                i = next
            }
        }
        return (blocks, typed)
    }

    struct Spec { var name: String; var type: String?; var value: ConstValue?; var line: Int }

    private static func candidate(_ specs: [Spec], name: String, file: String, line: Int, end: Int) -> Candidate {
        Candidate(name: name, file: file, line: line, endLine: end,
                  values: specs.compactMap { spec in spec.value.map { (describe($0), spec.name) } }.filter { $0.1 != "_" })
    }

    static func describe(_ value: ConstValue) -> String {
        switch value {
        case .int(let n): String(n)
        case .string(let s): s
        }
    }

    private static func constBlock(_ tokens: [GoToken], from start: Int, known: inout [String: ConstValue]) -> ([Spec], Int) {
        constSpecs(tokens, from: start, block: true, known: &known)
    }

    /// Const specs from `start`: a block's lines up to its `)`, or one spec up to the end of the line.
    /// An empty right side repeats the previous expression with the next `iota`.
    private static func constSpecs(_ tokens: [GoToken], from start: Int, block: Bool, known: inout [String: ConstValue]) -> ([Spec], Int) {
        var specs: [Spec] = []
        var i = start
        var iota = 0
        var previous: (type: String?, expr: [GoToken])?
        while i < tokens.count {
            // One spec: tokens to the newline (or `;`) at depth 0.
            var line: [GoToken] = []
            var depth = 0
            while i < tokens.count {
                let t = tokens[i]
                if t.text == "(" || t.text == "[" || t.text == "{" { depth += 1 }
                if t.text == ")" || t.text == "]" || t.text == "}" {
                    if depth == 0 { break }
                    depth -= 1
                }
                if depth == 0, t.kind == .newline || t.text == ";" { break }
                line.append(t)
                i += 1
            }
            if !line.isEmpty, line[0].kind == .ident {
                let name = line[0].text
                var j = 1
                var type: String?
                if j < line.count, line[j].kind == .ident {
                    type = line[j].text
                    j += 1
                    if j + 1 < line.count, line[j].text == ".", line[j + 1].kind == .ident { type = line[j + 1].text; j += 2 }
                }
                var expr: [GoToken]
                if j < line.count, line[j].text == "=" {
                    expr = Array(line[(j + 1)...])
                    previous = (type, expr)
                } else if j == line.count, let previous {
                    expr = previous.expr
                    type = type ?? previous.type
                } else {
                    expr = []
                }
                var parser = ConstExpr(tokens: expr, iota: iota, known: known)
                let value = expr.isEmpty ? nil : parser.parse()
                if let value, parser.atEnd { known[name] = value }
                specs.append(Spec(name: name, type: type, value: parser.atEnd ? value : nil, line: line[0].line))
                iota += 1
            }
            guard i < tokens.count else { break }
            if tokens[i].text == ")" && block { return (specs, i + 1) }
            if !block { return (specs, i) }
            i += 1
        }
        return (specs, i)
    }

    /// A Go constant expression: integers (decimal, hex, octal, binary, `_` separators), `iota`, strings,
    /// earlier constants, conversions (`Status(3)`), unary `-`, and `* / % << >> & + - | ^` by precedence.
    struct ConstExpr {
        let tokens: [GoToken]
        let iota: Int
        let known: [String: ConstValue]
        var position = 0
        init(tokens: [GoToken], iota: Int, known: [String: ConstValue]) { self.tokens = tokens; self.iota = iota; self.known = known }

        var atEnd: Bool { position >= tokens.count }

        mutating func parse() -> ConstValue? { binary(0) }

        private static let precedence: [String: Int] = ["|": 1, "^": 1, "+": 1, "-": 1, "*": 2, "/": 2, "%": 2, "<<": 2, ">>": 2, "&": 2]

        private mutating func binary(_ minimum: Int) -> ConstValue? {
            guard var left = unary() else { return nil }
            while position < tokens.count, let level = Self.precedence[tokens[position].text], level > minimum {
                let op = tokens[position].text
                position += 1
                guard let right = binary(level) else { return nil }
                switch (left, right) {
                case (.int(let a), .int(let b)):
                    switch op {
                    case "+": left = .int(a &+ b)
                    case "-": left = .int(a &- b)
                    case "*": left = .int(a &* b)
                    case "/": guard b != 0 else { return nil }; left = .int(a / b)
                    case "%": guard b != 0 else { return nil }; left = .int(a % b)
                    case "<<": left = .int(b >= 0 && b < 63 ? a << b : 0)
                    case ">>": left = .int(b >= 0 && b < 63 ? a >> b : 0)
                    case "&": left = .int(a & b)
                    case "|": left = .int(a | b)
                    case "^": left = .int(a ^ b)
                    default: return nil
                    }
                case (.string(let a), .string(let b)) where op == "+": left = .string(a + b)
                default: return nil
                }
            }
            return left
        }

        private mutating func unary() -> ConstValue? {
            guard position < tokens.count else { return nil }
            let token = tokens[position]
            position += 1
            switch token.kind {
            case .number: return Self.integer(token.text).map(ConstValue.int)
            case .string: return .string(token.text)
            case .punct:
                if token.text == "-", case .int(let n)? = unary() { return .int(-n) }
                if token.text == "+" { return unary() }
                if token.text == "(" {
                    let inner = binary(0)
                    guard position < tokens.count, tokens[position].text == ")" else { return nil }
                    position += 1
                    return inner
                }
                return nil
            case .ident:
                if token.text == "iota" { return .int(iota) }
                // A conversion: Type(expr) or pkg.Type(expr).
                if position + 1 < tokens.count, tokens[position].text == ".", tokens[position + 1].kind == .ident { position += 2 }
                if position < tokens.count, tokens[position].text == "(" {
                    position += 1
                    let inner = binary(0)
                    guard position < tokens.count, tokens[position].text == ")" else { return nil }
                    position += 1
                    return inner
                }
                return known[token.text]
            case .newline: return nil
            }
        }

        static func integer(_ text: String) -> Int? {
            let clean = text.replacingOccurrences(of: "_", with: "").lowercased()
            if clean.hasPrefix("0x") { return Int(clean.dropFirst(2), radix: 16) }
            if clean.hasPrefix("0b") { return Int(clean.dropFirst(2), radix: 2) }
            if clean.hasPrefix("0o") { return Int(clean.dropFirst(2), radix: 8) }
            if clean.count > 1, clean.hasPrefix("0"), clean.allSatisfy(\.isNumber) { return Int(clean.dropFirst(), radix: 8) }
            return Int(clean)
        }
    }

    // MARK: SQL

    static func sqlCandidates(_ repo: DriftRepo) -> [Candidate] {
        var types: [String: Candidate] = [:]
        var order: [String] = []
        var checks: [Candidate] = []
        for file in repo.sqlFiles {
            guard let text = repo.text(file) else { continue }
            let ns = text as NSString
            func line(_ location: Int) -> Int { ns.substring(to: location).filter { $0 == "\n" }.count + 1 }
            for match in createType.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let name = unquote(ns.substring(with: match.range(at: 1)))
                let values = quotedValues(ns.substring(with: match.range(at: 2)))
                let at = line(match.range.location)
                if types[name] == nil { order.append(name) }
                types[name] = Candidate(name: name, file: file, line: at, endLine: at, values: values.map { ($0, $0) })
            }
            for match in addValue.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let name = unquote(ns.substring(with: match.range(at: 1)))
                guard var type = types[name] else { continue }
                type.values.append((ns.substring(with: match.range(at: 2)), ns.substring(with: match.range(at: 2))))
                types[name] = type
            }
            for match in checkIn.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let column = unquote(ns.substring(with: match.range(at: 1)))
                let values = listValues(ns.substring(with: match.range(at: 2)))
                guard values.count >= 2 else { continue }
                let at = line(match.range.location)
                checks.append(Candidate(name: column, file: file, line: at, endLine: at, values: values.map { ($0, $0) }))
            }
        }
        return order.compactMap { types[$0] } + checks
    }

    private static let createType = try! NSRegularExpression(
        pattern: #"create\s+type\s+([\w."]+)\s+as\s+enum\s*\(([^)]*)\)"#, options: [.caseInsensitive])
    private static let addValue = try! NSRegularExpression(
        pattern: #"alter\s+type\s+([\w."]+)\s+add\s+value\s+(?:if\s+not\s+exists\s+)?'([^']*)'"#, options: [.caseInsensitive])
    private static let checkIn = try! NSRegularExpression(
        pattern: #"check\s*\(\s*\(?\s*([\w"]+)\s*\)?(?:\s*::\s*\w+)?\s+in\s*\(([^)]*)\)"#, options: [.caseInsensitive])

    private static func unquote(_ text: String) -> String {
        (text.split(separator: ".").last.map(String.init) ?? text).replacingOccurrences(of: "\"", with: "")
    }

    private static func quotedValues(_ text: String) -> [String] {
        text.components(separatedBy: "'").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
    }

    private static func listValues(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.compactMap { item in
            if item.hasPrefix("'") {
                return String(item.dropFirst().prefix { $0 != "'" })
            }
            let number = item.prefix { $0.isNumber || $0 == "-" }
            return number.isEmpty ? nil : String(number)
        }
    }

    // MARK: Check

    static func same(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if let x = Double(a), let y = Double(b) { return x == y }
        return false
    }

    /// Code names without the prefix they share (`StatusDraft`, `StatusPaid` → draft, paid), lowercased
    /// with separators dropped, for comparing with the map's names.
    static func shortNames(_ names: [String]) -> [String] {
        let lowered = names.map { $0.lowercased() }
        var prefix = lowered.first ?? ""
        for name in lowered.dropFirst() { while !name.hasPrefix(prefix) { prefix.removeLast() } }
        if names.count < 2 { prefix = "" }
        return lowered.map { name in
            let short = String(name.dropFirst(prefix.count))
            return (short.isEmpty ? name : short).filter { $0.isLetter || $0.isNumber }
        }
    }

    static func simple(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }

    private static let sentinels: Set<String> = ["unspecified", "unknown", "invalid", "count", "max", "min", "last", "first", "end",
                                                 "sentinel", "num", "total", "undefined", "none", "zero", "begin"]

    static func run(_ context: DriftContext) {
        guard !context.facts.enums.isEmpty else { return }
        let repo = context.repo
        let candidates = goCandidates(repo) + sqlCandidates(repo)
        for def in context.facts.enums where !def.values.isEmpty {
            context.checked(.enums)
            let key = "enums|\(def.id)"
            let location = DriftMapLocation(enumID: def.id, field: "values", line: def.line)
            let refs = def.code.compactMap { DriftCode.parse($0, root: repo.rootPath) }
            let mapValues = def.values
            let numericMap = mapValues.allSatisfy { Double($0.value) != nil }

            func score(_ candidate: Candidate) -> (overlap: Int, jaccard: Double) {
                let numericCandidate = candidate.values.allSatisfy { Double($0.value) != nil }
                // A string enum in the map (values are names) against an iota block: compare by name.
                if !numericMap && numericCandidate {
                    let short = Set(shortNames(candidate.values.map(\.name)))
                    let overlap = mapValues.filter { short.contains(simple($0.value)) || short.contains(simple($0.name)) }.count
                    return (overlap, Double(overlap) / Double(max(1, Set(mapValues.map(\.value)).union(short).count)))
                }
                let overlap = mapValues.filter { value in candidate.values.contains { same($0.value, value.value) } }.count
                let union = mapValues.count + candidate.values.count - overlap
                return (overlap, Double(overlap) / Double(max(1, union)))
            }
            // Scored once: only candidates sharing a value can be the definition.
            let scored = candidates.map { ($0, score($0)) }.filter { $0.1.overlap > 0 }
            let pointed = scored.filter { pair in
                refs.contains { ref in
                    ref.path == pair.0.file && (ref.line.map { $0 >= pair.0.line - 3 && $0 <= pair.0.endLine + 1 } ?? true)
                }
            }
            let needed = min(2, mapValues.count)
            let named = { (c: Candidate) in simple(c.name).contains(simple(def.id).prefix(5)) }
            let chosen = pointed.max { $0.1.jaccard < $1.1.jaccard }?.0
                ?? scored.filter { $0.1.overlap >= needed && $0.1.jaccard >= 0.4 }
                    .max { a, b in a.1.jaccard != b.1.jaccard ? a.1.jaccard < b.1.jaccard : !named(a.0) && named(b.0) }?.0
            guard let found = chosen else {
                context.add(DriftFinding(.info, .enums, "enum-not-found",
                                         message: "no const block, Postgres enum or CHECK in the repo has the values of \(def.id)",
                                         fix: def.code.isEmpty ? "Add code: pointing at where \(def.label) is defined, or check its values by hand."
                                            : "Check \(def.code.joined(separator: ", ")): the values may be defined another way.",
                                         map: location, ref: def.id), fact: nil)
                continue
            }
            let repoLocation = DriftRepoLocation(file: found.file, line: found.line)
            let numericCandidate = found.values.allSatisfy { Double($0.value) != nil }
            if !numericMap && numericCandidate {
                // Compare names only: the map keeps the names, the code numbers them.
                let short = shortNames(found.values.map(\.name))
                let mapNames = Set(mapValues.flatMap { [simple($0.value), simple($0.name)] })
                let added = zip(found.values, short).filter { !mapNames.contains($0.1) && !sentinels.contains($0.1) }.map { $0.0.name }
                let removed = mapValues.filter { !short.contains(simple($0.value)) && !short.contains(simple($0.name)) }.map(\.value)
                report(context, def: def, location: location, repo: repoLocation, added: added, removed: removed, key: key)
                continue
            }
            let codeNames = shortNames(found.values.map(\.name))
            var added: [String] = []
            for (index, value) in found.values.enumerated() where !mapValues.contains(where: { same($0.value, value.value) }) {
                if sentinels.contains(codeNames[index]) && !numericMap { continue }
                if sentinels.contains(codeNames[index]), value.value == "0" || value.value == "-1" { continue }
                added.append(value.value == value.name ? value.value : "\(value.value) (\(value.name))")
            }
            let removed = mapValues.filter { value in !found.values.contains { same($0.value, value.value) } }
                .map { $0.value == $0.name ? $0.value : "\($0.value) (\($0.name))" }
            // A string enum with one value swapped for another reads as a rename.
            if !numericMap, added.count == 1, removed.count == 1 {
                context.add(DriftFinding(.warn, .enums, "value-renamed",
                                         message: "\(def.id): \(removed[0]) is now \(added[0]) in \(found.file)",
                                         fix: "Rename the value \(removed[0]) to \(added[0]) (and in transitions and sample rows).",
                                         map: location, repo: repoLocation, ref: removed[0], found: added[0]), fact: key)
                continue
            }
            report(context, def: def, location: location, repo: repoLocation, added: added, removed: removed, key: key)
            // Renamed codes: the map's names follow the code's for most values, but not for this one.
            guard numericMap, found.values.contains(where: { $0.name != $0.value }) else { continue }
            var matched: [(map: EnumValue, code: String)] = []
            for value in mapValues {
                if let index = found.values.firstIndex(where: { same($0.value, value.value) }) { matched.append((value, codeNames[index])) }
            }
            let agree = matched.filter { simple($0.map.name) == $0.code || $0.code.contains(simple($0.map.name)) || simple($0.map.name).contains($0.code) }
            guard matched.count >= 3, Double(agree.count) / Double(matched.count) >= 0.6 else { continue }
            for pair in matched where !agree.contains(where: { $0.map.value == pair.map.value }) {
                let codeName = found.values.first { same($0.value, pair.map.value) }?.name ?? pair.code
                context.add(DriftFinding(.warn, .enums, "value-renamed",
                                         message: "\(def.id): \(pair.map.value) is \(codeName) in the code, \(pair.map.name) in the map",
                                         fix: "Rename \(pair.map.value) to match \(codeName), or check that its meaning hasn't changed.",
                                         map: location, repo: repoLocation, ref: "\(pair.map.value) \(pair.map.name)", found: codeName), fact: key)
            }
        }
    }

    private static func report(_ context: DriftContext, def: EnumDef, location: DriftMapLocation, repo: DriftRepoLocation,
                               added: [String], removed: [String], key: String) {
        if !added.isEmpty {
            context.add(DriftFinding(.warn, .enums, "value-added",
                                     message: "\(def.id): the code has \(added.joined(separator: ", ")), the map doesn't",
                                     fix: "Add \(added.count == 1 ? "the value" : "these values") to \(def.id) with name, doc and transitions.",
                                     map: location, repo: repo, ref: def.id, found: added.joined(separator: ", ")), fact: key)
        }
        if !removed.isEmpty {
            context.add(DriftFinding(.warn, .enums, "value-removed",
                                     message: "\(def.id): \(removed.joined(separator: ", ")) \(removed.count == 1 ? "is" : "are") no longer in \(repo.file)",
                                     fix: "Remove \(removed.count == 1 ? "it" : "them") from \(def.id), with their transitions, or find where \(removed.count == 1 ? "it moved" : "they moved").",
                                     map: location, repo: repo, ref: removed.joined(separator: ", ")), fact: key)
        }
    }
}
