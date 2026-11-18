import Foundation

// Lookups over the tables, joins and entities of a level (docs/manifest.md, Data). Additive helpers
// next to the contract types, so the parser, the CLI and the UI resolve refs and join rows the same way.

/// A table on a node of the level.
public struct TableRef: Sendable, Hashable, CustomStringConvertible {
    public var node: String
    public var table: String
    public init(node: String, table: String) { self.node = node; self.table = table }
    public var description: String { "\(node).\(table)" }
}

/// A column of a table on a node of the level.
public struct ColumnRef: Sendable, Hashable, CustomStringConvertible {
    public var node: String
    public var table: String
    public var column: String
    public init(node: String, table: String, column: String) { self.node = node; self.table = table; self.column = column }
    public var tableRef: TableRef { TableRef(node: node, table: table) }
    public var description: String { "\(node).\(table).\(column)" }
}

/// A foreign key seen from one table. Outgoing: `column` here refers to `other`. Incoming: `other`
/// refers to `column` here.
public struct TableJoin: Sendable, Hashable {
    public enum Direction: String, Sendable { case outgoing, incoming }
    public var direction: Direction
    public var column: String
    public var other: ColumnRef
    public init(direction: Direction, column: String, other: ColumnRef) {
        self.direction = direction; self.column = column; self.other = other
    }
}

/// A sample row that joins to a selected value, and the column whose value matched.
public struct RowRef: Sendable, Hashable {
    public var node: String
    public var table: String
    public var row: Int                  // index into the table's `rows`
    public var column: String
    public init(node: String, table: String, row: Int, column: String) {
        self.node = node; self.table = table; self.row = row; self.column = column
    }
}

/// A table an op names, looked up on the node it targets (or its own node when it has no target).
public struct TouchedTable: Sendable {
    public var name: String
    public var node: String?             // nil when that node is not on the level
    public var schema: TableSchema?      // nil when the node's schema has no such table
    public init(name: String, node: String?, schema: TableSchema?) { self.name = name; self.node = node; self.schema = schema }
}

/// How one included table of an entity hangs from the table above it, through one ref column.
public struct EntityJoin: Sendable, Hashable {
    public enum Relation: String, Sendable {
        case child                       // rows of `table` refer to `above` (order_items.order_id → orders.id)
        case parent                      // `above` refers to `table` (orders.user_id → users.id)
    }
    public var table: String
    public var above: String             // the root or another included table
    public var relation: Relation
    public var column: String            // the column on `table`
    public var aboveColumn: String       // the column on `above` whose value it equals
    public init(table: String, above: String, relation: Relation, column: String, aboveColumn: String) {
        self.table = table; self.above = above; self.relation = relation; self.column = column; self.aboveColumn = aboveColumn
    }
}

/// One row of an assembled entity, with the rows joined below it.
public struct EntityRow: Sendable, Identifiable {
    public enum Relation: String, Sendable { case root, child, parent }
    /// The path from the root, unique within the tree: "orders#0/order_items#1".
    public var id: String
    public var table: String
    public var row: Int                  // index into the table's `rows`
    public var values: [String?]         // in column order
    public var relation: Relation
    public var column: String?           // the join column on this row's table (nil at the root)
    public var aboveColumn: String?      // the column on the row above whose value it equals
    public var children: [EntityRow] = []
    /// Matching rows left out by the fan-out cap, by table.
    public var omitted: [String: Int] = [:]
    /// The depth cap stopped here although more rows join below.
    public var truncated = false
    public init(id: String, table: String, row: Int, values: [String?], relation: Relation) {
        self.id = id; self.table = table; self.row = row; self.values = values; self.relation = relation
    }
}

public extension TableSchema {
    func columnIndex(_ name: String) -> Int? { columns.firstIndex { $0.name == name } }
    func column(_ name: String) -> Column? { columns.first { $0.name == name } }
    /// The primary key columns, in column order (several make a composite key).
    var primaryKey: [Column] { columns.filter(\.pk) }

    /// A sample value; nil for NULL or out of range.
    func value(row: Int, column: Int) -> String? {
        guard rows.indices.contains(row), rows[row].indices.contains(column) else { return nil }
        return rows[row][column]
    }

    /// The row whose primary key is `key`: the pk value, or a composite key's values joined by ",".
    /// A table without a pk is keyed by its first column.
    func rowIndex(key: String) -> Int? {
        let keyColumns = primaryKey.isEmpty ? Array(columns.prefix(1)) : primaryKey
        let indices = keyColumns.compactMap { columnIndex($0.name) }
        guard !indices.isEmpty else { return nil }
        return rows.indices.first { row in
            let values = indices.map { value(row: row, column: $0) }
            return !values.contains(nil) && values.compactMap { $0 }.joined(separator: ",") == key
        }
    }
}

public extension Level {
    /// Node kinds that hold tables and can be an entity's source.
    static let dataKinds: Set<NodeKind> = [.database, .store, .search]

    func table(_ node: String, _ table: String) -> TableSchema? {
        self.node(node)?.schema.first { $0.name == table }
    }

    func table(_ ref: TableRef) -> TableSchema? { table(ref.node, ref.table) }

    /// A column's `ref` resolved from the node that declares it: `table.column` on that node, or
    /// `node.table.column`. nil when the table or column doesn't exist.
    func resolveRef(_ ref: String, from node: String) -> ColumnRef? {
        let parts = ref.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let resolved: ColumnRef
        switch parts.count {
        case 2: resolved = ColumnRef(node: node, table: parts[0], column: parts[1])
        case 3: resolved = ColumnRef(node: parts[0], table: parts[1], column: parts[2])
        default: return nil
        }
        return table(resolved.tableRef)?.column(resolved.column) == nil ? nil : resolved
    }

    /// Every resolved ref on the level, in node, table and column order.
    func foreignKeys() -> [(from: ColumnRef, to: ColumnRef)] {
        var keys: [(from: ColumnRef, to: ColumnRef)] = []
        for node in nodes {
            for table in node.schema {
                for column in table.columns {
                    guard let ref = column.ref, let target = resolveRef(ref, from: node.id) else { continue }
                    keys.append((ColumnRef(node: node.id, table: table.name, column: column.name), target))
                }
            }
        }
        return keys
    }

    /// The joins of a table: its own ref columns (outgoing) first, then the columns that refer to it (incoming).
    func joins(of table: TableRef) -> [TableJoin] {
        let keys = foreignKeys()
        let outgoing = keys.filter { $0.from.tableRef == table }
            .map { TableJoin(direction: .outgoing, column: $0.from.column, other: $0.to) }
        let incoming = keys.filter { $0.to.tableRef == table }
            .map { TableJoin(direction: .incoming, column: $0.to.column, other: $0.from) }
        return outgoing + incoming
    }

    /// The tables an op names, resolved on its target's schema (or its own node's, without a target).
    func tables(touchedBy op: Operation, on node: String) -> [TouchedTable] {
        let holder = op.target ?? node
        let known = self.node(holder) != nil
        return op.tables.map { TouchedTable(name: $0, node: known ? holder : nil, schema: table(holder, $0)) }
    }

    /// The ops that write a table: ops on any node of the level that target its node, name it in
    /// `tables`, and have write or read-write access.
    func writers(of table: TableRef) -> [(node: String, op: Operation)] {
        nodes.flatMap { node in
            node.ops.filter { op in
                op.target == table.node && op.tables.contains(table.table) && (op.access == .write || op.access == .readWrite)
            }.map { (node: node.id, op: $0) }
        }
    }

    /// Who owns a table: its explicit `owner`, else every node with an op that writes it.
    func owners(of table: TableRef) -> [String] {
        if let owner = self.table(table)?.owner { return [owner] }
        var result: [String] = []
        for writer in writers(of: table) where !result.contains(writer.node) { result.append(writer.node) }
        return result
    }

    /// The data nodes (database, store, search) a node has ops on. With several, those whose schema
    /// has `root`, when that narrows it to one.
    func entitySourceCandidates(on node: String, root: String? = nil) -> [String] {
        guard let owner = self.node(node) else { return [] }
        var targets: [String] = []
        for op in owner.ops {
            guard let target = op.target, !targets.contains(target),
                  let kind = self.node(target)?.kind, Level.dataKinds.contains(kind) else { continue }
            targets.append(target)
        }
        if targets.count > 1, let root {
            let holding = targets.filter { table($0, root) != nil }
            if holding.count == 1 { return holding }
        }
        return targets
    }

    /// An entity's source node: its `source`, or the one data node its node has ops on.
    func entitySource(_ entity: Entity, on node: String) -> String? {
        if let source = entity.source { return source }
        let candidates = entitySourceCandidates(on: node, root: entity.root)
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// How an entity's included tables join its root, breadth first from the root: each table hangs
    /// from the nearest table already placed, trying includes in order (child refs before parent refs).
    /// Includes that no ref path reaches are left out.
    func entityJoins(_ entity: Entity, on node: String) -> [EntityJoin] {
        guard let source = entitySource(entity, on: node), let holder = self.node(source) else { return [] }
        var tables: [String: TableSchema] = [:]
        for table in holder.schema where tables[table.name] == nil { tables[table.name] = table }
        guard tables[entity.root] != nil else { return [] }
        func local(_ column: Column) -> ColumnRef? {
            guard let ref = column.ref, let target = resolveRef(ref, from: source), target.node == source else { return nil }
            return target
        }
        var placed: Set<String> = [entity.root]
        var queue = [entity.root]
        var joins: [EntityJoin] = []
        var next = 0
        while next < queue.count {
            let above = queue[next]
            next += 1
            guard let aboveTable = tables[above] else { continue }
            for include in entity.includes where !placed.contains(include) {
                guard let table = tables[include] else { continue }
                let join: EntityJoin
                if let column = table.columns.first(where: { local($0)?.table == above }), let target = local(column) {
                    join = EntityJoin(table: include, above: above, relation: .child, column: column.name, aboveColumn: target.column)
                } else if let column = aboveTable.columns.first(where: { local($0)?.table == include }), let target = local(column) {
                    join = EntityJoin(table: include, above: above, relation: .parent, column: target.column, aboveColumn: column.name)
                } else {
                    continue
                }
                joins.append(join)
                placed.insert(include)
                queue.append(include)
            }
        }
        return joins
    }

    /// Assembles an entity from one root row, chosen by its primary key value (the first row when
    /// `key` is nil). See `assembleEntity(_:on:row:maxDepth:maxRows:)`.
    func assembleEntity(_ entity: Entity, on node: String, key: String? = nil, maxDepth: Int = 4, maxRows: Int = 8) -> EntityRow? {
        guard let source = entitySource(entity, on: node), let root = table(source, entity.root) else { return nil }
        let row = key.map { root.rowIndex(key: $0) } ?? (root.rows.isEmpty ? nil : 0)
        guard let row else { return nil }
        return assembleEntity(entity, on: node, row: row, maxDepth: maxDepth, maxRows: maxRows)
    }

    /// Assembles an entity from the root table's row `row` by following its joins (`entityJoins`).
    /// Children are the rows whose ref equals the key of the row above; parents are the rows the row
    /// above refers to. At most `maxDepth` levels below the root and `maxRows` rows per join.
    func assembleEntity(_ entity: Entity, on node: String, row: Int, maxDepth: Int = 4, maxRows: Int = 8) -> EntityRow? {
        guard let source = entitySource(entity, on: node), let holder = self.node(source),
              let root = holder.schema.first(where: { $0.name == entity.root }), root.rows.indices.contains(row) else { return nil }
        var tables: [String: TableSchema] = [:]
        for table in holder.schema where tables[table.name] == nil { tables[table.name] = table }
        let below = Dictionary(grouping: entityJoins(entity, on: node), by: \.above)

        func expand(_ table: TableSchema, row: Int, relation: EntityRow.Relation, via join: EntityJoin?, path: String, depth: Int) -> EntityRow {
            var result = EntityRow(id: path, table: table.name, row: row, values: table.rows[row], relation: relation)
            result.column = join?.column
            result.aboveColumn = join?.aboveColumn
            for join in below[table.name] ?? [] {
                guard let other = tables[join.table], let otherIndex = other.columnIndex(join.column),
                      let aboveIndex = table.columnIndex(join.aboveColumn),
                      let value = table.value(row: row, column: aboveIndex) else { continue }
                let matches = other.rows.indices.filter { other.value(row: $0, column: otherIndex) == value }
                guard !matches.isEmpty else { continue }
                guard depth < maxDepth else { result.truncated = true; continue }
                for match in matches.prefix(max(maxRows, 0)) {
                    result.children.append(expand(other, row: match, relation: join.relation == .child ? .child : .parent,
                                                  via: join, path: "\(path)/\(other.name)#\(match)", depth: depth + 1))
                }
                if matches.count > maxRows { result.omitted[other.name] = matches.count - max(maxRows, 0) }
            }
            return result
        }
        return expand(root, row: row, relation: .root, via: nil, path: "\(root.name)#\(row)", depth: 0)
    }

    /// The column a value ultimately identifies: follows refs (`orders.user_id → users.id`) to the
    /// column that refers to nothing.
    func keyColumn(of column: ColumnRef) -> ColumnRef {
        var current = column
        var seen: Set<ColumnRef> = [column]
        while let ref = table(current.tableRef)?.column(current.column)?.ref,
              let next = resolveRef(ref, from: current.node), seen.insert(next).inserted {
            current = next
        }
        return current
    }

    /// Join highlighting: every sample row whose value `value` in some column joins the selected
    /// `(table, column)`. That is the key column the selection refers to and every column that refers
    /// to the same key, including the selected row itself. Empty when the column joins nothing.
    func joinedRows(_ column: ColumnRef, value: String) -> [RowRef] {
        let key = keyColumn(of: column)
        var members: [ColumnRef] = []
        for node in nodes {
            for table in node.schema {
                for other in table.columns {
                    let candidate = ColumnRef(node: node.id, table: table.name, column: other.name)
                    if keyColumn(of: candidate) == key { members.append(candidate) }
                }
            }
        }
        guard members.count > 1 else { return [] }
        var rows: [RowRef] = []
        for member in members {
            guard let table = table(member.tableRef), let index = table.columnIndex(member.column) else { continue }
            for row in table.rows.indices where table.value(row: row, column: index) == value {
                rows.append(RowRef(node: member.node, table: member.table, row: row, column: member.column))
            }
        }
        return rows
    }
}

/// Short text for data volumes and real-world rates, shared by the CLI and the UI.
public enum DataFormat {
    /// 4_000_000 → "4M", 1_250 → "1.3k", 950 → "950", 0.5 → "0.5".
    public static func count(_ value: Double) -> String {
        let units: [(factor: Double, suffix: String)] = [(1e9, "B"), (1e6, "M"), (1e3, "k"), (1, "")]
        for (index, unit) in units.enumerated() where abs(value) >= unit.factor || unit.factor == 1 {
            // 999_999 rounds to 1000k; show it as 1M.
            if index > 0, abs((value / unit.factor * 10).rounded() / 10) >= 1000 {
                return trimmed(value / units[index - 1].factor) + units[index - 1].suffix
            }
            return trimmed(value / unit.factor) + unit.suffix
        }
        return trimmed(value)
    }

    /// Requests per second as "120/s", or per minute below one per second ("30/min").
    public static func rate(_ perSecond: Double) -> String {
        perSecond >= 1 || perSecond == 0 ? count(perSecond) + "/s" : count(perSecond * 60) + "/min"
    }

    private static func trimmed(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }
}
