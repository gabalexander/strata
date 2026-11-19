import Foundation

// `strata journey draft`: a skeleton journey written from what the map already knows (docs/manifest.md,
// Journeys). It follows the flows that perform the entity's status transitions, from the flow that
// moves it out of its current status (or the one that inserts it, for a new id) on through the queues
// those flows publish to, keeping the steps whose op touches the entity's tables or makes one of its
// transitions; then it walks the rest of the lifecycle by the transitions' `by:` ops. Statuses follow
// the transitions in a valid order, inserts of related rows get fresh ids, and binds are left to fill.

public struct JourneyDraftError: Error, Sendable, CustomStringConvertible {
    public var message: String
    public var description: String { message }
    init(_ message: String) { self.message = message }
}

public struct JourneyDraft: Sendable {
    public struct Step: Sendable {
        public var id: String
        public var label: String
        public var node: String
        public var path: [String]
        public var op: String?
        public var at: String
        public var status: [JourneyStatus] = []
        public var rows: [JourneyRowChange] = []
        public var binds: [JourneyBind] = []
        /// Lines written as comments under the step: placeholders to fill, other transitions.
        public var comments: [String] = []
        /// The flow the step comes from; nil for a step from the lifecycle walk.
        public var flow: String?
    }

    public var id: String
    public var title: String
    public var brief: String
    public var table: String
    public var entityID: String
    public var entityLabel: String
    /// A new row the draft inserts, rather than a sample row it starts from.
    public var inserted: Bool
    public var related: [(table: String, id: String, label: String)]
    public var steps: [Step]
    public var notes: [String]

    /// The draft as YAML, ready to go under `journeys:`.
    public var yaml: String {
        var lines = notes.map { "# " + $0 }
        lines.append("journeys:")
        lines.append("  - id: \(id)")
        lines.append("    title: \(Self.scalar(title))")
        lines.append("    brief: \(Self.scalar(brief))")
        lines.append("    entity: { table: \(table), id: \(Self.flowScalar(entityID)), label: \(Self.flowScalar(entityLabel)) }")
        if !related.isEmpty {
            lines.append("    related:")
            for item in related {
                lines.append("      - { table: \(item.table), id: \(Self.flowScalar(item.id)), label: \(Self.flowScalar(item.label)) }")
            }
        }
        lines.append("    steps:")
        for step in steps {
            lines.append("      - id: \(step.id)")
            lines.append("        at: \(Self.scalar(step.at))")
            lines.append("        label: \(Self.scalar(step.label))")
            if !step.path.isEmpty { lines.append("        path: [\(step.path.joined(separator: ", "))]") }
            if step.op == nil || step.path.isEmpty == false { lines.append("        node: \(step.node)") }
            if let op = step.op { lines.append("        op: \(op)") }
            if !step.binds.isEmpty {
                let pairs = step.binds.map { "\($0.name ?? "?"): \(Self.flowScalar($0.value ?? "null"))" }
                lines.append("        binds: { \(pairs.joined(separator: ", ")) }")
            }
            if !step.rows.isEmpty {
                lines.append("        rows:")
                for change in step.rows {
                    let values = change.values.map { "\($0.column): \(Self.flowScalar($0.value ?? "null"))" }.joined(separator: ", ")
                    lines.append("          - \(change.kind.rawValue): \(change.table)")
                    if let key = change.key?.id { lines.append("            id: \(Self.flowScalar(key))") }
                    if !values.isEmpty { lines.append("            \(change.kind == .insert ? "values" : "set"): { \(values) }") }
                }
            }
            if step.status.count == 1, let status = step.status.first {
                lines.append("        status: \(Self.status(status))")
            } else if !step.status.isEmpty {
                lines.append("        status:")
                for status in step.status { lines.append("          - \(Self.status(status))") }
            }
            for comment in step.comments { lines.append("        # " + comment) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func status(_ status: JourneyStatus) -> String {
        let from = status.from.map { "from: \(flowScalar($0)), " } ?? ""
        return "{ enum: \(status.enumID), \(from)to: \(flowScalar(status.to)) }"
    }

    /// A block scalar value: plain when safe, else double-quoted.
    static func scalar(_ text: String) -> String {
        let plain = text.range(of: #"^[A-Za-z0-9_(+][^:#{}\[\],&*!|>'"%@`]*$"#, options: .regularExpression) != nil
            && !text.hasSuffix(" ") && !["true", "false", "null", "yes", "no", "~"].contains(text.lowercased())
            && Syntax.number(text) == nil
        return plain ? text : json(text)
    }

    /// A value inside `{ }`: plain when it has no flow punctuation.
    static func flowScalar(_ text: String) -> String {
        if text == "null" { return text }
        let plain = text.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.\-+/]*$"#, options: .regularExpression) != nil
            && !["true", "false", "yes", "no", "~"].contains(text.lowercased())
        return plain ? text : json(text)
    }

    private static func json(_ text: String) -> String {
        (try? String(decoding: JSONEncoder().encode(text), as: UTF8.self)) ?? "\"\(text)\""
    }
}

public extension Manifest {
    /// A skeleton journey following a row of `table` (`task`, or `pg.task`): the sample row `id`, a new
    /// row with that id when no sample has it, or the sample row furthest back in its lifecycle.
    func draftJourney(table name: String, id: String? = nil, journeyID: String? = nil) throws -> JourneyDraft {
        var drafter = try JourneyDrafter(manifest: self, table: name, id: id)
        return drafter.run(journeyID: journeyID)
    }
}

/// A row the draft tracks: its table, key, and the enum columns it holds.
private struct DraftRow {
    var site: JourneyTableSite
    var id: String
    var label: String
    var values: [String: String?]
}

private struct JourneyDrafter {
    let manifest: Manifest
    let site: JourneyTableSite
    var entity: DraftRow
    let isNew: Bool
    /// Tables whose rows point at the entity (`call.task_sid → task.task_sid`), with the column that points.
    var children: [(site: JourneyTableSite, column: String)] = []
    var related: [DraftRow] = []
    var steps: [JourneyDraft.Step] = []
    var usedOps: Set<String> = []
    var stepIDs: Set<String> = []
    var clock = 0.0
    var notes: [String] = []

    init(manifest: Manifest, table name: String, id: String?) throws {
        self.manifest = manifest
        guard let site = manifest.journeyTables(name).first else {
            let bare = name.split(separator: ".").last.map(String.init) ?? name
            let fix = closestKey(to: bare, in: manifest.journeyTableNames()).map { "; did you mean '\($0)'?" } ?? ""
            let known = manifest.journeyTableNames()
            throw JourneyDraftError("unknown table '\(name)' in \(manifest.id)\(fix)" + (known.isEmpty ? "; it has no schema: tables" : ""))
        }
        self.site = site
        let schema = site.schema
        let keys = JourneyDrafter.keyColumns(schema)
        guard let first = keys.first else { throw JourneyDraftError("'\(schema.name)' has no columns") }
        func row(_ index: Int) -> [String: String?] {
            Dictionary(schema.columns.enumerated().map { ($1.name, schema.value(row: index, column: $0)) }, uniquingKeysWith: { a, _ in a })
        }
        let firstColumn = schema.columnIndex(first)
        if let id {
            if let index = schema.rows.indices.first(where: { r in
                firstColumn.map { schema.value(row: r, column: $0) == id } ?? false
            }) {
                entity = DraftRow(site: site, id: id, label: schema.name, values: row(index))
                isNew = false
            } else {
                entity = DraftRow(site: site, id: id, label: schema.name, values: [first: id])
                isNew = true
            }
        } else {
            guard !schema.rows.isEmpty else {
                throw JourneyDraftError("'\(schema.name)' has no sample rows; pass --id to draft a new row, or add rows to its schema")
            }
            // The row furthest back in its lifecycle: the earliest layer of its first enum column, not terminal.
            var best = 0
            if let column = schema.columns.first(where: { $0.enumRef != nil }), let def = column.enumRef.flatMap(manifest.enumDef),
               let index = schema.columnIndex(column.name) {
                let lifecycle = def.lifecycle()
                func rank(_ r: Int) -> (Int, Int) {
                    guard let value = schema.value(row: r, column: index), let v = def.value(value) else { return (Int.max, r) }
                    return (v.terminal ? 1000 : lifecycle.layer[value] ?? 999, r)
                }
                best = schema.rows.indices.min { rank($0) < rank($1) } ?? 0
            }
            let values = row(best)
            entity = DraftRow(site: site, id: (values[first] ?? nil) ?? "", label: schema.name, values: values)
            isNew = false
        }
        children = JourneyDrafter.children(of: site, in: manifest)
        if !isNew {
            // Sample rows that point at it join in: their statuses move too.
            for child in children {
                guard let index = child.site.schema.columnIndex(child.column) else { continue }
                let keys = JourneyDrafter.keyColumns(child.site.schema)
                for r in child.site.schema.rows.indices where child.site.schema.value(row: r, column: index) == entity.id {
                    let values = Dictionary(child.site.schema.columns.enumerated().map { ($1.name, child.site.schema.value(row: r, column: $0)) },
                                            uniquingKeysWith: { a, _ in a })
                    guard child.site.schema.columns.contains(where: { $0.enumRef != nil }),
                          let key = keys.first.flatMap({ values[$0] ?? nil }), related.filter({ $0.site.schema.name == child.site.schema.name }).count < 2 else { continue }
                    related.append(DraftRow(site: child.site, id: key, label: child.site.schema.name, values: values))
                }
            }
        }
    }

    static func keyColumns(_ schema: TableSchema) -> [String] {
        let primary = schema.primaryKey.map(\.name)
        return primary.isEmpty ? schema.columns.prefix(1).map(\.name) : primary
    }

    /// Tables on the same node with a column whose `ref` points at the entity table's first key column.
    static func children(of site: JourneyTableSite, in manifest: Manifest) -> [(site: JourneyTableSite, column: String)] {
        guard let level = manifest.level(at: site.path), let node = level.node(site.node), let key = keyColumns(site.schema).first else { return [] }
        var found: [(site: JourneyTableSite, column: String)] = []
        for table in node.schema where table.name != site.schema.name {
            for column in table.columns {
                guard let ref = column.ref, let resolved = level.resolveRef(ref, from: node.id) else { continue }
                if resolved.node == site.node, resolved.table == site.schema.name, resolved.column == key {
                    found.append((JourneyTableSite(path: site.path, node: site.node, schema: table), column.name))
                    break
                }
            }
        }
        return found
    }

    var tables: Set<String> { Set([site.schema.name] + children.map(\.site.schema.name)) }

    /// Every enum the entity or its children hold, by column.
    var enumColumns: [(table: String, column: String, enumID: String)] {
        ([site] + children.map(\.site)).flatMap { site in
            site.schema.columns.compactMap { column in column.enumRef.map { (site.schema.name, column.name, $0) } }
        }
    }

    /// `node/op` refs that make one of the entity's transitions.
    var transitionOps: Set<String> {
        let ids = Set(enumColumns.map(\.enumID))
        return Set(manifest.enums.filter { ids.contains($0.id) }.flatMap { $0.transitions.compactMap(\.by) }.filter { $0.contains("/") })
    }

    func isCandidate(_ node: String, _ op: Operation) -> Bool {
        if transitionOps.contains("\(node)/\(op.id)") { return true }
        return (op.kind == .sql || op.kind == .search) && !Set(op.tables).isDisjoint(with: tables)
    }

    /// Tables an op's query inserts into.
    static func inserts(_ op: Operation) -> [String] {
        guard let query = op.query, let regex = try? NSRegularExpression(pattern: #"(?i)\binsert\s+into\s+"?([A-Za-z_][A-Za-z0-9_.]*)"?"#) else { return [] }
        return regex.matches(in: query, range: NSRange(query.startIndex..., in: query)).compactMap { match in
            Range(match.range(at: 1), in: query).map { String(query[$0]).split(separator: ".").last.map(String.init) ?? "" }
        }
    }

    // MARK: Flows

    /// One thing a flow does, as a tree: a call with what runs at the callee, a publish, a consume.
    struct Event {
        enum Kind { case origin, consume, call, publish }
        var kind: Kind
        var flow: String
        var caller: String
        var target: String?
        var op: (node: String, op: Operation)?
        var label: String?
        var p: Double
        var children: [Event] = []
    }

    func events(of flow: Flow, in level: Level) -> [Event] {
        var result: [Event] = []
        if let by = flow.by, let ref = flow.op, let resolved = level.resolveOp(ref, caller: by, target: nil) {
            result.append(Event(kind: .consume, flow: flow.id, caller: by, target: flow.on, op: resolved, label: flow.label, p: 1))
        } else if let from = flow.from, let ref = flow.op, let resolved = level.resolveOp(ref, caller: from, target: nil) {
            result.append(Event(kind: .origin, flow: flow.id, caller: from, target: nil, op: resolved, label: flow.label, p: 1))
        }
        func walk(_ steps: [Step], caller: String) -> [Event] {
            steps.flatMap { step -> [Event] in
                let op = step.op.flatMap { ref in
                    switch step.action {
                    case .call(let target, _, _), .publish(let target): level.resolveOp(ref, caller: caller, target: target)
                    default: level.resolveOp(ref, caller: caller, target: nil)
                    }
                }
                switch step.action {
                case .call(let target, let inner, let miss):
                    var event = Event(kind: .call, flow: flow.id, caller: caller, target: target, op: op, label: step.label, p: step.p ?? 1)
                    event.children = walk(inner, caller: target)
                    return [event] + walk(miss, caller: caller).map { var e = $0; e.p *= 0.1; return e }
                case .publish(let target):
                    return [Event(kind: .publish, flow: flow.id, caller: caller, target: target, op: op, label: step.label, p: step.p ?? 1)]
                case .parallel(let branches): return walk(branches, caller: caller)
                case .work: return []
                }
            }
        }
        if let origin = flow.from ?? flow.by { result += walk(flow.steps, caller: origin) }
        return result
    }

    func contains(_ events: [Event], where match: (Event) -> Bool) -> Bool {
        events.contains { match($0) || contains($0.children, where: match) }
    }

    // MARK: Run

    mutating func run(journeyID: String?) -> JourneyDraft {
        let level = manifest.root
        let initialValues = entity.values
        let flows = level.flows.map { (flow: $0, events: events(of: $0, in: level)) }
        let startValues = currentTransitions()
        // The flow to start from: the one that moves the entity out of its status, or inserts it when new.
        let start = flows.first { item in
            contains(item.events) { event in
                guard let op = event.op else { return false }
                if isNew { return JourneyDrafter.inserts(op.op).contains(site.schema.name) }
                return startValues.contains("\(op.node)/\(op.op.id)")
            }
        }
        var chain: [String] = []
        if let start {
            var queue = [start.flow.id]
            while !queue.isEmpty {
                let id = queue.removeFirst()
                guard !chain.contains(id), let item = flows.first(where: { $0.flow.id == id }) else { continue }
                chain.append(id)
                func buffers(_ events: [Event]) -> [String] {
                    events.flatMap { event -> [String] in
                        (event.kind == .publish && event.p >= 0.5 ? [event.target].compactMap { $0 } : []) + buffers(event.children)
                    }
                }
                for buffer in buffers(item.events) {
                    for consumer in flows where consumer.flow.on == buffer && !chain.contains(consumer.flow.id) { queue.append(consumer.flow.id) }
                }
            }
            for id in chain {
                guard let item = flows.first(where: { $0.flow.id == id }) else { continue }
                emit(item.events, flow: item.flow, top: true, startFlow: id == start.flow.id)
            }
        } else {
            notes.append("No flow moves \(site.schema.name) \(entity.id) out of its status\(isNew ? " or inserts it" : ""), so the steps follow its transitions' by: ops.")
        }
        lifecycle()
        let label = site.schema.name
        let firstEnum = enumColumns.first { $0.table == site.schema.name }
        var title = "A \(label) from start to end"
        if let firstEnum, let def = manifest.enumDef(firstEnum.enumID) {
            let startValue = isNew ? JourneyDrafter.startValue(def) : (initialValues[firstEnum.column] ?? nil)
            let endValue = steps.flatMap(\.status).last { $0.enumID == def.id }?.to
            if let startValue, let endValue, startValue != endValue {
                title = "A \(label) from \(def.value(startValue)?.name ?? startValue) to \(def.value(endValue)?.name ?? endValue)"
            }
        }
        let flowLabels = chain.compactMap { id in level.flow(id)?.label }
        var brief = "Follow \(label) \(entity.id) through its status changes."
        for count in stride(from: min(5, flowLabels.count), through: 1, by: -1) {
            let text = "Follow \(label) \(entity.id) through " + flowLabels.prefix(count).joined(separator: ", ").lowercased()
                + (count < flowLabels.count ? " and on." : ".")
            if text.count <= 150 { brief = text; break }
        }
        var header = ["Drafted by strata journey draft from \(manifest.id): \(site.node).\(site.schema.name) \(entity.id)"
                      + (isNew ? " (a new row)." : ".")]
        header.append("Check each step against the code: fill binds, add the rows each step changes, add the steps the map")
        header.append("doesn't model and drop the ones that aren't this story, then strata validate.")
        return JourneyDraft(id: journeyID ?? "\(label)-\(entity.id)".lowercased().replacingOccurrences(of: #"[^a-z0-9_-]+"#, with: "-", options: .regularExpression),
                            title: title, brief: brief, table: manifest.journeyTables(site.schema.name).count > 1 ? "\(site.node).\(site.schema.name)" : site.schema.name,
                            entityID: entity.id, entityLabel: label, inserted: isNew,
                            related: related.map { ($0.site.schema.name, $0.id, $0.label) }, steps: steps, notes: header + notes)
    }

    /// `node/op` refs of the transitions out of the entity's current statuses.
    func currentTransitions() -> Set<String> {
        var refs: Set<String> = []
        for (table, column, enumID) in enumColumns where table == site.schema.name {
            guard let def = manifest.enumDef(enumID), let value = entity.values[column] ?? nil else { continue }
            for transition in def.transitions(from: value) { if let by = transition.by, by.contains("/") { refs.insert(by) } }
        }
        return refs
    }

    /// Emits the events worth a step: candidates, calls whose subtree holds one, and publishes or consumes
    /// on the chain.
    mutating func emit(_ events: [Event], flow: Flow, top: Bool, startFlow: Bool) {
        for event in events {
            let subtree = contains(event.children) { child in child.op.map { isCandidate($0.node, $0.op) } ?? false }
            let candidate = event.op.map { isCandidate($0.node, $0.op) } ?? false
            var keep = false
            switch event.kind {
            case .origin: keep = startFlow
            case .consume: keep = true
            case .call: keep = candidate || (subtree && event.p >= 0.5 && event.op != nil)
            case .publish: keep = candidate || event.p >= 0.5
            }
            if keep { step(for: event, flow: flow) }
            if event.p >= 0.5 || subtree { emit(event.children, flow: flow, top: false, startFlow: startFlow) }
        }
    }

    mutating func step(for event: Event, flow: Flow) {
        var node = event.caller
        var reference: String?
        if let op = event.op {
            // An endpoint or consumer happens where it is served; an outbound op where it is called from.
            node = op.op.direction == .inbound || op.node == event.target ? op.node : event.caller
            reference = "\(op.node)/\(op.op.id)"
            if let reference, usedOps.contains(reference), event.kind != .consume { return }
            if let reference { usedOps.insert(reference) }
        } else if event.kind == .publish, let target = event.target {
            // A publish without an op still carries the entity on: name the producer and the queue.
            var draft = JourneyDraft.Step(id: uniqueID("publish-\(target)"), label: event.label ?? "publish to \(target)", node: node, path: [],
                                          op: nil, at: advance(node: node))
            draft.flow = flow.id
            draft.comments.append("message: { to: \(target), payload: … } with this \(site.schema.name)'s values")
            steps.append(draft)
            return
        } else {
            return
        }
        let label = event.label ?? event.op?.op.label ?? reference ?? node
        var draft = JourneyDraft.Step(id: uniqueID(event.op?.op.id ?? node), label: label, node: node, path: [], op: reference,
                                      at: advance(node: event.kind == .call ? (event.target ?? node) : node))
        draft.flow = flow.id
        if let op = event.op { fill(&draft, node: op.node, op: op.op) }
        steps.append(draft)
    }

    /// Statuses, inserts and binds for a step running `op`.
    mutating func fill(_ draft: inout JourneyDraft.Step, node: String, op: Operation) {
        let reference = "\(node)/\(op.id)"
        for table in JourneyDrafter.inserts(op) {
            if table == site.schema.name {
                guard isNew, !(steps.contains { $0.rows.contains { $0.kind == .insert && $0.table == table } }) else { continue }
                var change = JourneyRowChange(kind: .insert, table: table)
                change.values = newValues(site.schema, key: entity.id, link: nil)
                for cell in change.values { entity.values[cell.column] = cell.value }
                draft.rows.append(change)
            } else if let child = children.first(where: { $0.site.schema.name == table }) {
                if let earlier = steps.first(where: { $0.rows.contains { $0.kind == .insert && $0.table == table } }) {
                    draft.comments.append("also inserts into \(table); the draft inserts its row at \(earlier.id), keep the step that really does")
                    continue
                }
                let id = nextID(child.site.schema)
                var change = JourneyRowChange(kind: .insert, table: table)
                change.values = newValues(child.site.schema, key: id, link: (child.column, entity.id))
                draft.rows.append(change)
                let values = Dictionary(change.values.map { ($0.column, $0.value) }, uniquingKeysWith: { a, _ in a })
                let key = JourneyDrafter.keyColumns(child.site.schema).first.flatMap { values[$0] ?? nil } ?? id
                related.append(DraftRow(site: child.site, id: key, label: table, values: values))
            }
        }
        // The transitions this op makes from where each row is now: to a terminal value first.
        for row in [entity] + related {
            for column in row.site.schema.columns {
                guard let enumID = column.enumRef, let def = manifest.enumDef(enumID), let current = row.values[column.name] ?? nil else { continue }
                let made = def.transitions(from: current).filter { $0.by == reference }
                guard let chosen = made.first(where: { def.value($0.to)?.terminal == true }) ?? made.first,
                      !draft.status.contains(where: { $0.enumID == enumID && $0.from == current && $0.to == chosen.to }) else { continue }
                draft.status.append(JourneyStatus(enumID: enumID, from: current, to: chosen.to))
                setValue(table: row.site.schema.name, id: row.id, column: column.name, to: chosen.to)
                let others = made.filter { $0.to != chosen.to }.map { def.title(of: $0.to) }
                if !others.isEmpty {
                    let listed = others.prefix(4).joined(separator: ", ") + (others.count > 4 ? " and \(others.count - 4) more" : "")
                    draft.comments.append("\(enumID): \(def.title(of: current)) can also move to \(listed) here")
                }
            }
        }
        // Named placeholders that match a column of the rows get their value; the rest are listed.
        var placeholders: [String] = []
        if let query = op.query { placeholders = JourneyFill.sqlPlaceholders(query).map(\.text) }
        if let key = op.key { placeholders += JourneyFill.bracePlaceholders(key).map(\.text) }
        if let path = op.path { placeholders += JourneyFill.bracePlaceholders(path).map(\.text) }
        var unique: [String] = []
        for text in placeholders where text == "?" || !unique.contains(text) { unique.append(text) }
        let rows = [entity] + related
        var named: [JourneyBind] = []
        for text in unique where text != "?" && !text.hasPrefix("$") {
            let name = text.trimmingCharacters(in: CharacterSet(charactersIn: "@:{}"))
                .replacingOccurrences(of: #"^sqlc\.(n?arg|slice)\('?|'?\)$"#, with: "", options: .regularExpression)
            if let value = rows.lazy.compactMap({ $0.values[name] ?? nil }).first { named.append(JourneyBind(name: name, value: value)) }
        }
        draft.binds = named
        let left = unique.filter { text in !named.contains { bind in text.contains(bind.name ?? "\u{0}") } }
        if !left.isEmpty {
            let questions = left.filter { $0 == "?" }.count
            let listed = questions == left.count ? "\(questions) positional ? placeholder\(questions == 1 ? "" : "s")" : left.joined(separator: ", ")
            draft.comments.append("binds: \(listed) to fill from the code")
        }
    }

    mutating func setValue(table: String, id: String, column: String, to value: String) {
        if table == site.schema.name, id == entity.id { entity.values[column] = value; return }
        if let k = related.firstIndex(where: { $0.site.schema.name == table && $0.id == id }) { related[k].values[column] = value }
    }

    /// A new row's values: its key, the column that points at the entity, each enum column at its start
    /// value, and the rest of a composite key from the first sample row.
    func newValues(_ schema: TableSchema, key: String, link: (column: String, value: String)?) -> [JourneyCell] {
        let keys = JourneyDrafter.keyColumns(schema)
        var cells: [JourneyCell] = []
        for column in schema.columns {
            var value: String?
            if column.name == link?.column { value = link?.value }
            else if column.name == keys.first { value = key }
            else if let id = column.enumRef, let def = manifest.enumDef(id) { value = JourneyDrafter.startValue(def) }
            else if keys.contains(column.name) { value = schema.columnIndex(column.name).flatMap { schema.value(row: 0, column: $0) } }
            if let value { cells.append(JourneyCell(column: column.name, value: value)) }
        }
        return cells
    }

    /// The value a new row enters with: the first one no transition moves into.
    static func startValue(_ def: EnumDef) -> String? {
        let entered = Set(def.transitions.map(\.to))
        return def.values.first { !entered.contains($0.value) }?.value ?? def.values.first?.value
    }

    /// A fresh key for a new row: one past the largest sample key's trailing number, keeping its prefix.
    func nextID(_ schema: TableSchema) -> String {
        guard let column = JourneyDrafter.keyColumns(schema).first, let index = schema.columnIndex(column) else { return "new" }
        let taken = schema.rows.indices.compactMap { schema.value(row: $0, column: index) }
            + related.filter { $0.site.schema.name == schema.name }.map(\.id)
        var best: (prefix: String, number: Int, width: Int)?
        for key in taken {
            guard let range = key.range(of: #"[0-9]+$"#, options: .regularExpression), let number = Int(key[range]) else { continue }
            if best == nil || number > best!.number { best = (String(key[..<range.lowerBound]), number, key[range].count) }
        }
        guard let best else { return "\(schema.name)-new" }
        let digits = String(best.number + 1)
        return best.prefix + String(repeating: "0", count: max(0, best.width - digits.count)) + digits
    }

    /// After the flows, the rest of the lifecycle: from where the entity is, the first declared transition
    /// made by an op (a value is never visited twice), until a terminal value or a move nobody makes.
    mutating func lifecycle() {
        for (table, column, enumID) in enumColumns where table == site.schema.name {
            guard let def = manifest.enumDef(enumID) else { continue }
            var visited: Set<String> = []
            while let current = entity.values[column] ?? nil, !visited.contains(current) {
                visited.insert(current)
                if def.value(current)?.terminal == true { break }
                let out = def.transitions(from: current).filter { !visited.contains($0.to) }
                guard let next = out.first else { break }
                guard let by = next.by, by.contains("/"), let actor = manifest.resolveActor(by), let opID = actor.op,
                      let node = manifest.level(at: actor.path)?.node(actor.node), let op = node.ops.first(where: { $0.id == opID }) else {
                    let who = next.by.map { " (by \($0))" } ?? ""
                    if var last = steps.last {
                        last.comments.append("then \(def.title(of: current)) → \(def.title(of: next.to))\(who): no op makes it, add that step by hand")
                        steps[steps.count - 1] = last
                    } else {
                        notes.append("\(def.title(of: current)) → \(def.title(of: next.to))\(who): no op makes it; add that step by hand.")
                    }
                    break
                }
                guard !usedOps.contains(by) else { break }
                usedOps.insert(by)
                var draft = JourneyDraft.Step(id: uniqueID(op.id), label: next.label ?? op.label, node: node.id, path: actor.path, op: by,
                                              at: advance(node: op.target ?? node.id))
                fill(&draft, node: node.id, op: op)
                if !draft.status.contains(where: { $0.enumID == enumID }) {
                    draft.status.insert(JourneyStatus(enumID: enumID, from: current, to: next.to), at: 0)
                    entity.values[column] = next.to
                }
                steps.append(draft)
            }
        }
    }

    mutating func uniqueID(_ base: String) -> String {
        var id = base, n = 2
        while stepIDs.contains(id) { id = "\(base)-\(n)"; n += 1 }
        stepIDs.insert(id)
        return id
    }

    /// The step's offset: the start, then the time the node it talks to takes, in whole milliseconds.
    mutating func advance(node: String) -> String {
        guard !steps.isEmpty else { return "0ms" }
        let latency = manifest.root.node(node).map { NodeConfiguration.effective($0).latency?.mean ?? 0.005 } ?? 0.005
        let ms = max(1, Int((latency * 1000).rounded()))
        clock += Double(ms)
        return "+\(ms)ms"
    }
}
