import Foundation

// Validation of top-level `enums:` and column `enum:` links (docs/manifest.md, Enums). Runs after the
// levels are validated, because a transition's `by` and a column's enum can live on any level.
enum EnumValidation {
    static func check(_ manifest: Manifest, at root: Field) {
        var seen: [String: Int] = [:]
        for (def, location) in zip(manifest.enums, root["enums"].items(named: true)) {
            if let first = seen[def.id] {
                location["id"].diagnose("duplicate enum '\(def.id)' (first defined on line \(first))")
            } else {
                seen[def.id] = location["id"].line
            }
            enumDef(def, in: manifest, at: location)
        }
        columns(manifest.root, path: [], in: manifest, at: root)
    }

    private static func enumDef(_ def: EnumDef, in manifest: Manifest, at field: Field) {
        var codes: [String: Int] = [:]
        var names: [String: Int] = [:]
        let locations = field["values"].items()
        for (value, location) in zip(def.values, locations) {
            if let first = codes[value.value] {
                location["value"].diagnose("duplicate value \(value.value) in '\(def.id)' (first defined on line \(first))")
            } else {
                codes[value.value] = location["value"].line
            }
            if let first = names[value.name] {
                location["name"].diagnose("duplicate name '\(value.name)' in '\(def.id)' (first used on line \(first))", .warning)
            } else {
                names[value.name] = location["name"].line
            }
        }
        let known = def.values.map(\.value)
        for (transition, location) in zip(def.transitions, field["transitions"].items()) {
            for (end, key) in [(transition.from, "from"), (transition.to, "to")] where def.value(end) == nil {
                let byName = def.value(named: end).map { "; '\(end)' is the name of \($0.value), write the value" } ?? ""
                let fix = byName.isEmpty ? closestKey(to: end, in: known).map { "; did you mean \($0)?" } ?? "" : byName
                location[key].diagnose("unknown value \(end) in '\(def.id)'\(fix)")
            }
            if let from = def.value(transition.from), from.terminal {
                location["from"].diagnose("\(def.title(from)) is terminal but has a transition to \(def.title(of: transition.to)); drop terminal or the transition", .warning)
            }
            if let by = transition.by { actor(by, in: manifest, at: location["by"]) }
        }
    }

    /// `node` or `node/op` on any level of the manifest.
    private static func actor(_ by: String, in manifest: Manifest, at field: Field) {
        guard manifest.resolveActor(by) == nil else { return }
        let parts = by.split(separator: "/", maxSplits: 1).map(String.init)
        let levels = manifest.everyLevel()
        let nodes = levels.flatMap { $0.level.nodes }
        guard let node = nodes.first(where: { $0.id == parts[0] }) else {
            let fix = closestKey(to: parts[0], in: nodes.map(\.id)).map { "; did you mean '\($0)'?" } ?? ""
            field.diagnose("unknown node '\(parts[0])' in by '\(by)'\(fix)")
            return
        }
        let ops = levels.flatMap { $0.level.nodes.filter { $0.id == node.id }.flatMap(\.ops) }.map(\.id)
        let fix = closestKey(to: parts[1], in: ops).map { "; did you mean '\(node.id)/\($0)'?" } ?? ""
        field.diagnose("unknown op '\(parts[1])' on '\(node.id)' in by '\(by)'\(fix)")
    }

    /// Each column's `enum` exists, and its sample values are values of that enum.
    private static func columns(_ level: Level, path: [String], in manifest: Manifest, at field: Field) {
        let ids = manifest.enums.map(\.id)
        for (node, nodeField) in zip(level.nodes, field["nodes"].items(named: true)) {
            for (table, tableField) in zip(node.schema, nodeField["schema"].items(named: true, nameKey: "table")) {
                for (index, (column, columnField)) in zip(table.columns, tableField["columns"].items(named: true, nameKey: "name")).enumerated() {
                    guard let id = column.enumRef else { continue }
                    guard let def = manifest.enumDef(id) else {
                        let fix = closestKey(to: id, in: ids).map { "; did you mean '\($0)'?" } ?? (ids.isEmpty ? "; define it under enums" : "")
                        columnField["enum"].diagnose("unknown enum '\(id)'\(fix)")
                        continue
                    }
                    var unknown: [String] = []
                    var firstRow: Int?
                    for (row, values) in table.rows.enumerated() {
                        guard values.indices.contains(index), let value = values[index], def.value(value) == nil else { continue }
                        if !unknown.contains(value) { unknown.append(value) }
                        if firstRow == nil { firstRow = row }
                    }
                    if let firstRow, !unknown.isEmpty {
                        let rows = tableField["rows"].items()
                        let location = rows.indices.contains(firstRow) ? rows[firstRow] : tableField["rows"]
                        let list = unknown.map { "'\($0)'" }.joined(separator: ", ")
                        location.diagnose("\(table.name).\(column.name) holds \(list), not \(unknown.count == 1 ? "a value" : "values") of '\(id)'", .warning)
                    }
                }
            }
            if let inside = node.inside { columns(inside, path: path + [node.id], in: manifest, at: nodeField["inside"]) }
            for (op, opField) in zip(node.ops, nodeField["ops"].items(named: true)) {
                if let inside = op.inside { columns(inside, path: path + ["\(node.id)#\(op.id)"], in: manifest, at: opField["inside"]) }
            }
        }
    }
}
