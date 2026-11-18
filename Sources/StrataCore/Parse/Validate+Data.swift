import Foundation

// Validation of node `schema:` and `entities:`, op `tables:` against a schema, and flow `traffic:`
// and `slo:` (docs/manifest.md, Data, and Traffic, SLOs and pressure).
extension LevelValidation {
    /// Checks a node's tables and entities. Returns its entities with each default `source` filled in.
    func data(of node: Node, at field: Field) -> [Entity] {
        schema(of: node, at: field["schema"])
        return entities(of: node, at: field["entities"])
    }

    private func schema(of node: Node, at field: Field) {
        guard !node.schema.isEmpty else { return }
        if !Level.dataKinds.contains(node.kind) {
            field.diagnose("schema describes the tables of a database, store or search node; '\(node.id)' is a \(node.kind.rawValue)", .warning)
        }
        var seen: [String: Int] = [:]
        for (table, location) in zip(node.schema, field.items(named: true, nameKey: "table")) {
            if let first = seen[table.name] {
                location["table"].diagnose("duplicate table '\(table.name)' (first defined on line \(first))")
            } else {
                seen[table.name] = location.line
            }
            self.table(table, on: node, at: location)
        }
    }

    private func table(_ table: TableSchema, on node: Node, at field: Field) {
        var seen: [String: Int] = [:]
        for (column, location) in zip(table.columns, field["columns"].items(named: true, nameKey: "name")) {
            if let first = seen[column.name] {
                location["name"].diagnose("duplicate column '\(column.name)' in '\(table.name)' (first defined on line \(first))")
            } else {
                seen[column.name] = location.line
            }
            if let ref = column.ref { self.ref(ref, from: node, at: location["ref"]) }
        }
        if let owner = table.owner, nodes[owner] == nil {
            field["owner"].diagnose("unknown node '\(owner)'\(suggestion(owner, among: nodes.keys))")
        }
        let keys = table.columns.indices.filter { table.columns[$0].pk }
        guard !keys.isEmpty else { return }
        var rows: [[String]: Int] = [:]
        for (index, location) in field["rows"].items().enumerated() where table.rows.indices.contains(index) {
            let key = keys.compactMap { table.value(row: index, column: $0) }
            guard key.count == keys.count else { continue }
            if let first = rows[key] {
                location.diagnose("duplicate primary key (\(key.joined(separator: ", "))) in '\(table.name)'; sample row \(first + 1) has it too", .warning)
            } else {
                rows[key] = index
            }
        }
    }

    /// `table.column` on the declaring node, or `node.table.column`.
    private func ref(_ ref: String, from node: Node, at field: Field) {
        let parts = ref.split(separator: ".").map(String.init)
        let owner: Node
        if parts.count == 3 {
            guard let other = nodes[parts[0]] else {
                field.diagnose("unknown node '\(parts[0])' in ref '\(ref)'\(suggestion(parts[0], among: nodes.keys))")
                return
            }
            owner = other
        } else {
            owner = node
        }
        let tableName = parts[parts.count - 2], columnName = parts[parts.count - 1]
        guard let table = owner.schema.first(where: { $0.name == tableName }) else {
            let names = owner.schema.map(\.name)
            var fix = closestKey(to: tableName, in: names).map { "; did you mean '\($0)'?" } ?? ""
            if fix.isEmpty, parts.count == 2, nodes[tableName] != nil {
                fix = "; to refer to node '\(tableName)', write \(tableName).\(columnName).<column>"
            } else if fix.isEmpty, names.isEmpty {
                fix = "; '\(owner.id)' has no schema"
            }
            field.diagnose("unknown table '\(tableName)' in '\(owner.id)'\(fix)")
            return
        }
        guard table.column(columnName) != nil else {
            let fix = closestKey(to: columnName, in: table.columns.map(\.name)).map { "; did you mean '\($0)'?" } ?? ""
            field.diagnose("unknown column '\(columnName)' in '\(owner.id == node.id ? tableName : "\(owner.id).\(tableName)")'\(fix)")
            return
        }
    }

    private func entities(of node: Node, at field: Field) -> [Entity] {
        var seen: [String: Int] = [:]
        var resolved: [Entity] = []
        for (entity, location) in zip(node.entities, field.items(named: true, nameKey: "name")) {
            if let first = seen[entity.name] {
                location["name"].diagnose("duplicate entity '\(entity.name)' (first defined on line \(first))")
            } else {
                seen[entity.name] = location.line
            }
            resolved.append(self.entity(entity, on: node, at: location))
        }
        return resolved
    }

    private func entity(_ entity: Entity, on node: Node, at field: Field) -> Entity {
        var entity = entity
        let source: Node
        if let id = entity.source {
            guard let found = nodes[id] else {
                field["source"].diagnose("unknown node '\(id)'\(suggestion(id, among: nodes.keys))")
                return entity
            }
            guard Level.dataKinds.contains(found.kind) else {
                field["source"].diagnose("an entity's source is a database, store or search node; '\(id)' is a \(found.kind.rawValue)")
                return entity
            }
            source = found
        } else {
            let candidates = level.entitySourceCandidates(on: node.id, root: entity.root)
            guard candidates.count == 1, let found = nodes[candidates[0]] else {
                if candidates.isEmpty {
                    field.diagnose("set source to the node this entity is loaded from; '\(node.id)' has no ops on a database, store or search node")
                } else {
                    let names = candidates.map { "'\($0)'" }.joined(separator: ", ")
                    field.diagnose("set source to the node this entity is loaded from; '\(node.id)' has ops on \(names)")
                }
                return entity
            }
            source = found
            entity.source = found.id
        }

        let names = source.schema.map(\.name)
        guard !names.isEmpty else {
            field[field["source"].present ? "source" : "root"]
                .diagnose("'\(source.id)' has no schema; describe its tables under schema so the entity can be assembled")
            return entity
        }
        func unknown(_ table: String, at location: Field) {
            let fix = closestKey(to: table, in: names).map { "; did you mean '\($0)'?" } ?? ""
            location.diagnose("unknown table '\(table)' in '\(source.id)'\(fix)")
        }
        let rootKnown = names.contains(entity.root)
        if !rootKnown { unknown(entity.root, at: field["root"]) }

        let list = field["includes"]
        let locations = list.node?.scalar != nil ? [list] : list.items()
        let reached = rootKnown ? Set(level.entityJoins(entity, on: node.id).map(\.table)) : []
        var listed: Set<String> = []
        for (include, location) in zip(entity.includes, locations) {
            guard names.contains(include) else { unknown(include, at: location); continue }
            if include == entity.root {
                location.diagnose("'\(include)' is the root table; includes lists the tables joined to it", .warning)
            } else if !listed.insert(include).inserted {
                location.diagnose("'\(include)' is listed twice", .warning)
            } else if rootKnown, !reached.contains(include) {
                location.diagnose("'\(include)' does not join '\(entity.root)' through ref columns; add a ref, or include the table that links them")
            }
        }
        return entity
    }

    /// A warning for each table an op names that its target's schema doesn't have.
    func opTables(_ op: Operation, in target: Node, at field: Field) {
        guard !target.schema.isEmpty, !op.tables.isEmpty else { return }
        let names = target.schema.map(\.name)
        let locations = field.node?.scalar != nil ? [field] : field.items()
        for (table, location) in zip(op.tables, locations) where !names.contains(table) {
            let fix = closestKey(to: table, in: names).map { "; did you mean '\($0)'?" } ?? ""
            location.diagnose("'\(target.id)' has no table '\(table)' in its schema\(fix)", .warning)
        }
    }

    /// Real-world numbers that contradict each other.
    func trafficSanity(_ flow: Flow, at field: Field) {
        if let traffic = flow.traffic, let peak = traffic.peak, let daily = traffic.daily, peak > 0 {
            let numbers = "daily \(DataFormat.count(daily)) against peak \(DataFormat.rate(peak))"
            if daily < peak * 60 {
                field["traffic"]["daily"].diagnose("\(numbers) is less than one minute of peak traffic; check the units", .warning)
            } else if daily > peak * 86400 {
                field["traffic"]["daily"].diagnose("\(numbers) is more than a whole day at the peak rate; peak is the busiest rate", .warning)
            }
        }
        if let slo = flow.slo {
            if let p50 = slo.p50, let p99 = slo.p99, p50 > p99 {
                field["slo"]["p50"].diagnose("p50 \(Self.duration(p50)) is above p99 \(Self.duration(p99))", .warning)
            }
            if let p99 = slo.p99, let deadline = flow.deadline, p99 > deadline {
                field["slo"]["p99"].diagnose("p99 \(Self.duration(p99)) is longer than the flow's deadline \(Self.duration(deadline)), so the client gives up first", .warning)
            }
        }
    }

    private static func duration(_ seconds: Double) -> String {
        seconds >= 1 ? Value.number((seconds * 1000).rounded() / 1000).description + "s"
                     : Value.number((seconds * 1_000_000).rounded() / 1000).description + "ms"
    }
}
