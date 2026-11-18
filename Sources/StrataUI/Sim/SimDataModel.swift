import SwiftUI
import StrataCore

// Data as the inspector sees it (docs/manifest.md, Data): each database's tables, the foreign keys
// between them, who writes them, the rows a key joins to, and entities assembled from sample rows.
// Pure values, built once per level (SimDataIndex).
//
// The `simData…` Level helpers at the bottom are stand-ins for data-core's Level helpers
// (StrataCore/Model/Data.swift): the same jobs (resolve a `ref`, follow refs in both directions with
// capped depth and fan-out, assemble an entity), so swapping them in is a rename at the call sites in
// this file.

/// A table on a node of the level.
struct SimTableRef: Hashable, Sendable, Identifiable {
    let node: String
    let table: String
    var id: String { "\(node).\(table)" }
}

/// One sample row of a table (its index in `TableSchema.rows`).
struct SimRowRef: Hashable, Sendable {
    let table: SimTableRef
    let row: Int
}

/// One cell of a sample row.
struct SimCellRef: Hashable, Sendable {
    let row: SimRowRef
    let column: String
    var table: SimTableRef { row.table }
}

/// A resolved `ref`: `from.fromColumn` holds values of `to.toColumn`.
struct SimForeignKey: Hashable, Sendable {
    let from: SimTableRef
    let fromColumn: String
    let to: SimTableRef
    let toColumn: String

    /// `order_items.order_id → orders.id`; the node is left out when both tables share it.
    var title: String {
        let target = from.node == to.node ? to.table : "\(to.node).\(to.table)"
        return "\(from.table).\(fromColumn) → \(target).\(toColumn)"
    }
}

/// The rows a key value joins to, found by following refs from one row in both directions.
struct SimDataJoin: Equatable {
    struct Hop: Equatable {
        let row: SimRowRef
        /// The row it was reached from, and the key between them.
        let from: SimRowRef
        let key: SimForeignKey
        /// Reached by following a ref from child to parent (`orders.user_id → users.id`).
        let up: Bool
        let depth: Int
    }

    let origin: SimRowRef
    var hops: [Hop] = []
    /// Rows the fan-out cap left out, by table.
    var omitted: [SimTableRef: Int] = [:]
    /// The origin and every joined row.
    var rows: Set<SimRowRef> = []
    /// Both ends of every hop: the key cells that make the join.
    var cells: Set<SimCellRef> = []
    var keys: Set<SimForeignKey> = []

    init(origin: SimRowRef) {
        self.origin = origin
        rows = [origin]
    }

    struct Group: Identifiable {
        let table: SimTableRef
        var rows: [Int]
        /// The keys that reached these rows.
        var keys: [SimForeignKey]
        var id: SimTableRef { table }
    }

    /// Joined rows by table, tables in the order the walk first reached them.
    var byTable: [Group] {
        var groups: [Group] = []
        for hop in hops {
            if let i = groups.firstIndex(where: { $0.table == hop.row.table }) {
                groups[i].rows.append(hop.row.row)
                if !groups[i].keys.contains(hop.key) { groups[i].keys.append(hop.key) }
            } else {
                groups.append(Group(table: hop.row.table, rows: [hop.row.row], keys: [hop.key]))
            }
        }
        return groups
    }

    func count(in table: SimTableRef) -> Int { rows.filter { $0.table == table }.count }
}

/// An entity assembled from one root row: the object the code sees, every field traced to its cell.
struct SimDataObject: Equatable {
    let type: String
    let row: SimRowRef
    var fields: [SimDataField]
}

struct SimDataField: Equatable {
    enum Value: Equatable {
        case scalar(String?)
        /// A parent through the root's ref, or a child whose ref column is unique; nil when no row matches.
        case one(SimDataObject?)
        /// Children through their ref to this row; `omitted` past the fan-out cap.
        case many([SimDataObject], omitted: Int)
    }

    let name: String
    /// The table whose tint the field carries: its own for a scalar, the joined one for a relation.
    let table: SimTableRef
    /// A scalar's cell.
    let cell: SimCellRef?
    /// The ref a relation follows.
    let key: SimForeignKey?
    let value: Value
}

// MARK: - Index

struct SimDataIndex {
    let level: Level
    /// Every table of every node that has a schema, in node then schema order.
    let tables: [SimTableRef]
    /// Every `ref` that resolves.
    let keys: [SimForeignKey]
    private let schemas: [SimTableRef: TableSchema]
    private let positions: [SimTableRef: Int]

    init(level: Level) {
        self.level = level
        var tables: [SimTableRef] = []
        var schemas: [SimTableRef: TableSchema] = [:]
        var positions: [SimTableRef: Int] = [:]
        for node in level.nodes {
            for (offset, table) in node.schema.enumerated() {
                let ref = SimTableRef(node: node.id, table: table.name)
                guard schemas[ref] == nil else { continue }
                tables.append(ref)
                schemas[ref] = table
                positions[ref] = offset
            }
        }
        self.tables = tables
        self.schemas = schemas
        self.positions = positions
        keys = level.simDataForeignKeys()
    }

    func table(_ ref: SimTableRef) -> TableSchema? { schemas[ref] }
    func tables(of node: String) -> [SimTableRef] { tables.filter { $0.node == node } }
    func keys(from table: SimTableRef) -> [SimForeignKey] { keys.filter { $0.from == table } }
    func keys(to table: SimTableRef) -> [SimForeignKey] { keys.filter { $0.to == table } }

    /// The key a column holds, if it is a `ref`.
    func key(_ table: SimTableRef, column: String) -> SimForeignKey? {
        keys.first { $0.from == table && $0.fromColumn == column }
    }

    /// A table's colour: its place in its node's schema picks it, so the diagram, an entity's fields and
    /// its legend agree. Amber (token 5) is left out, since it reads as the accent; grey takes its place.
    func tint(_ ref: SimTableRef) -> Color {
        let palette = [Theme.token(1), Theme.token(2), Theme.token(3), Theme.token(4), Theme.token(6), Theme.muted]
        return palette[(positions[ref] ?? 0) % palette.count]
    }

    /// The tables named by an op's `tables` on the node it talks to.
    func table(named name: String, on node: String?) -> SimTableRef? {
        guard let node else { return nil }
        let ref = SimTableRef(node: node, table: name)
        return schemas[ref] == nil ? nil : ref
    }

    /// The node an entity reads from: `source`, else the one database the node has ops on.
    func source(of entity: Entity, on node: Node) -> String? { level.simDataSource(of: entity, on: node) }

    /// The node ids that write a table: its `owner`, else every node with an op that writes it.
    func owners(of ref: SimTableRef, ops: SimOpsIndex) -> [String] {
        if let owner = schemas[ref]?.owner { return [owner] }
        return writers(of: ref, ops: ops)
    }

    /// Nodes whose ops write the table (an op's `tables` on this node with write access).
    func writers(of ref: SimTableRef, ops: SimOpsIndex) -> [String] {
        var ids: [String] = []
        for entry in usage(of: ref, ops: ops) where [.write, .readWrite].contains(SimOpsText.access(entry.op)) {
            if !ids.contains(entry.node.id) { ids.append(entry.node.id) }
        }
        return ids
    }

    /// Ops on the level that name the table in `tables` and talk to its node.
    func usage(of ref: SimTableRef, ops: SimOpsIndex) -> [SimOpsIndex.Entry] {
        ops.targeting(ref.node).filter { $0.op.tables.contains(ref.table) }
    }

    func join(from row: SimRowRef) -> SimDataJoin { level.simDataJoinedRows(from: row, keys: keys) }

    func assemble(_ entity: Entity, on node: Node, root row: Int) -> SimDataObject? {
        guard let source = source(of: entity, on: node) else { return nil }
        return level.simDataAssemble(entity, source: source, rootRow: row, keys: keys)
    }
}

// MARK: - Text

enum SimDataText {
    /// `12M · +40k/day`.
    static func volume(_ volume: TableVolume?) -> String? {
        guard let volume else { return nil }
        let parts = [volume.rows.map(count), volume.growthPerDay.flatMap { $0 > 0 ? "+\(count($0))/day" : nil }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// `12M`, `2.4M`, `18k`, `950`.
    static func count(_ n: Double) -> String {
        let (value, suffix): (Double, String) = switch n {
        case 1e9...: (n / 1e9, "B")
        case 1e6...: (n / 1e6, "M")
        case 1e3...: (n / 1e3, "k")
        default: (n, "")
        }
        let rounded = value >= 100 ? value.rounded() : (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? "\(Int(rounded))\(suffix)" : "\(rounded.formatted(.number.precision(.fractionLength(1))))\(suffix)"
    }

    /// A row's name: its primary key values (`o-9f1c`, `A-1 · 2026-06-01`), else its first value.
    static func label(_ table: TableSchema, row: Int) -> String {
        let keys = table.columns.filter(\.pk).map(\.name)
        let names = keys.isEmpty ? Array(table.columns.prefix(1).map(\.name)) : keys
        let values = names.map { table.simDataValue(row, $0) ?? "NULL" }
        return values.isEmpty ? "row \(row + 1)" : values.joined(separator: " · ")
    }

    /// The column a row is identified by: its first primary key column, else its first column.
    static func keyColumn(_ table: TableSchema) -> String? { (table.columns.first(where: \.pk) ?? table.columns.first)?.name }

    static func isNumeric(_ column: Column?) -> Bool {
        guard let type = column?.type?.lowercased() else { return false }
        let base = type.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first.map(String.init) ?? type
        return ["int", "int2", "int4", "int8", "integer", "smallint", "bigint", "serial", "bigserial", "smallserial",
                "numeric", "decimal", "real", "double", "float", "float4", "float8", "money", "number"].contains(base)
    }

    /// How an assembled object shows a value: strings quoted, numbers, booleans and JSON as they are.
    static func literal(_ value: String?, column: Column?) -> String {
        guard let value else { return "null" }
        let type = column?.type?.lowercased() ?? ""
        if isNumeric(column) || type.hasPrefix("bool") || type.hasPrefix("json") { return value }
        if column?.type == nil, Double(value) != nil || value == "true" || value == "false" { return value }
        return "\"\(value)\""
    }

    /// `Order`, `OrderItem`, `Address`: the singular of a table name in PascalCase.
    static func typeName(_ table: String) -> String {
        let words = words(table)
        guard let last = words.last else { return table }
        return (words.dropLast() + [singular(last)]).map(capitalized).joined()
    }

    /// The field an entity names a parent by: `user_id` → `user`, else the parent's singular table name.
    static func parentField(_ key: SimForeignKey) -> String {
        let column = key.fromColumn
        for suffix in ["_id", "Id", "_ref", "_key"] where column.hasSuffix(suffix) && column.count > suffix.count {
            return String(column.dropLast(suffix.count))
        }
        return camel(singularPhrase(key.to.table))
    }

    /// The field an entity names its children by: `order_items` under an order → `items`, `payments`
    /// → `payments`, or `payment` when each parent has at most one.
    static func childField(_ key: SimForeignKey, one: Bool) -> String {
        let parent = singularPhrase(key.to.table)
        var name = key.from.table
        if name.hasPrefix(parent + "_"), name.count > parent.count + 1 { name = String(name.dropFirst(parent.count + 1)) }
        return camel(one ? singularPhrase(name) : name)
    }

    static func singular(_ word: String) -> String {
        let lower = word.lowercased()
        if lower.hasSuffix("ies"), word.count > 3 { return String(word.dropLast(3)) + "y" }
        if ["sses", "xes", "ches", "shes", "zes", "uses"].contains(where: lower.hasSuffix) { return String(word.dropLast(2)) }
        if ["ss", "us", "is"].contains(where: lower.hasSuffix) { return word }
        if lower.hasSuffix("s"), word.count > 1 { return String(word.dropLast()) }
        return word
    }

    private static func singularPhrase(_ name: String) -> String {
        var parts = name.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
        guard let last = parts.popLast() else { return name }
        return (parts + [singular(last)]).joined(separator: "_")
    }

    private static func words(_ name: String) -> [String] {
        name.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " || $0 == "." }).map(String.init)
    }

    private static func capitalized(_ word: String) -> String { word.prefix(1).uppercased() + word.dropFirst() }

    private static func camel(_ name: String) -> String {
        let parts = words(name)
        guard let first = parts.first else { return name }
        return first.lowercased() + parts.dropFirst().map(capitalized).joined()
    }
}

extension TableSchema {
    func simDataColumn(_ name: String) -> Column? { columns.first { $0.name == name } }

    /// The value in a row's column; nil for NULL, a missing column or a short row.
    func simDataValue(_ row: Int, _ column: String) -> String? {
        guard rows.indices.contains(row), let index = columns.firstIndex(where: { $0.name == column }),
              rows[row].indices.contains(index) else { return nil }
        return rows[row][index]
    }

    /// Rows whose `column` equals `value` (NULL never matches).
    func simDataRows(where column: String, equals value: String) -> [Int] {
        guard let index = columns.firstIndex(where: { $0.name == column }) else { return [] }
        return rows.indices.filter { rows[$0].indices.contains(index) && rows[$0][index] == value }
    }
}

// MARK: - Level helpers (stand-ins for data-core's)

extension Level {
    /// Resolves a column's `ref`: `table.column` on `node`, or `node.table.column` on another node.
    func simDataResolve(_ ref: String, from node: String) -> (table: SimTableRef, column: String)? {
        let parts = ref.split(separator: ".").map(String.init)
        let (owner, table, column): (String, String, String)
        switch parts.count {
        case 2: (owner, table, column) = (node, parts[0], parts[1])
        case 3: (owner, table, column) = (parts[0], parts[1], parts[2])
        default: return nil
        }
        guard let schema = self.node(owner)?.schema.first(where: { $0.name == table }),
              schema.columns.contains(where: { $0.name == column }) else { return nil }
        return (SimTableRef(node: owner, table: table), column)
    }

    /// Every `ref` column on the level that resolves.
    func simDataForeignKeys() -> [SimForeignKey] {
        nodes.flatMap { node in
            node.schema.flatMap { table in
                table.columns.compactMap { column -> SimForeignKey? in
                    guard let ref = column.ref, let target = simDataResolve(ref, from: node.id) else { return nil }
                    return SimForeignKey(from: SimTableRef(node: node.id, table: table.name), fromColumn: column.name,
                                         to: target.table, toColumn: target.column)
                }
            }
        }
    }

    func simDataTable(_ ref: SimTableRef) -> TableSchema? { node(ref.node)?.schema.first { $0.name == ref.table } }

    /// The rows that join to `origin` through refs, in both directions, the way an aggregate hangs
    /// together: parents (`orders.user_id → users.id`) and their parents, children (`order_items.order_id
    /// → orders.id`) and their children and parents, but never a parent's other children (siblings).
    /// At most `maxDepth` hops from the origin and `fanOut` rows per key per row.
    func simDataJoinedRows(from origin: SimRowRef, keys: [SimForeignKey], maxDepth: Int = 3, fanOut: Int = 8) -> SimDataJoin {
        var join = SimDataJoin(origin: origin)
        var seen: Set<SimRowRef> = [origin]
        var frontier: [(row: SimRowRef, upOnly: Bool)] = [(origin, false)]
        var depth = 0
        while !frontier.isEmpty, depth < maxDepth {
            depth += 1
            var next: [(row: SimRowRef, upOnly: Bool)] = []
            for (row, upOnly) in frontier {
                guard let schema = simDataTable(row.table) else { continue }
                for key in keys {
                    for up in [true, false] where !(upOnly && !up) {
                        let (near, far, nearColumn, farColumn) = up ? (key.from, key.to, key.fromColumn, key.toColumn)
                                                                    : (key.to, key.from, key.toColumn, key.fromColumn)
                        guard near == row.table, let value = schema.simDataValue(row.row, nearColumn),
                              let target = simDataTable(far) else { continue }
                        var taken = 0
                        for match in target.simDataRows(where: farColumn, equals: value) {
                            let reached = SimRowRef(table: far, row: match)
                            guard !seen.contains(reached) else { continue }
                            guard taken < fanOut else { join.omitted[far, default: 0] += 1; continue }
                            taken += 1
                            seen.insert(reached)
                            join.rows.insert(reached)
                            join.keys.insert(key)
                            join.cells.insert(SimCellRef(row: row, column: nearColumn))
                            join.cells.insert(SimCellRef(row: reached, column: farColumn))
                            join.hops.append(.init(row: reached, from: row, key: key, up: up, depth: depth))
                            next.append((reached, upOnly || up))
                        }
                    }
                }
            }
            frontier = next
        }
        return join
    }

    /// The node an entity reads: its `source`, else the one database (or node with a schema) its node
    /// has ops on.
    func simDataSource(of entity: Entity, on node: Node) -> String? {
        if let source = entity.source { return self.node(source) == nil ? nil : source }
        var targets: [String] = []
        for op in node.ops {
            guard let target = op.target, let peer = self.node(target),
                  peer.kind == .database || !peer.schema.isEmpty, !targets.contains(target) else { continue }
            targets.append(target)
        }
        return targets.count == 1 ? targets[0] : nil
    }

    /// An entity as the object its code sees, from one sample row of its root table: the root's
    /// columns, each parent it refs as a nested object (in place of the ref column), and children that
    /// ref it as lists (or one object when their ref column is unique). Only the entity's tables are
    /// followed, each at most once on a path, `maxDepth` levels deep and `fanOut` children per list.
    func simDataAssemble(_ entity: Entity, source: String, rootRow: Int, keys: [SimForeignKey],
                         maxDepth: Int = 3, fanOut: Int = 5) -> SimDataObject? {
        let root = SimTableRef(node: source, table: entity.root)
        guard let schema = simDataTable(root), schema.rows.indices.contains(rootRow) else { return nil }
        let allowed = Set(([entity.root] + entity.includes).map { SimTableRef(node: source, table: $0) })

        func object(_ row: SimRowRef, via: SimForeignKey?, used: Set<SimTableRef>, depth: Int) -> SimDataObject {
            let schema = simDataTable(row.table) ?? TableSchema(name: row.table.table)
            let parents = depth < maxDepth ? keys.filter { $0.from == row.table && allowed.contains($0.to) && !used.contains($0.to) } : []
            let children = depth < maxDepth ? keys.filter { $0.to == row.table && allowed.contains($0.from) && !used.contains($0.from) } : []
            var hidden = Set(parents.map(\.fromColumn))
            if let via, via.from == row.table { hidden.insert(via.fromColumn) }
            let reached = used.union(parents.map(\.to)).union(children.map(\.from))
            var fields = schema.columns.filter { !hidden.contains($0.name) }.map { column in
                SimDataField(name: column.name, table: row.table, cell: SimCellRef(row: row, column: column.name), key: nil,
                             value: .scalar(schema.simDataValue(row.row, column.name)))
            }
            for key in parents {
                let match = schema.simDataValue(row.row, key.fromColumn).flatMap { value in
                    simDataTable(key.to)?.simDataRows(where: key.toColumn, equals: value).first
                }
                let nested = match.map { object(SimRowRef(table: key.to, row: $0), via: key, used: reached, depth: depth + 1) }
                fields.append(SimDataField(name: SimDataText.parentField(key), table: key.to, cell: nil, key: key, value: .one(nested)))
            }
            for key in children {
                guard let child = simDataTable(key.from) else { continue }
                let matches = schema.simDataValue(row.row, key.toColumn).map { child.simDataRows(where: key.fromColumn, equals: $0) } ?? []
                let column = child.simDataColumn(key.fromColumn)
                let one = column?.unique == true || (column?.pk == true && child.columns.filter(\.pk).count == 1)
                let objects = matches.prefix(one ? 1 : fanOut).map {
                    object(SimRowRef(table: key.from, row: $0), via: key, used: reached, depth: depth + 1)
                }
                fields.append(SimDataField(name: SimDataText.childField(key, one: one), table: key.from, cell: nil, key: key,
                                           value: one ? .one(objects.first) : .many(objects, omitted: max(0, matches.count - objects.count))))
            }
            return SimDataObject(type: SimDataText.typeName(row.table.table), row: row, fields: fields)
        }
        return object(SimRowRef(table: root, row: rootRow), via: nil, used: [root], depth: 0)
    }
}
