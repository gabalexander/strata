import SwiftUI
import StrataCore

// Data as the inspector sees it (docs/manifest.md, Data): each database's tables, the foreign keys
// between them, who writes them, the rows a key joins to, and entities assembled from sample rows.
// Pure values, built once per level (SimDataIndex), on top of StrataCore's Level helpers
// (Model/Data.swift): `foreignKeys`, `table`, `owners`, `writers`, `entitySource`, `entityJoins` and
// `assembleEntity`. The one walk of its own is the join highlight (`SimDataJoins`): the rows a row's
// aggregate holds, following refs in both directions with capped depth and fan-out.

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
        /// Rows join here, but the depth cap stopped the assembly above them.
        case cut
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
    /// Every `ref` that resolves (`Level.foreignKeys`).
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
        keys = level.foreignKeys().map { key in
            SimForeignKey(from: SimTableRef(node: key.from.node, table: key.from.table), fromColumn: key.from.column,
                          to: SimTableRef(node: key.to.node, table: key.to.table), toColumn: key.to.column)
        }
    }

    func table(_ ref: SimTableRef) -> TableSchema? { schemas[ref] }
    func tables(of node: String) -> [SimTableRef] { tables.filter { $0.node == node } }

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

    /// A table named by an op's `tables` or an entity, on the node it lives on.
    func table(named name: String, on node: String?) -> SimTableRef? {
        guard let node else { return nil }
        let ref = SimTableRef(node: node, table: name)
        return schemas[ref] == nil ? nil : ref
    }

    /// The node an entity reads from (`Level.entitySource`).
    func source(of entity: Entity, on node: Node) -> String? { level.entitySource(entity, on: node.id) }

    /// Who owns a table: its `owner`, else every node with an op that writes it (`Level.owners`).
    func owners(of ref: SimTableRef) -> [String] { level.owners(of: TableRef(node: ref.node, table: ref.table)) }

    /// Every node with an op that writes the table (`Level.writers`).
    func writers(of ref: SimTableRef) -> [String] {
        var ids: [String] = []
        for writer in level.writers(of: TableRef(node: ref.node, table: ref.table)) where !ids.contains(writer.node) {
            ids.append(writer.node)
        }
        return ids
    }

    /// Ops on the level that name the table in `tables` and talk to its node.
    func usage(of ref: SimTableRef, ops: SimOpsIndex) -> [SimOpsIndex.Entry] {
        ops.targeting(ref.node).filter { $0.op.tables.contains(ref.table) }
    }

    func join(from row: SimRowRef) -> SimDataJoin { SimDataJoins.walk(from: row, keys: keys, index: self) }

    /// An entity as the object its code sees, from one sample row of its root table
    /// (`Level.assembleEntity`): the root's columns, each parent it refs as a nested object in place of
    /// the ref column, and the children that ref it as lists (one object when their ref column is
    /// unique), without the ref back to the row above.
    func assemble(_ entity: Entity, on node: Node, root row: Int, maxDepth: Int = 3, maxRows: Int = 5) -> SimDataObject? {
        guard let source = source(of: entity, on: node),
              let tree = level.assembleEntity(entity, on: node.id, row: row, maxDepth: maxDepth, maxRows: maxRows) else { return nil }
        let below = Dictionary(grouping: level.entityJoins(entity, on: node.id), by: \.above)
        func object(_ entityRow: EntityRow) -> SimDataObject {
            let ref = SimTableRef(node: source, table: entityRow.table)
            let schema = table(ref) ?? TableSchema(name: entityRow.table)
            let joins = below[entityRow.table] ?? []
            var hidden = Set(joins.filter { $0.relation == .parent }.map(\.aboveColumn))
            if entityRow.relation == .child, let column = entityRow.column { hidden.insert(column) }
            let rowRef = SimRowRef(table: ref, row: entityRow.row)
            var fields = schema.columns.enumerated().filter { !hidden.contains($0.element.name) }.map { offset, column in
                SimDataField(name: column.name, table: ref, cell: SimCellRef(row: rowRef, column: column.name), key: nil,
                             value: .scalar(entityRow.values.indices.contains(offset) ? entityRow.values[offset] : nil))
            }
            for join in joins {
                let joined = SimTableRef(node: source, table: join.table)
                let key = join.relation == .child
                    ? SimForeignKey(from: joined, fromColumn: join.column, to: ref, toColumn: join.aboveColumn)
                    : SimForeignKey(from: ref, fromColumn: join.aboveColumn, to: joined, toColumn: join.column)
                let rows = entityRow.children.filter { $0.table == join.table && $0.column == join.column && $0.aboveColumn == join.aboveColumn }
                let objects = rows.map(object)
                let cut = objects.isEmpty && entityRow.truncated
                if join.relation == .parent {
                    fields.append(SimDataField(name: SimDataText.parentField(key), table: joined, cell: nil, key: key,
                                               value: cut ? .cut : .one(objects.first)))
                } else {
                    let column = table(joined)?.column(join.column)
                    let one = column?.unique == true || (column?.pk == true && table(joined)?.primaryKey.count == 1)
                    let value: SimDataField.Value = cut ? .cut : one ? .one(objects.first)
                        : .many(objects, omitted: entityRow.omitted[join.table] ?? 0)
                    fields.append(SimDataField(name: SimDataText.childField(key, one: one), table: joined, cell: nil, key: key, value: value))
                }
            }
            return SimDataObject(type: SimDataText.typeName(entityRow.table), row: rowRef, fields: fields)
        }
        return object(tree)
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

    /// `12M`, `2.4M`, `18k`, `950` (`DataFormat.count`, as the CLI prints them).
    static func count(_ n: Double) -> String { DataFormat.count(n) }

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
    /// The value in a row's column; nil for NULL, a missing column or a short row.
    func simDataValue(_ row: Int, _ column: String) -> String? {
        columnIndex(column).flatMap { value(row: row, column: $0) }
    }

    /// Rows whose `column` equals `value` (NULL never matches).
    func simDataRows(where column: String, equals value: String) -> [Int] {
        guard let index = columnIndex(column) else { return [] }
        return rows.indices.filter { self.value(row: $0, column: index) == value }
    }
}

// MARK: - Join highlight

/// The rows that join to one row, the way an aggregate hangs together: parents (`orders.user_id →
/// users.id`) and their parents, children (`order_items.order_id → orders.id`) and their children and
/// parents, but never a parent's other children (siblings). `Level.joinedRows` answers a different
/// question (every row sharing one key value) and would light the other orders of the same user.
enum SimDataJoins {
    /// At most `maxDepth` hops from the origin and `fanOut` rows per key per row.
    static func walk(from origin: SimRowRef, keys: [SimForeignKey], index: SimDataIndex,
                     maxDepth: Int = 3, fanOut: Int = 8) -> SimDataJoin {
        var join = SimDataJoin(origin: origin)
        var seen: Set<SimRowRef> = [origin]
        var frontier: [(row: SimRowRef, upOnly: Bool)] = [(origin, false)]
        var depth = 0
        while !frontier.isEmpty, depth < maxDepth {
            depth += 1
            var next: [(row: SimRowRef, upOnly: Bool)] = []
            for (row, upOnly) in frontier {
                guard let schema = index.table(row.table) else { continue }
                for key in keys {
                    for up in [true, false] where !(upOnly && !up) {
                        let (near, far, nearColumn, farColumn) = up ? (key.from, key.to, key.fromColumn, key.toColumn)
                                                                    : (key.to, key.from, key.toColumn, key.fromColumn)
                        guard near == row.table, let value = schema.simDataValue(row.row, nearColumn),
                              let target = index.table(far) else { continue }
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
}
