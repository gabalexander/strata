import Foundation

/// What a manifest claims about its repo, collected from every level: code references with the symbols
/// their context names, SQL ops, binaries, topics and keys, enums, and all of the map's text (for
/// "does the map mention this name anywhere").
struct DriftMapFacts {
    struct CodeRef {
        var location: DriftMapLocation
        var ref: String
        /// Names the reference should still point at, with high confidence (a sqlc query name, a symbol
        /// written in the reference itself).
        var strong: [String]
        /// Names its context mentions as functions (`Acquire()` in the doc): checked only against definitions.
        var weak: [String]
        /// Functions the enclosing node or mechanism mentions: only used to guess where a missing file went.
        var context: [String] = []
    }

    struct SQLOp {
        var location: DriftMapLocation
        var op: Operation
        var code: [String]
    }

    struct Binary {
        var location: DriftMapLocation
        var binary: String
        var code: [String]
    }

    enum NameKind: String { case topic, queue, routingKey = "routing key", key }

    struct Name {
        var location: DriftMapLocation
        var kind: NameKind
        var value: String
    }

    var codeRefs: [CodeRef] = []
    var sql: [SQLOp] = []
    var binaries: [Binary] = []
    var names: [Name] = []
    var enums: [EnumDef] = []
    /// Every string of the map in one buffer: labels, docs, queries, keys, topics, commands, payloads.
    var text = ""

    init(_ manifest: Manifest) {
        enums = manifest.enums
        var parts: [String] = [manifest.title, manifest.summary ?? "", manifest.notes ?? ""]
        for def in manifest.enums {
            parts += [def.id, def.label, def.doc ?? ""] + def.values.flatMap { [$0.value, $0.name, $0.doc ?? ""] }
            let location = DriftMapLocation(enumID: def.id, field: "code", line: def.line)
            for ref in def.code { codeRefs.append(CodeRef(location: location, ref: ref, strong: [], weak: Self.functions(in: def.doc))) }
        }
        walk(manifest.root, path: [], parts: &parts)
        text = parts.joined(separator: "\n")
    }

    private mutating func walk(_ level: Level, path: [String], parts: inout [String]) {
        parts.append(level.narration ?? "")
        for flow in level.flows { parts.append(flow.label) }
        for node in level.nodes {
            let at = DriftMapLocation(level: path, node: node.id, line: node.line)
            parts += [node.id, node.label, node.tech ?? "", node.doc ?? "", node.binary ?? ""]
            let nodeWeak = Self.functions(in: node.doc)
            for ref in node.code { codeRefs.append(CodeRef(location: with(at, field: "code"), ref: ref, strong: [], weak: nodeWeak)) }
            if let binary = node.binary, !binary.trimmingCharacters(in: .whitespaces).isEmpty {
                binaries.append(Binary(location: with(at, field: "binary"), binary: binary, code: node.code))
            }
            if let formula = node.formula { formulaRefs(formula, at: at, parts: &parts) }
            for entity in node.entities {
                parts += [entity.name, entity.doc ?? ""]
                for ref in entity.code { codeRefs.append(CodeRef(location: with(at, field: "entities"), ref: ref, strong: [], weak: [entity.name])) }
            }
            for table in node.schema { parts += [table.name, table.doc ?? ""] + table.columns.map(\.name) }
            for mechanism in node.how { mechanismRefs(mechanism, at: at, context: nodeWeak, parts: &parts) }
            for op in node.ops { opFacts(op, node: node, path: path, context: nodeWeak, parts: &parts) }
            if let inside = node.inside { walk(inside, path: path + [node.id], parts: &parts) }
        }
    }

    private mutating func opFacts(_ op: Operation, node: Node, path: [String], context: [String], parts: inout [String]) {
        let at = DriftMapLocation(level: path, node: node.id, op: op.id, line: op.line ?? node.line)
        parts += [op.id, op.label, op.doc ?? "", op.query ?? "", op.command ?? "", op.key ?? "", op.topic ?? "", op.group ?? "",
                  op.payload ?? "", op.method ?? "", op.path ?? "", op.request ?? "", op.response ?? ""]
        parts += op.facts.map { "\($0.key) \($0.value)" } + op.tables + op.indexes
        var strong: [String] = []
        if let query = op.query { strong += DriftSQL.sqlcNames(in: query).map(\.name) }
        var weak = Self.functions(in: op.doc)
        if op.kind == .rpc, let method = op.method, let last = method.split(separator: "/").last, last.count >= 3 { weak.append(String(last)) }
        if Self.isIdentifier(op.label), op.label.count >= 4, op.label.contains(where: \.isUppercase) { weak.append(op.label) }
        for ref in op.code { codeRefs.append(CodeRef(location: with(at, field: "code"), ref: ref, strong: strong, weak: weak, context: context)) }
        if op.kind == .sql || op.kind == .search, let query = op.query, SQLFormat.looksLikeSQL(query) || !DriftSQL.sqlcNames(in: query).isEmpty {
            sql.append(SQLOp(location: with(at, field: "query"), op: op, code: op.code))
        }
        switch op.kind {
        case .publish, .consume:
            if let topic = op.topic { names.append(Name(location: with(at, field: "topic"), kind: .topic, value: topic)) }
            if let group = op.group { names.append(Name(location: with(at, field: "group"), kind: .queue, value: group)) }
            if let key = op.key { names.append(Name(location: with(at, field: "key"), kind: .routingKey, value: key)) }
        case .cache:
            if let key = op.key { names.append(Name(location: with(at, field: "key"), kind: .key, value: key)) }
        default: break
        }
        if let formula = op.formula { formulaRefs(formula, at: at, parts: &parts) }
        for mechanism in op.how { mechanismRefs(mechanism, at: at, context: context + weak, parts: &parts) }
        if let inside = op.inside { walk(inside, path: path + ["\(node.id)#\(op.id)"], parts: &parts) }
    }

    private mutating func formulaRefs(_ formula: Formula, at: DriftMapLocation, parts: inout [String]) {
        parts += [formula.expr, formula.doc ?? "", formula.example ?? ""]
        for ref in formula.code { codeRefs.append(CodeRef(location: with(at, field: "formula"), ref: ref, strong: [], weak: Self.functions(in: formula.doc))) }
    }

    private mutating func mechanismRefs(_ mechanism: Mechanism, at: DriftMapLocation, context: [String], parts: inout [String]) {
        var base = at
        base.mechanism = mechanism.id
        base.line = mechanism.line ?? at.line
        parts += [mechanism.title, mechanism.summary ?? ""] + mechanism.initial.flatMap { [$0.key, $0.value ?? ""] }
        let weak = Self.functions(in: mechanism.summary)
        for ref in mechanism.code { codeRefs.append(CodeRef(location: with(base, field: "code"), ref: ref, strong: [], weak: weak, context: context)) }
        for step in mechanism.steps + mechanism.branches.flatMap(\.steps) {
            var location = base
            location.step = step.id
            location.line = step.line ?? base.line
            parts += [step.label, step.command ?? "", step.reply ?? "", step.note ?? ""] + step.state.flatMap { [$0.key, $0.value ?? ""] }
            for ref in step.code {
                codeRefs.append(CodeRef(location: with(location, field: "code"), ref: ref, strong: [], weak: Self.functions(in: step.note),
                                        context: weak + context))
            }
        }
        for branch in mechanism.branches { parts += [branch.label, branch.note ?? ""] }
    }

    private func with(_ location: DriftMapLocation, field: String) -> DriftMapLocation {
        var copy = location
        copy.field = field
        return copy
    }

    // MARK: Symbols

    /// Function names a markdown text writes as code: `` `Acquire()` ``, `` `lock.Acquire()` ``,
    /// `` `(*Lock).Acquire` ``, `` `func Acquire` ``.
    static func functions(in text: String?) -> [String] {
        guard let text, text.contains("`") else { return [] }
        var out: [String] = []
        for span in text.split(separator: "`", omittingEmptySubsequences: false).enumerated() where span.offset % 2 == 1 {
            var code = span.element.trimmingCharacters(in: .whitespaces)
            if code.hasPrefix("func ") {
                code.removeFirst(5)
                if code.hasPrefix("("), let close = code.firstIndex(of: ")") { code = String(code[code.index(after: close)...]).trimmingCharacters(in: .whitespaces) }
                let name = code.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                if name.count >= 3 { out.append(String(name)) }
                continue
            }
            let isCall = code.hasSuffix("()")
            let isMethod = code.hasPrefix("(*") || code.hasPrefix("(")
            guard isCall || isMethod, !code.contains(" ") else { continue }
            if isCall { code.removeLast(2) }
            guard let name = code.split(whereSeparator: { $0 == "." || $0 == ")" }).last.map(String.init),
                  isIdentifier(name), name.count >= 3 else { continue }
            out.append(name)
        }
        return Array(Set(out)).sorted()
    }

    static func isIdentifier(_ text: String) -> Bool {
        guard let first = text.first, first.isLetter || first == "_" else { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
