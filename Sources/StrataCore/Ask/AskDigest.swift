import Foundation

// The map as Ask sends it to Claude (docs/architecture.md, Ask): a compact, deterministic text digest
// of every level, node, op, mechanism, enum, table, flow, control and scenario, with the ids the
// answer's `strata:` links use. It fits a size budget by cutting the least important detail first,
// tier by tier, and says what it cut. The selected node keeps full detail and the level on screen
// keeps one tier more than the rest.

/// Where the user is in the app when they ask: the level on screen and what is selected on it.
public struct AskFocus: Sendable, Hashable {
    public var path: [String]
    public var node: String?
    public var flow: String?

    public init(path: [String] = [], node: String? = nil, flow: String? = nil) {
        self.path = path; self.node = node; self.flow = flow
    }
}

public struct AskDigest: Sendable {
    public let text: String
    /// 0 is everything; each tier past it cuts more (see `AskDigest.cuts`).
    public let tier: Int
    /// What was left out, least important first, for the prompt and the report.
    public let cut: [String]
    /// True when even the last tier was over budget and the text was cut short.
    public let truncated: Bool

    public var bytes: Int { text.utf8.count }
    /// About four bytes per token for this mix of prose, ids and SQL.
    public var estimatedTokens: Int { (bytes + 3) / 4 }

    /// About 37k tokens: all of a typical map at full detail (the bundled checkout map is 29 KB), and the
    /// ops, tables and short queries of a very large one, while staying small next to the model's context.
    public static let defaultBudget = 150_000

    /// What each tier cuts on top of the tiers before it.
    public static let cuts = [
        "sample rows past the second, term details, control insights, mechanism notes and state, long payloads",
        "sample rows, docs past 240 characters, payloads, op facts, mechanism replies, formula examples, scenario steps, glossary terms",
        "docs past 120 characters, op docs, risks and status codes, mechanism steps, flow step labels, queries past 600 characters",
        "docs, code paths, node parameters, traffic and SLOs, column types, indexes, mechanism summaries, transition labels, "
            + "enum value docs, controls, queries past 200 characters",
        "queries, op fields besides kind, target, access and tables, columns, flow steps, formulas",
        "op details outside the level on screen (one line per node), entities, groups",
    ]

    public static func build(_ manifest: Manifest, file: String?, focus: AskFocus = AskFocus(),
                             budget: Int = defaultBudget) -> AskDigest {
        func render(_ tier: Int) -> String {
            var writer = AskDigestWriter(manifest: manifest, file: file, focus: focus, tier: tier)
            return writer.render()
        }
        var tier = 0
        var text = render(0)
        while text.utf8.count > budget, tier < cuts.count {
            tier += 1
            text = render(tier)
        }
        var cut = Array(cuts.prefix(tier))
        var truncated = false
        if text.utf8.count > budget {
            truncated = true
            let kept = AskDigestWriter.prefix(text, bytes: max(0, budget - 200))
            text = kept + "\n… [digest cut at \(budget / 1000) KB: Grep the manifest file by id for the rest]\n"
            cut.append("everything past \(budget / 1000) KB")
        }
        return AskDigest(text: text, tier: tier, cut: cut, truncated: truncated)
    }
}

/// Renders one tier of the digest. Pure: the same manifest, focus and tier give the same text.
struct AskDigestWriter {
    let manifest: Manifest
    let file: String?
    let focus: AskFocus
    let tier: Int
    private var lines: [String] = []

    init(manifest: Manifest, file: String?, focus: AskFocus, tier: Int) {
        self.manifest = manifest; self.file = file; self.focus = focus; self.tier = tier
    }

    mutating func render() -> String {
        header()
        let levels = manifest.everyLevel()
        let focused = levels.first { $0.path == focus.path }
        if let focused, !focused.path.isEmpty { level(focused.path, focused.level) }
        enums()
        for (path, level) in levels where path != focused?.path || path.isEmpty {
            self.level(path, level)
        }
        terms()
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Tiers

    /// The level on screen keeps one tier more detail than the rest.
    private func levelTier(_ path: [String]) -> Int { path == focus.path ? max(0, tier - 1) : tier }

    /// The selected node keeps everything.
    private func nodeTier(_ node: Node, _ path: [String]) -> Int {
        path == focus.path && node.id == focus.node ? 0 : levelTier(path)
    }

    // MARK: Sections

    private mutating func header() {
        var title = "MAP \(manifest.id) · \(quoted(manifest.title)) · \(manifest.kind.rawValue)"
        if let category = manifest.category { title += " · category \(category)" }
        lines.append(title)
        if let file { lines.append("file: \(file)") }
        if let repo = manifest.repo { lines.append("repo: \(repo)") }
        if let summary = manifest.summary { lines.append("summary: \(Self.clip(summary, 400))") }
        if !manifest.tags.isEmpty { lines.append("tags: \(manifest.tags.joined(separator: ", "))") }
        if let notes = manifest.notes, tier <= 2 { lines.append("about: \(Self.clip(notes, tier == 0 ? 900 : 400))") }
        if manifest.layout == .manual { lines.append("layout: manual") }
    }

    private mutating func enums() {
        guard !manifest.enums.isEmpty else { return }
        lines.append("")
        lines.append("ENUMS (link: strata:enum/<id>/<value>)")
        let columns = manifest.enumColumns()
        for def in manifest.enums {
            var line = "- \(def.id) \(quoted(def.label))"
            if let doc = def.doc, tier <= 3 { line += " — \(Self.clip(doc, tier <= 1 ? 300 : 140))" }
            if let code = def.code.first, tier <= 3 { line += " · code \(def.code.count > 1 ? def.code.joined(separator: ", ") : code)" }
            lines.append(line)
            if tier >= 4 {
                lines.append("  values: " + def.values.map { "\($0.value) \($0.name)\($0.terminal ? " (terminal)" : "")" }.joined(separator: "; "))
            } else {
                for value in def.values {
                    var item = "  \(value.value) \(value.name)\(value.terminal ? " (terminal)" : "")"
                    if let doc = value.doc, tier <= 3 { item += " — \(Self.clip(doc, tier <= 1 ? 240 : 120))" }
                    lines.append(item)
                }
            }
            if !def.transitions.isEmpty {
                lines.append("  transitions: " + def.transitions.map { t in
                    var s = "\(t.from)→\(t.to)"
                    if let label = t.label, tier <= 3 { s += " \(label)" }
                    if let by = t.by { s += " (by \(by))" }
                    return s
                }.joined(separator: "; "))
            }
            let held = columns.filter { $0.enumID == def.id }
            if !held.isEmpty {
                lines.append("  columns: " + held.map { column in
                    (column.path.isEmpty ? "" : column.path.joined(separator: "/") + ":") + column.column.description
                }.joined(separator: ", "))
            }
        }
    }

    private mutating func terms() {
        guard !manifest.terms.isEmpty, tier <= 1 else { return }
        lines.append("")
        lines.append("TERMS")
        for term in manifest.terms {
            var line = "- \(term.term): \(Self.clip(term.short, 200))"
            if tier == 0, let detail = term.detail { line += " \(Self.clip(detail, 240))" }
            lines.append(line)
        }
    }

    private mutating func level(_ path: [String], _ level: Level) {
        let t = levelTier(path)
        lines.append("")
        if path.isEmpty {
            lines.append("LEVEL root (links: strata:node/<id>)")
        } else {
            let owner = Self.ownerLabel(path, in: manifest)
            let prefix = path.joined(separator: "/")
            lines.append("LEVEL \(prefix) · inside \(owner) (links: strata:node/\(prefix)/<id>, strata:level/\(prefix))")
        }
        if path == focus.path { lines.append("(the user is looking at this level)") }
        if let narration = level.narration, t <= 3 {
            lines.append("narration: \(Self.clip(narration, [600, 400, 240, 120][t]))")
        }
        if !level.groups.isEmpty, t <= 5 {
            lines.append("groups: " + level.groups.map { group in
                "\(group.id) \(quoted(group.label)) (\(group.kind.rawValue)\(group.parent.map { ", in \($0)" } ?? ""))"
            }.joined(separator: "; "))
        }
        for node in level.nodes { self.node(node, path: path, level: level) }
        if t <= 2, let inherited = manifest.inheritedOps(at: path) {
            let mapped = inherited.entries.compactMap { entry -> String? in
                guard let peer = entry.peer else { return nil }
                return "\(entry.op.id)→\(peer)" + (entry.performer.map { $0 == peer ? "" : " (by \($0))" } ?? "")
            }
            if !mapped.isEmpty { lines.append("ops of \(inherited.owner.id) mapped here: " + mapped.joined(separator: ", ")) }
        }
        let edges = level.edges.filter { !$0.implicit }
        if !edges.isEmpty {
            lines.append("edges: " + edges.map { edge in
                var s = "\(edge.from)→\(edge.to)"
                let detail = [edge.protocol, edge.label.flatMap { $0 == edge.protocol ? nil : $0 },
                              t <= 3 ? edge.latency.map(Self.dist) : nil, edge.loss.map { "loss \(Self.percent($0))" }]
                    .compactMap { $0 }
                if !detail.isEmpty { s += " " + detail.joined(separator: " ") }
                return s
            }.joined(separator: "; "))
        }
        flows(level, path: path, tier: t)
        scenarios(level, tier: t)
        controls(level, tier: t)
    }

    private mutating func node(_ node: Node, path: [String], level: Level) {
        let t = nodeTier(node, path)
        var head = "NODE \(node.id) [\(node.kind.rawValue)] \(quoted(node.label))"
        var facts: [String] = []
        if let tech = node.tech { facts.append(tech) }
        if let group = node.group, t <= 4 { facts.append("group \(group)") }
        if t <= 3 { facts += Self.params(node.params) }
        if !node.code.isEmpty, t <= 3 { facts.append("code \(node.code.joined(separator: ", "))") }
        if let binary = node.binary, t <= 3 { facts.append("binary \(binary)") }
        if node.inside != nil { facts.append("deep dive: strata:level/\((path + [node.id]).joined(separator: "/"))") }
        if let detail = node.detail { facts.append("deep dive in manifest \(detail)") }
        if !facts.isEmpty { head += " · " + facts.joined(separator: " · ") }
        if path == focus.path, node.id == focus.node { head += " · SELECTED" }
        lines.append(head)

        if let brief = Self.brief(node) { lines.append("  brief: \(Self.clip(brief, 200))") }
        if let doc = node.doc, t <= 3 { lines.append("  doc: \(Self.clip(doc, [700, 500, 240, 120][t]))") }
        if let term = node.term, t <= 1 { lines.append("  term: \(term)") }
        if let formula = node.formula { self.formula(formula, indent: "  ", tier: t) }
        if !node.actions.isEmpty, t <= 2 {
            lines.append("  actions: " + node.actions.map { "\($0.label) (\($0.commands.map(Self.command).joined(separator: "; ")))" }
                .joined(separator: "; "))
        }
        ops(node, path: path, tier: t)
        if !node.how.isEmpty {
            lines.append("  how (link: strata:how/\((path + [node.id]).joined(separator: "/"))/<id>):")
            for mechanism in node.how { self.mechanism(mechanism, indent: "  ", tier: t) }
        }
        if !node.entities.isEmpty {
            if t >= 6 {
                lines.append("  entities: " + node.entities.map(\.name).joined(separator: ", "))
            } else {
                lines.append("  entities:")
                for entity in node.entities {
                    var line = "  - \(entity.name): root \(entity.root)"
                    if !entity.includes.isEmpty { line += " + \(entity.includes.joined(separator: ", "))" }
                    if let source = entity.source { line += " (from \(source))" }
                    if let doc = entity.doc, t <= 2 { line += " — \(Self.clip(doc, 160))" }
                    lines.append(line)
                }
            }
        }
        if !node.schema.isEmpty { schema(node, tier: t) }
    }

    private mutating func ops(_ node: Node, path: [String], tier t: Int) {
        guard !node.ops.isEmpty else { return }
        let prefix = (path + [node.id]).joined(separator: "/")
        if t >= 6 {
            // One line: what each op is and touches, enough for "who writes X" and a link.
            lines.append("  ops (strata:op/\(prefix)/<id>): " + node.ops.map { op in
                var s = "\(op.id) \(op.kind.rawValue)"
                if let target = op.target { s += "→\(target)" }
                if let access = op.access { s += " \(access.rawValue)" }
                if !op.tables.isEmpty { s += " [\(op.tables.joined(separator: ", "))]" }
                return s
            }.joined(separator: "; "))
            return
        }
        lines.append("  ops (link: strata:op/\(prefix)/<id>):")
        for op in node.ops {
            var head = "  - \(op.id) \(op.kind.rawValue) \(op.direction == .inbound ? "in" : "out")"
            if let target = op.target { head += " →\(target)" }
            if let access = op.access { head += " \(access.rawValue)" }
            head += " \(quoted(op.label))"
            if !op.tables.isEmpty { head += " · tables \(op.tables.joined(separator: ", "))" }
            if t <= 4 {
                var parts: [String] = []
                if !op.indexes.isEmpty, t <= 3 { parts.append("indexes \(op.indexes.joined(separator: ", "))") }
                if op.tx == true { parts.append("tx") }
                if let locks = op.locks, t <= 3 { parts.append("locks \(locks)") }
                if let method = op.method { parts.append(method) }
                if let path = op.path { parts.append(path) }
                if let command = op.command { parts.append("command \(command)") }
                if let key = op.key { parts.append("key \(key)") }
                if let ttl = op.ttl { parts.append("ttl \(Self.duration(ttl))") }
                if let topic = op.topic { parts.append("topic \(topic)") }
                if let group = op.group { parts.append("group \(group)") }
                if let streaming = op.streaming, t <= 3 { parts.append(streaming) }
                if let calls = op.calls { parts.append("calls \(calls)") }
                if !op.code.isEmpty, t <= 3 { parts.append("code \(op.code.joined(separator: ", "))") }
                if !parts.isEmpty { head += " · " + parts.joined(separator: " · ") }
            }
            lines.append(head)
            let pad = "    "
            if let brief = Self.brief(op) { lines.append(pad + "brief: \(Self.clip(brief, 200))") }
            if let doc = op.doc, t <= 2 { lines.append(pad + "doc: \(Self.clip(doc, [500, 400, 300][t]))") }
            if let query = op.query, t <= 4 {
                let limit = [Int.max, Int.max, Int.max, 600, 200][t]
                lines.append(pad + "query: \(Self.clip(query, limit))")
            }
            for (name, value) in [("request", op.request), ("response", op.response), ("payload", op.payload)] {
                guard let value, t <= 1 else { continue }
                lines.append(pad + "\(name): \(Self.clip(value, t == 0 ? 300 : 100))")
            }
            if !op.status.isEmpty, t <= 2 { lines.append(pad + "status: \(op.status.joined(separator: "; "))") }
            if !op.facts.isEmpty, t <= 1 {
                lines.append(pad + "facts: " + op.facts.map { "\($0.key)=\(Self.clip($0.value, 120))" }.joined(separator: "; "))
            }
            if !op.risks.isEmpty, t <= 2 { lines.append(pad + "risks: \(op.risks.map { Self.clip($0, 160) }.joined(separator: "; "))") }
            if let formula = op.formula { self.formula(formula, indent: pad, tier: t) }
            if !op.how.isEmpty, t <= 5 {
                lines.append(pad + "how (link: strata:how/\(prefix)/\(op.id)/<id>):")
                for mechanism in op.how { self.mechanism(mechanism, indent: pad, tier: t) }
            }
            if op.inside != nil { lines.append(pad + "own level: strata:level/\(prefix)%23\(op.id)") }
            if let detail = op.detail { lines.append(pad + "detail manifest: \(detail)") }
        }
    }

    private mutating func mechanism(_ mechanism: Mechanism, indent: String, tier t: Int) {
        var head = indent + "- \(mechanism.id) \(quoted(mechanism.title))"
        if !mechanism.code.isEmpty, t <= 3 { head += " · code \(mechanism.code.joined(separator: ", "))" }
        if t >= 3 { head += " · \(mechanism.steps.count) steps, \(mechanism.branches.count) branches" }
        lines.append(head)
        let pad = indent + "  "
        if let summary = mechanism.summary, t <= 3 { lines.append(pad + "summary: \(Self.clip(summary, [500, 400, 300, 160][t]))") }
        if t >= 3 { return }
        if !mechanism.participants.isEmpty {
            lines.append(pad + "participants: " + mechanism.participants.map { p in
                "\(p.id)=\(p.label)" + (p.node.map { $0 == p.label ? "" : " (\($0))" } ?? "")
            }.joined(separator: "; "))
        }
        if !mechanism.initial.isEmpty, t == 0 {
            lines.append(pad + "initial: " + mechanism.initial.map(Self.state).joined(separator: "; "))
        }
        for step in mechanism.steps { lines.append(pad + self.step(step, tier: t)) }
        for branch in mechanism.branches {
            var line = pad + "branch \(branch.id) \(quoted(branch.label))" + (branch.after.map { " after \($0)" } ?? " from the start")
            if let note = branch.note, t == 0 { line += " — \(Self.clip(note, 200))" }
            lines.append(line)
            for step in branch.steps { lines.append(pad + "  " + self.step(step, tier: t)) }
        }
    }

    private func step(_ step: MechStep, tier t: Int) -> String {
        var s = "\(step.id) \(step.from)→\(step.to) \(step.label)"
        if let command = step.command { s += ": \(Self.clip(command, [600, 300, 120][min(t, 2)]))" }
        if let reply = step.reply, t <= 1 { s += " → \(Self.clip(reply, 120))" }
        if let at = step.at { s += " @\(Self.duration(at))" }
        if !step.state.isEmpty, t == 0 { s += " · state " + step.state.map(Self.state).joined(separator: ", ") }
        if let note = step.note, t == 0 { s += " · note: \(Self.clip(note, 200))" }
        return s
    }

    private mutating func formula(_ formula: Formula, indent: String, tier t: Int) {
        guard t <= 4 else { return }
        var line = indent + "formula: \(Self.clip(formula.expr, t <= 2 ? 600 : 240))"
        if t <= 2, !formula.vars.isEmpty {
            line += " · where " + formula.vars.map { "\($0.name): \(Self.clip($0.meaning, 120))" }.joined(separator: "; ")
        }
        if t <= 1, let example = formula.example { line += " · example: \(Self.clip(example, 200))" }
        lines.append(line)
    }

    private mutating func schema(_ node: Node, tier t: Int) {
        if t >= 5 {
            lines.append("  tables (strata:table/\(node.id)/<table>): " + node.schema.map(\.name).joined(separator: ", "))
            return
        }
        lines.append("  tables (link: strata:table/\(node.id)/<table>):")
        for table in node.schema {
            var head = "  - \(table.name)"
            if let doc = table.doc, t <= 3 { head += " — \(Self.clip(doc, t <= 1 ? 200 : 100))" }
            if let volume = table.volume {
                let parts = [volume.rows.map { "\(Self.count($0)) rows" }, volume.growthPerDay.map { "+\(Self.count($0))/day" }].compactMap { $0 }
                if !parts.isEmpty { head += " · " + parts.joined(separator: ", ") }
            }
            if let owner = table.owner { head += " · owner \(owner)" }
            lines.append(head)
            if t <= 3 {
                lines.append("    columns: " + table.columns.map { column in
                    var s = column.name
                    if let type = column.type { s += " \(type)" }
                    if column.pk { s += " pk" }
                    if column.unique { s += " unique" }
                    if let ref = column.ref { s += " →\(ref)" }
                    if let id = column.enumRef { s += " enum:\(id)" }
                    if let note = column.note, t <= 1 { s += " (\(Self.clip(note, 60)))" }
                    return s
                }.joined(separator: ", "))
            } else {
                lines.append("    columns: " + table.columns.map { $0.name + ($0.pk ? " pk" : "") + ($0.ref.map { " →\($0)" } ?? "") }
                    .joined(separator: ", "))
            }
            if !table.indexes.isEmpty, t <= 3 { lines.append("    indexes: \(table.indexes.joined(separator: "; "))") }
            let rows = t == 0 ? 3 : t == 1 ? 2 : 0
            if rows > 0, !table.rows.isEmpty {
                lines.append("    rows: " + table.rows.prefix(rows).map { row in
                    "(" + row.map { $0.map { Self.clip($0, 40) } ?? "NULL" }.joined(separator: ", ") + ")"
                }.joined(separator: "; ") + (table.rows.count > rows ? " (+\(table.rows.count - rows) more)" : ""))
            }
        }
    }

    private mutating func flows(_ level: Level, path: [String], tier t: Int) {
        guard !level.flows.isEmpty else { return }
        lines.append("flows:")
        for flow in level.flows {
            let ft = path == focus.path && flow.id == focus.flow ? 0 : t
            var head = "- \(flow.id) \(quoted(flow.label))"
            if let from = flow.from { head += " from \(from) \(Self.rate(flow.rate))" }
            if let on = flow.on { head += " on \(on) by \(flow.by ?? "?")" }
            if let op = flow.op { head += " op \(op)" }
            if let deadline = flow.deadline { head += " deadline \(Self.duration(deadline))" }
            if ft <= 3 {
                if let traffic = flow.traffic {
                    if let peak = traffic.peak { head += " · peak \(Self.number(peak))/s" }
                    if let daily = traffic.daily { head += " · daily \(Self.count(daily))" }
                }
                if let slo = flow.slo {
                    let parts = [slo.p50.map { "p50 \(Self.duration($0))" }, slo.p99.map { "p99 \(Self.duration($0))" },
                                 slo.errors.map { "errors \(Self.percent($0))" }].compactMap { $0 }
                    if !parts.isEmpty { head += " · slo " + parts.joined(separator: " ") }
                }
            }
            if path == focus.path, flow.id == focus.flow { head += " · SELECTED" }
            if ft <= 4, !flow.steps.isEmpty { head += ": " + Self.steps(flow.steps, labels: ft <= 2) }
            lines.append(head)
        }
    }

    private mutating func scenarios(_ level: Level, tier t: Int) {
        guard !level.scenarios.isEmpty else { return }
        lines.append("scenarios (link: strata:scenario/<id>):")
        for scenario in level.scenarios {
            var line = "- \(scenario.id) \(quoted(scenario.label))"
            if let goal = scenario.goal, t <= 3 { line += " — goal: \(Self.clip(goal, t <= 2 ? 240 : 120))" }
            if t <= 1 {
                if !scenario.setup.isEmpty { line += " · setup: " + scenario.setup.map(Self.command).joined(separator: "; ") }
                if !scenario.steps.isEmpty {
                    line += " · steps: " + scenario.steps.map { step in
                        var s = "\(Self.duration(step.at)) " + step.commands.map(Self.command).joined(separator: "; ")
                        if let say = step.say, t <= 0 { s += " (\(Self.clip(say, 120)))" }
                        return s.trimmingCharacters(in: .whitespaces)
                    }.joined(separator: "; ")
                }
                if !scenario.watch.isEmpty, t <= 1 { line += " · watch \(scenario.watch.joined(separator: ", "))" }
            }
            lines.append(line)
        }
    }

    private mutating func controls(_ level: Level, tier t: Int) {
        guard !level.controls.isEmpty, t <= 3 else { return }
        lines.append("controls: " + level.controls.map { control in
            var s = "\(quoted(control.label)) → \(control.bind)"
            if t <= 2 {
                switch control.input {
                case .range(let min, let max, _): s += " \(Self.number(min))…\(Self.number(max))\(control.unit.map { " \($0)" } ?? "")"
                case .options(let values): s += " [\(values.map(\.description).joined(separator: ", "))]"
                case .toggle: s += " on/off"
                }
            }
            if t == 0, !control.insights.isEmpty {
                s += " {" + control.insights.map { "\(Self.condition($0.when)): \(Self.clip($0.text, 140))" }.joined(separator: " | ") + "}"
            }
            return s
        }.joined(separator: "; "))
    }

    // MARK: Formatting

    private func quoted(_ text: String) -> String { "\"" + Self.clip(text, 120) + "\"" }

    /// Whitespace collapsed to single spaces, cut at a word boundary near `limit` characters.
    static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard limit < Int.max, flat.count > limit else { return flat }
        let cut = flat.prefix(limit)
        let end = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return String(end.count > limit / 2 ? end : cut) + "…"
    }

    /// The longest prefix of `text` within `bytes` UTF-8 bytes that ends at a line break.
    static func prefix(_ text: String, bytes: Int) -> String {
        var used = 0
        var end = text.startIndex
        for index in text.indices {
            used += text[index].utf8.count
            if used > bytes { break }
            if text[index] == "\n" { end = index }
        }
        return String(text[..<end])
    }

    /// `brief:` (a one-line summary another branch adds to nodes and ops) when the model has it, read
    /// by reflection so this builds with or without that field.
    static func brief(_ value: Any) -> String? {
        for child in Mirror(reflecting: value).children where child.label == "brief" {
            if let text = child.value as? String, !text.isEmpty { return text }
        }
        return nil
    }

    static func ownerLabel(_ path: [String], in manifest: Manifest) -> String {
        guard let last = path.last else { return manifest.title }
        let parent = manifest.level(at: Array(path.dropLast()))
        if let hash = last.firstIndex(of: "#") {
            let node = String(last[..<hash]), op = String(last[last.index(after: hash)...])
            let label = parent?.node(node)?.ops.first { $0.id == op }?.label ?? op
            return "\(parent?.node(node)?.label ?? node) · \(label)"
        }
        return parent?.node(last)?.label ?? last
    }

    static func steps(_ steps: [Step], labels: Bool) -> String {
        steps.map { step in
            var s: String
            switch step.action {
            case .call(let target, let inner, let miss):
                s = target
                if labels, let label = step.label { s += " \"\(clip(label, 60))\"" }
                s += options(step)
                if !inner.isEmpty { s += " { " + Self.steps(inner, labels: labels) + " }" }
                if !miss.isEmpty { s += " miss { " + Self.steps(miss, labels: labels) + " }" }
            case .publish(let target):
                s = "publish \(target)"
                if labels, let label = step.label { s += " \"\(clip(label, 60))\"" }
                s += options(step)
            case .work(let latency):
                s = "work \(dist(latency))" + options(step)
            case .parallel(let branches):
                s = "parallel { " + branches.map { Self.steps([$0], labels: labels) }.joined(separator: " | ") + " }"
            }
            return s
        }.joined(separator: "; ")
    }

    private static func options(_ step: Step) -> String {
        var parts: [String] = []
        if let op = step.op { parts.append("op \(op)") }
        if let timeout = step.timeout { parts.append("timeout \(duration(timeout))") }
        if let retries = step.retries { parts.append("retries \(retries)") }
        if let breaker = step.breaker { parts.append("breaker \(breaker.failures)/\(duration(breaker.cooldown))") }
        if let p = step.p { parts.append("p \(percent(p))") }
        if step.optional { parts.append("optional") }
        return parts.isEmpty ? "" : " [" + parts.joined(separator: ", ") + "]"
    }

    static func params(_ p: NodeParams) -> [String] {
        var parts: [String] = []
        if let v = p.latency { parts.append("latency \(dist(v))") }
        if let v = p.concurrency { parts.append("concurrency \(v)") }
        if let v = p.replicas { parts.append("replicas \(v)") }
        if let v = p.queue { parts.append("queue \(v)") }
        if let v = p.errors { parts.append("errors \(percent(v))") }
        if let v = p.timeout { parts.append("timeout \(duration(v))") }
        if let v = p.retries { parts.append("retries \(v)") }
        if let v = p.backoff { parts.append("backoff \(duration(v))") }
        if p.async == true { parts.append("async") }
        if let v = p.capacity { parts.append("capacity \(v)") }
        if let v = p.overflow { parts.append("overflow \(v.rawValue)") }
        if let v = p.ttl { parts.append("ttl \(duration(v))") }
        if let v = p.dlq { parts.append("dlq \(v)") }
        if let v = p.prefetch { parts.append("prefetch \(v)") }
        if let v = p.ack { parts.append("ack \(v.rawValue)") }
        if let v = p.onError { parts.append("onError \(v.rawValue)") }
        if let v = p.maxDeliveries { parts.append("maxDeliveries \(v)") }
        if let v = p.hitRate { parts.append("hitRate \(percent(v))") }
        return parts
    }

    static func state(_ entry: StateEntry) -> String {
        guard let value = entry.value else { return "\(entry.key) deleted" }
        return "\(entry.key)=\(clip(value, 80))" + (entry.ttl.map { " ttl \(duration($0))" } ?? "")
    }

    static func command(_ command: Command) -> String {
        switch command {
        case .kill(let n): "kill \(n)"
        case .restore(let n): "restore \(n)"
        case .slow(let n, let f): "slow \(n) \(number(f))"
        case .fail(let n, let p): "fail \(n) \(percent(p))"
        case .scale(let n, let k, let relative): "scale \(n) \(relative && k >= 0 ? "+" : "")\(k)"
        case .set(let binding, let value): "set \(binding) \(value)"
        case .rate(let flow, let r): "rate \(flow) \(rate(r))"
        case .send(let flow, let n): "send \(flow) \(n)"
        case .cut(let a, let b): "cut \(a) \(b)"
        case .heal(let a, let b): "heal \(a) \(b)"
        case .delay(let a, let b, let d): "delay \(a) \(b) \(duration(d))"
        case .redirect(let a, let b): "redirect \(a) \(b)"
        case .unredirect(let n): "unredirect \(n)"
        case .purge(let n): "purge \(n)"
        case .say(let text): "say \(clip(text, 120))"
        case .pause: "pause"
        }
    }

    static func condition(_ condition: Condition) -> String {
        switch condition {
        case .lt(let v): "< \(number(v))"
        case .le(let v): "<= \(number(v))"
        case .gt(let v): "> \(number(v))"
        case .ge(let v): ">= \(number(v))"
        case .eq(let v): "== \(v)"
        case .between(let a, let b): "\(number(a))..\(number(b))"
        case .always: "otherwise"
        }
    }

    static func rate(_ rate: Rate) -> String {
        switch rate {
        case .perSecond(let r): "\(number(r))/s"
        case .every(let s): "every \(duration(s))"
        case .manual: "manual"
        case .parent: "parent rate"
        }
    }

    static func dist(_ dist: Dist) -> String {
        switch dist {
        case .jitter(let m): duration(m)
        case .fixed(let m): "fixed \(duration(m))"
        case .uniform(let a, let b): "\(duration(a))..\(duration(b))"
        case .exponential(let m): "exp \(duration(m))"
        case .lognormal(let p50, let p99): "p50 \(duration(p50)) p99 \(duration(p99))"
        }
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "∞" }
        if seconds == 0 { return "0s" }
        if seconds < 0.001 { return number(seconds * 1_000_000) + "us" }
        if seconds < 1 { return number(seconds * 1000) + "ms" }
        if seconds < 120 { return number(seconds) + "s" }
        if seconds < 7200 { return number(seconds / 60) + "m" }
        return number(seconds / 3600) + "h"
    }

    static func percent(_ fraction: Double) -> String { number(fraction * 100) + "%" }

    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "∞" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        var text = String(format: "%.3f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    static func count(_ value: Double) -> String {
        switch value {
        case 1e9...: number((value / 1e8).rounded() / 10) + "B"
        case 1e6...: number((value / 1e5).rounded() / 10) + "M"
        case 1e3...: number((value / 1e2).rounded() / 10) + "k"
        default: number(value.rounded())
        }
    }
}
