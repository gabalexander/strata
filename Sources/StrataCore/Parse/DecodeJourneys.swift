import Foundation

// Decoding of top-level `journeys:` (docs/manifest.md, Journeys). References (tables, columns, nodes,
// ops, enums) are checked afterwards by JourneyValidation, once every level is decoded.

extension Decode {
    static let manifestJourneyKeys: Set<String> = ["journeys"]
    static let journeyKeys: Set<String> = ["id", "title", "brief", "entity", "related", "steps"]
    static let journeyRowRefKeys: Set<String> = ["table", "id", "key", "label"]
    static let journeyStepKeys: Set<String> = ["id", "at", "label", "node", "path", "op", "binds", "rows", "status", "message", "note", "how"]
    static let journeyChangeKeys: Set<String> = ["insert", "update", "delete", "key", "id", "values", "set"]
    static let journeyStatusKeys: Set<String> = ["enum", "from", "to", "column"]
    static let journeyMessageKeys: Set<String> = ["to", "topic", "key", "payload"]

    static func journeys(_ field: Field) -> [Journey] {
        field.items(named: true).compactMap(journey)
    }

    static func journey(_ field: Field) -> Journey? {
        guard field.mapping(journeyKeys) else { return nil }
        let id = field["id"].id(required: true)
        let title = field["title"].text(required: true, nonempty: true)
        let entity = journeyRowRef(field["entity"], required: true)
        guard let id, let entity else { return nil }
        var journey = Journey(id: id, title: title ?? id, entity: entity)
        journey.line = field.line
        journey.brief = field["brief"].text(nonempty: true)
        if let brief = journey.brief, brief.contains("\n") || brief.count > 160 {
            field["brief"].diagnose("keep brief to one line (\(brief.count) characters); say the rest in the steps", .warning)
        }
        let related = field["related"]
        journey.related = (related.node?.fields != nil ? [related] : related.items()).compactMap { journeyRowRef($0) }
        let steps = field["steps"]
        journey.steps = steps.items(required: true, named: true).enumerated().compactMap { index, item in
            journeyStep(item, defaultID: "s\(index + 1)")
        }
        if steps.node?.elements?.isEmpty == true { steps.diagnose("a journey needs at least one step") }
        return journey
    }

    /// `{ table: task, id: 5000101, label: lead }`, or `{ table: task, key: { task_sid: …, create_time: … } }`.
    static func journeyRowRef(_ field: Field, required: Bool = false) -> JourneyRowRef? {
        guard field.present || required else { return nil }
        guard field.present else { field.diagnose("required value is missing; name the table and the sample id, such as { table: orders, id: o_9k2 }"); return nil }
        guard field.mapping(journeyRowRefKeys) else { return nil }
        guard let table = field["table"].scalar(required: true, Syntax.journeyTable) else { return nil }
        var ref = JourneyRowRef(table: table, key: journeyKey(field))
        ref.label = field["label"].text(nonempty: true)
        ref.line = field.line
        return ref
    }

    /// A row key: `id: 5000101` (the first key column), or `key:` with a map of columns. `id` may be a map too.
    static func journeyKey(_ field: Field) -> JourneyKey? {
        if field["id"].present, field["key"].present { field["key"].diagnose("use id or key, not both") }
        let source = field["key"].present ? field["key"] : field["id"]
        guard let node = source.node else { return nil }
        switch node.content {
        case .map(let pairs):
            var cells: [JourneyCell] = []
            for pair in pairs {
                guard Syntax.isName(pair.key) else { source[pair.key].diagnose("invalid column name '\(pair.key)'"); continue }
                cells.append(JourneyCell(column: pair.key, value: cell(pair.value)))
            }
            if cells.isEmpty { source.diagnose("expected the key's columns, such as { task_sid: 5000101 }") }
            return cells.isEmpty ? nil : JourneyKey(cells: cells)
        case .scalar(let text, _):
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { source.diagnose("expected a nonempty id"); return nil }
            return JourneyKey(id: text)
        case .list, .null:
            source.diagnose("expected an id such as 5000101, or a map of key columns")
            return nil
        }
    }

    static func journeyStep(_ field: Field, defaultID: String) -> JourneyStep? {
        guard field.mapping(journeyStepKeys) else { return nil }
        let id = field["id"].id() ?? defaultID
        let label = field["label"].text(required: true, nonempty: true)
        var step = JourneyStep(id: id, label: label ?? id)
        step.line = field.line
        step.at = field["at"].scalar { text in
            _ = try JourneyTime.parse(text)
            return text
        }
        step.node = field["node"].id()
        step.path = journeyPath(field["path"])
        step.op = field["op"].scalar { try Syntax.opReference($0, qualified: false, owner: true) }
        step.binds = journeyBinds(field["binds"])
        step.rows = field["rows"].items().compactMap(journeyChange)
        let status = field["status"]
        step.status = (status.node?.fields != nil ? [status] : status.items()).compactMap(journeyStatus)
        step.message = journeyMessage(field["message"])
        step.note = field["note"].text(nonempty: true)
        step.how = field["how"].scalar { text in
            let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, parts.allSatisfy(Syntax.isID) else {
                throw InvalidValue("invalid how reference '\(text)'; use node/mechanism, such as relay/relay-cycle")
            }
            return text
        }
        if !field["node"].present, !field["op"].present {
            field.diagnose("a step needs node (where it happens) or op (what it runs)")
        }
        return step
    }

    /// A deep-dive path: `[orders, relay]` or `orders/relay`; `node#op` enters an op's level.
    static func journeyPath(_ field: Field) -> [String] {
        guard field.present else { return [] }
        let parts: [Field] = field.node?.scalar != nil ? [field] : field.items()
        var path: [String] = []
        for part in parts {
            guard let text = part.scalar({ $0 }) else { continue }
            for element in text.split(separator: "/").map(String.init) {
                let pieces = element.split(separator: "#", omittingEmptySubsequences: false).map(String.init)
                guard (1...2).contains(pieces.count), pieces.allSatisfy(Syntax.isID) else {
                    part.diagnose("invalid path element '\(element)'; use node ids, or node#op for an op's level")
                    continue
                }
                path.append(element)
            }
        }
        return path
    }

    /// A list fills positional placeholders in order (`?`, `$1`); a map fills named ones (`@id`, `:id`,
    /// `sqlc.arg(id)`, `{sku}`, `$2`).
    static func journeyBinds(_ field: Field) -> [JourneyBind] {
        guard let node = field.node else { return [] }
        switch node.content {
        case .list(let items):
            return items.map { JourneyBind(value: cell($0), quoted: quoted($0)) }
        case .map(let pairs):
            return pairs.map { JourneyBind(name: $0.key, value: cell($0.value), quoted: quoted($0.value)) }
        case .scalar, .null:
            field.diagnose("expected a list of values for ?, $1, $2 … or a map from placeholder name to value")
            return []
        }
    }

    private static func quoted(_ node: YAMLNode) -> Bool {
        if case .scalar(_, true) = node.content { return true }
        return false
    }

    /// `- update: task` with `key` (or `id`) and `set`; `- insert: call` with `values`; `- delete: t` with `key`.
    static func journeyChange(_ field: Field) -> JourneyRowChange? {
        guard field.mapping(journeyChangeKeys) else { return nil }
        let verbs = JourneyRowKind.allCases.filter { field[$0.rawValue].present }
        guard verbs.count == 1, let kind = verbs.first else {
            field.diagnose("expected exactly one of insert, update or delete, naming the table")
            return nil
        }
        guard let table = field[kind.rawValue].scalar(required: true, Syntax.journeyTable) else { return nil }
        var change = JourneyRowChange(kind: kind, table: table)
        change.line = field.line
        if field["key"].present || field["id"].present {
            change.key = journeyKey(field)
            if kind == .insert { (field["key"].present ? field["key"] : field["id"]).diagnose("an insert takes its key from values; drop key", .warning) }
        } else if kind != .insert {
            field.diagnose("\(kind.rawValue) needs the row's key: id: <value of the first key column>, or key: { column: value }")
        }
        if field["values"].present, field["set"].present { field["set"].diagnose("use values or set, not both") }
        let values = field["values"].present ? field["values"] : field["set"]
        if let pairs = values.node?.fields {
            change.values = pairs.compactMap { pair in
                guard Syntax.isName(pair.key) else { values[pair.key].diagnose("invalid column name '\(pair.key)'"); return nil }
                return JourneyCell(column: pair.key, value: cell(pair.value))
            }
        } else if values.present {
            values.diagnose("expected a map from column to value")
        }
        switch kind {
        case .insert where change.values.isEmpty: field.diagnose("insert needs values: { column: value, … }")
        case .update where change.values.isEmpty: field.diagnose("update needs set: { column: new value, … }")
        case .delete where !change.values.isEmpty: values.diagnose("delete takes only the key", .warning)
        default: break
        }
        return change
    }

    static func journeyStatus(_ field: Field) -> JourneyStatus? {
        guard field.mapping(journeyStatusKeys) else { return nil }
        let id = field["enum"].id(required: true)
        let to = field["to"].enumScalar(required: true)
        guard let id, let to else { return nil }
        var status = JourneyStatus(enumID: id, from: field["from"].enumScalar(), to: to)
        status.column = field["column"].scalar { text in
            let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard (2...3).contains(parts.count), parts.allSatisfy(Syntax.isName) else {
                throw InvalidValue("invalid column '\(text)'; use table.column")
            }
            return text
        }
        status.line = field.line
        return status
    }

    static func journeyMessage(_ field: Field) -> JourneyMessage? {
        guard field.present, field.mapping(journeyMessageKeys) else { return nil }
        var message = JourneyMessage()
        message.line = field.line
        message.to = field["to"].id()
        message.topic = field["topic"].anyText()
        message.key = field["key"].anyText()
        message.payload = field["payload"].structuredText()
        return message
    }
}

extension Syntax {
    /// A table, or `node.table` for a table on a named node.
    static func journeyTable(_ text: String) throws -> String {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count), parts.allSatisfy(isName) else {
            throw InvalidValue("invalid table '\(text)'; use table, or node.table when several nodes have one")
        }
        return text
    }
}
