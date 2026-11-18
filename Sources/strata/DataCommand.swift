import Foundation
import StrataCore

// `strata data <file|id> [--json]`: every table per data node, with its columns, keys and sample rows,
// then each entity assembled from its first root row, so an agent can check what it extracted.

struct DataReport: Encodable {
    var schemas: [SchemaListing] = []
    var entities: [EntityListing] = []
}

/// The tables of one data node. `level` is "" for the root, node ids joined by "/" for deep dives,
/// and `node#op` for an op's own `inside:` level.
struct SchemaListing: Encodable {
    let level: String
    let node: String
    let label: String
    let kind: String
    let tech: String?
    let tables: [TableListing]
}

struct TableListing: Encodable {
    struct ColumnListing: Encodable {
        let name: String
        let type: String?
        let pk: Bool
        let ref: String?
        let nullable: Bool?
        let unique: Bool
        let note: String?
    }
    struct Volume: Encodable { let rows: Double?; let growthPerDay: Double? }
    struct Join: Encodable { let direction: String; let column: String; let other: String; let node: String; let table: String; let otherColumn: String }
    /// A sample value in a ref column that no sample row of the referenced table has.
    struct Unmatched: Encodable { let column: String; let value: String; let ref: String }

    let name: String
    let doc: String?
    let columns: [ColumnListing]
    let indexes: [String]
    let rows: [[String?]]
    let volume: Volume?
    /// The declared owner, or the nodes whose ops write the table.
    let owners: [String]
    let ownerDeclared: Bool
    let joins: [Join]
    let unmatched: [Unmatched]
    let line: Int?

    init(_ table: TableSchema, on node: String, level: Level) {
        name = table.name; doc = table.doc; indexes = table.indexes; rows = table.rows; line = table.line
        columns = table.columns.map {
            ColumnListing(name: $0.name, type: $0.type, pk: $0.pk, ref: $0.ref, nullable: $0.nullable, unique: $0.unique, note: $0.note)
        }
        volume = table.volume.map { Volume(rows: $0.rows, growthPerDay: $0.growthPerDay) }
        let ref = TableRef(node: node, table: table.name)
        owners = level.owners(of: ref)
        ownerDeclared = table.owner != nil
        let joins = level.joins(of: ref)
        self.joins = joins.map {
            Join(direction: $0.direction.rawValue, column: $0.column, other: $0.other.description,
                 node: $0.other.node, table: $0.other.table, otherColumn: $0.other.column)
        }
        var unmatched: [Unmatched] = []
        for join in joins where join.direction == .outgoing {
            guard let target = level.table(join.other.tableRef), !target.rows.isEmpty,
                  let index = table.columnIndex(join.column), let targetIndex = target.columnIndex(join.other.column) else { continue }
            let known = Set(target.rows.indices.compactMap { target.value(row: $0, column: targetIndex) })
            var reported: Set<String> = []
            for row in table.rows.indices {
                guard let value = table.value(row: row, column: index), !known.contains(value), reported.insert(value).inserted else { continue }
                unmatched.append(Unmatched(column: join.column, value: value, ref: join.other.description))
            }
        }
        self.unmatched = unmatched
    }
}

struct EntityListing: Encodable {
    struct Join: Encodable {
        let table: String
        let above: String
        let relation: String
        let column: String
        let aboveColumn: String
    }
    struct Row: Encodable {
        let table: String
        let row: Int
        let relation: String
        let column: String?
        let aboveColumn: String?
        let columns: [String]
        let values: [String?]
        let children: [Row]
        let omitted: [String: Int]
        let truncated: Bool
    }

    let level: String
    let node: String
    let name: String
    let source: String?
    let root: String
    let includes: [String]
    let doc: String?
    let code: [String]
    let joins: [Join]
    /// The entity assembled from the root table's first sample row.
    let tree: Row?
    let line: Int?
}

@MainActor
func listData(_ args: Arguments) throws -> Int32 {
    let entry = try loadEntry(args.positional[0], command: "data")
    guard let manifest = entry.manifest else { return 1 }
    var report = DataReport()
    collectData(manifest.root, path: "", into: &report)
    if args.flags.contains("--json") {
        try printJSON(report)
    } else {
        print(renderData(report, manifest: manifest))
    }
    return 0
}

private func collectData(_ level: Level, path: String, into report: inout DataReport) {
    for node in level.nodes where !node.schema.isEmpty {
        report.schemas.append(SchemaListing(level: path, node: node.id, label: node.label, kind: node.kind.rawValue, tech: node.tech,
                                            tables: node.schema.map { TableListing($0, on: node.id, level: level) }))
    }
    for node in level.nodes {
        for entity in node.entities {
            let source = level.entitySource(entity, on: node.id)
            let tree = level.assembleEntity(entity, on: node.id)
            report.entities.append(EntityListing(
                level: path, node: node.id, name: entity.name, source: source, root: entity.root, includes: entity.includes,
                doc: entity.doc, code: entity.code,
                joins: level.entityJoins(entity, on: node.id).map {
                    EntityListing.Join(table: $0.table, above: $0.above, relation: $0.relation.rawValue, column: $0.column, aboveColumn: $0.aboveColumn)
                },
                tree: tree.map { rowListing($0, level: level, source: source ?? "") }, line: entity.line))
        }
    }
    for node in level.nodes {
        let nodePath = path.isEmpty ? node.id : "\(path)/\(node.id)"
        if let inside = node.inside { collectData(inside, path: nodePath, into: &report) }
        for op in node.ops {
            if let inside = op.inside { collectData(inside, path: "\(nodePath)#\(op.id)", into: &report) }
        }
    }
}

private func rowListing(_ row: EntityRow, level: Level, source: String) -> EntityListing.Row {
    EntityListing.Row(table: row.table, row: row.row, relation: row.relation.rawValue, column: row.column, aboveColumn: row.aboveColumn,
                      columns: level.table(source, row.table)?.columns.map(\.name) ?? [], values: row.values,
                      children: row.children.map { rowListing($0, level: level, source: source) },
                      omitted: row.omitted, truncated: row.truncated)
}

private func renderData(_ report: DataReport, manifest: Manifest) -> String {
    guard !report.schemas.isEmpty || !report.entities.isEmpty else { return "No schemas or entities in \(manifest.id)." }
    func title(_ level: String) -> String { level.isEmpty ? "\(manifest.id) (root)" : "\(manifest.id) › \(level)" }
    var sections: [String] = []
    for schema in report.schemas {
        let facts = [schema.label == schema.node ? nil : schema.label, schema.kind, schema.tech].compactMap { $0 }
        let heading = "\(title(schema.level)) › \(schema.node)  " + facts.joined(separator: " · ")
        sections.append(([heading] + schema.tables.map { renderTable($0, on: schema.node) }).joined(separator: "\n\n"))
    }
    var levels: [String] = []
    for entity in report.entities where !levels.contains(entity.level) { levels.append(entity.level) }
    for level in levels {
        let entities = report.entities.filter { $0.level == level }
        sections.append((["\(title(level)) entities"] + entities.map(renderEntity)).joined(separator: "\n\n"))
    }
    let tables = report.schemas.reduce(0) { $0 + $1.tables.count }
    func count(_ n: Int, _ noun: String, _ plural: String? = nil) -> String { "\(n) " + (n == 1 ? noun : plural ?? noun + "s") }
    sections.append("\(count(tables, "table")) on \(count(report.schemas.count, "node")), \(count(report.entities.count, "entity", "entities"))")
    return sections.joined(separator: "\n\n")
}

private func renderTable(_ table: TableListing, on node: String) -> String {
    var facts: [String] = []
    if let rows = table.volume?.rows { facts.append("\(DataFormat.count(rows)) rows") }
    if let growth = table.volume?.growthPerDay { facts.append("+\(DataFormat.count(growth))/day") }
    if !table.owners.isEmpty {
        facts.append((table.ownerDeclared ? "owner " : "written by ") + table.owners.joined(separator: ", "))
    }
    var lines = ["  " + ([table.name] + facts).joined(separator: " · ")]
    if let doc = table.doc { lines.append("  " + doc.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)) }
    if table.columns.isEmpty {
        lines.append("    (no columns)")
    } else {
        let header = table.columns.map { column in
            column.name + (column.pk ? " PK" : "") + (column.ref.map { " → \($0)" } ?? "")
        }
        let types = table.columns.map { column in
            var parts = [column.type ?? "–"]
            if column.unique { parts.append("unique") }
            if column.nullable == true { parts.append("null") }
            if column.nullable == false { parts.append("not null") }
            return parts.joined(separator: " ")
        }
        let rows = table.rows.map { row in row.map { cell in cell.map { clipped($0, 40) } ?? "NULL" } }
        lines.append(alignedTable([header, types] + rows).components(separatedBy: "\n").map { "    " + $0 }.joined(separator: "\n"))
        if table.rows.isEmpty { lines.append("    (no sample rows)") }
    }
    if !table.indexes.isEmpty { lines.append("    indexes: " + table.indexes.joined(separator: ", ")) }
    let notes = table.columns.compactMap { column in column.note.map { "\(column.name): \($0)" } }
    if !notes.isEmpty { lines.append("    notes: " + notes.joined(separator: "; ")) }
    let incoming = table.joins.filter { $0.direction == "incoming" }
        .map { $0.node == node ? "\($0.table).\($0.otherColumn)" : $0.other }
    if !incoming.isEmpty { lines.append("    referenced by: " + incoming.joined(separator: ", ")) }
    for miss in table.unmatched {
        lines.append("    unmatched: \(miss.column) '\(miss.value)' has no row in \(miss.ref)")
    }
    return lines.joined(separator: "\n")
}

private func renderEntity(_ entity: EntityListing) -> String {
    let tables = entity.includes.isEmpty ? entity.root : "\(entity.root) + \(entity.includes.joined(separator: ", "))"
    var lines = ["  \(entity.name) on \(entity.node) · from \(entity.source ?? "?") · \(tables)"]
    if let doc = entity.doc { lines.append("  " + doc.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)) }
    guard let tree = entity.tree else {
        lines.append("    (no sample rows in \(entity.root))")
        return lines.joined(separator: "\n")
    }
    func walk(_ row: EntityListing.Row, above: String?, depth: Int) {
        let indent = String(repeating: "  ", count: depth + 2)
        var line = indent
        switch row.relation {
        case "child": line += "↳ "
        case "parent": line += "↑ "
        default: break
        }
        line += "\(row.table) #\(row.row)"
        if let column = row.column, let aboveColumn = row.aboveColumn, let above {
            let mine = "\(row.table).\(column)", theirs = "\(above).\(aboveColumn)"
            line += row.relation == "child" ? "  via \(mine) → \(theirs)" : "  via \(theirs) → \(mine)"
        }
        let fields = zip(row.columns, row.values).map { "\($0)=\($1.map { clipped($0, 28) } ?? "NULL")" }
        line += "  " + fields.joined(separator: " ")
        lines.append(line)
        for child in row.children { walk(child, above: row.table, depth: depth + 1) }
        for (table, count) in row.omitted.sorted(by: { $0.key < $1.key }) {
            lines.append(indent + "  … \(count) more \(table) row\(count == 1 ? "" : "s")")
        }
        if row.truncated { lines.append(indent + "  … deeper rows not shown") }
    }
    walk(tree, above: nil, depth: 0)
    return lines.joined(separator: "\n")
}

private func clipped(_ text: String, _ limit: Int) -> String {
    let flat = text.replacingOccurrences(of: "\n", with: " ")
    return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
}
