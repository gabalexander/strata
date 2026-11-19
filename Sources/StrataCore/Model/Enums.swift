import Foundation

// Lookups over a manifest's enums (docs/manifest.md, Enums): values by code or name, the columns that
// hold them on each level, the order a state machine is drawn in, who uses an enum, and search.
// Additive helpers next to the contract types, shared by the parser, the CLI and the UI.

/// A column whose values come from an enum, on a node of the level at `path` ([] is the root).
public struct EnumColumn: Sendable, Hashable, CustomStringConvertible {
    public var path: [String]
    public var column: ColumnRef
    public var enumID: String
    public init(path: [String], column: ColumnRef, enumID: String) {
        self.path = path; self.column = column; self.enumID = enumID
    }
    public var description: String { column.description }
}

/// Who performs a transition: a node, or one of its ops, on the level at `path`.
public struct EnumActor: Sendable, Hashable {
    public var path: [String]
    public var node: String
    public var op: String?
    public init(path: [String], node: String, op: String?) { self.path = path; self.node = node; self.op = op }
}

/// Where an enum shows up: the columns linked to it, and the ops that name those tables or whose
/// query, payload, request or response holds one of its values.
public struct EnumUsage: Sendable {
    public struct OpUse: Sendable, Hashable {
        public var path: [String]
        public var node: String
        public var op: String
        /// The enum's values the op's text names, in the order they first appear.
        public var values: [String]
        public init(path: [String], node: String, op: String, values: [String]) {
            self.path = path; self.node = node; self.op = op; self.values = values
        }
    }
    public var columns: [EnumColumn] = []
    public var ops: [OpUse] = []
    public init() {}
}

/// A search result: a value of an enum, or the enum itself when its label or id matched (`value` nil).
public struct EnumSearchHit: Sendable, Hashable {
    public var enumID: String
    public var value: String?
    public var score: Int
    public init(enumID: String, value: String?, score: Int) { self.enumID = enumID; self.value = value; self.score = score }
}

/// The left-to-right layout of a state machine: values in lifecycle order, each in a column (`layer`)
/// and a row within it. Transitions that go back (cycles such as pause and resume) are in `back`.
public struct EnumLifecycle: Sendable, Equatable {
    public var order: [String] = []
    public var layer: [String: Int] = [:]
    public var row: [String: Int] = [:]
    /// Indices into `transitions` that point back to an earlier column or the same value.
    public var back: Set<Int> = []
    public var layers: Int { (layer.values.max() ?? -1) + 1 }
    public init() {}
}

public extension EnumDef {
    /// A value by its code (`3200`), else by its name (`scheduled`): APIs often send the name of a
    /// value the database stores as a code.
    func resolve(_ literal: String) -> EnumValue? { value(literal) ?? value(named: literal) }

    func value(named name: String) -> EnumValue? { values.first { $0.name == name } }

    /// Transitions out of a value, in declaration order.
    func transitions(from value: String) -> [EnumTransition] { transitions.filter { $0.from == value } }

    /// Transitions into a value, in declaration order.
    func transitions(to value: String) -> [EnumTransition] { transitions.filter { $0.to == value } }

    /// `3200 scheduled`, or the name alone when the code is the name (`placed`).
    func title(_ value: EnumValue) -> String { value.value == value.name ? value.name : "\(value.value) \(value.name)" }

    /// `3200 scheduled` for a known code, the code as written otherwise.
    func title(of code: String) -> String { self.value(code).map(title) ?? code }

    /// Values in lifecycle order for a left-to-right diagram. Starts are values nothing moves into
    /// (the first value when every value has a way in); a depth-first walk from them, in declaration
    /// order, marks the transitions that close a cycle as `back`. Each value's column is its longest
    /// path from a start over the remaining transitions, and rows follow the values they come from.
    /// Values no transition touches come last, in the first column.
    func lifecycle() -> EnumLifecycle {
        var result = EnumLifecycle()
        let codes = values.map(\.value)
        let position = Dictionary(codes.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let valid = transitions.indices.filter { position[transitions[$0].from] != nil && position[transitions[$0].to] != nil }
        for index in valid where transitions[index].from == transitions[index].to { result.back.insert(index) }
        let forward = valid.filter { !result.back.contains($0) }
        var outgoing: [String: [Int]] = [:]
        var incoming: Set<String> = []
        for index in forward {
            outgoing[transitions[index].from, default: []].append(index)
            incoming.insert(transitions[index].to)
        }
        let connected = codes.filter { outgoing[$0] != nil || incoming.contains($0) }

        // Depth-first from the starts: an edge to a value still on the stack closes a cycle.
        var state: [String: Int] = [:]   // 1 on the stack, 2 done
        func visit(_ code: String) {
            state[code] = 1
            for index in outgoing[code] ?? [] {
                let next = transitions[index].to
                switch state[next] {
                case 1: result.back.insert(index)
                case 2: break
                default: visit(next)
                }
            }
            state[code] = 2
        }
        let starts = connected.filter { !incoming.contains($0) }
        for code in starts where state[code] == nil { visit(code) }
        for code in connected where state[code] == nil { visit(code) }

        // Longest path over the forward transitions (a DAG now), in topological order.
        let dag = forward.filter { !result.back.contains($0) }
        var indegree = Dictionary(connected.map { ($0, 0) }, uniquingKeysWith: { first, _ in first })
        for index in dag { indegree[transitions[index].to, default: 0] += 1 }
        var ready = connected.filter { indegree[$0] == 0 }
        var layer: [String: Int] = [:]
        while !ready.isEmpty {
            let code = ready.removeFirst()
            for index in dag where transitions[index].from == code {
                let next = transitions[index].to
                layer[next] = max(layer[next] ?? 0, (layer[code] ?? 0) + 1)
                indegree[next, default: 0] -= 1
                if indegree[next] == 0 {
                    // Keep declaration order among the values that become ready.
                    let at = ready.firstIndex { position[$0, default: 0] > position[next, default: 0] } ?? ready.count
                    ready.insert(next, at: at)
                }
            }
        }
        for code in connected where layer[code] == nil { layer[code] = 0 }

        // Rows: by the mean row of the values a value comes from, then declaration order.
        var rows: [String: Int] = [:]
        let layered = Dictionary(grouping: connected, by: { layer[$0] ?? 0 })
        for column in layered.keys.sorted() {
            let members = layered[column] ?? []
            func barycenter(_ code: String) -> Double {
                let sources = dag.filter { transitions[$0].to == code }.compactMap { rows[transitions[$0].from] }
                return sources.isEmpty ? -1 : Double(sources.reduce(0, +)) / Double(sources.count)
            }
            let sorted = members.sorted { a, b in
                let (x, y) = (barycenter(a), barycenter(b))
                return x == y ? position[a, default: 0] < position[b, default: 0] : x < y
            }
            for (row, code) in sorted.enumerated() { rows[code] = row }
        }
        let isolated = codes.filter { layer[$0] == nil }
        let firstColumn = (layered[0] ?? []).count
        for (offset, code) in isolated.enumerated() {
            layer[code] = 0
            rows[code] = firstColumn + offset
        }
        result.layer = layer
        result.row = rows
        result.order = codes.sorted { a, b in
            let (la, lb) = (layer[a] ?? 0, layer[b] ?? 0)
            if la != lb { return la < lb }
            return (rows[a] ?? 0) < (rows[b] ?? 0)
        }
        return result
    }
}

public extension Level {
    /// Every column on this level linked to an enum, in node, table and column order.
    func enumColumns(path: [String] = []) -> [EnumColumn] {
        nodes.flatMap { node in
            node.schema.flatMap { table in
                table.columns.compactMap { column in
                    column.enumRef.map { EnumColumn(path: path, column: ColumnRef(node: node.id, table: table.name, column: column.name), enumID: $0) }
                }
            }
        }
    }
}

public extension Manifest {
    func enumDef(_ id: String) -> EnumDef? { enums.first { $0.id == id } }

    /// A value of an enum by code, else by name.
    func enumValue(_ enumID: String, _ literal: String) -> EnumValue? { enumDef(enumID)?.resolve(literal) }

    /// Every level of the manifest with its path: the root, each node's `inside:` (path + node id) and
    /// each op's `inside:` (path + `node#op`), depth first in node order.
    func everyLevel() -> [(path: [String], level: Level)] {
        var result: [(path: [String], level: Level)] = []
        func walk(_ level: Level, _ path: [String]) {
            result.append((path, level))
            for node in level.nodes {
                if let inside = node.inside { walk(inside, path + [node.id]) }
                for op in node.ops { if let inside = op.inside { walk(inside, path + ["\(node.id)#\(op.id)"]) } }
            }
        }
        walk(root, [])
        return result
    }

    /// Every enum-linked column on every level, root first.
    func enumColumns() -> [EnumColumn] { everyLevel().flatMap { $0.level.enumColumns(path: $0.path) } }

    /// The enum a column holds, looked up on the level at `path`.
    func enumOf(node: String, table: String, column: String, at path: [String] = []) -> EnumDef? {
        level(at: path)?.table(node, table)?.column(column)?.enumRef.flatMap(enumDef)
    }

    /// A transition's `by`: `node` or `node/op`, on the shallowest level that has that node (the root first).
    func resolveActor(_ by: String) -> EnumActor? {
        let parts = by.split(separator: "/", maxSplits: 1).map(String.init)
        guard let nodeID = parts.first else { return nil }
        let op = parts.count == 2 ? parts[1] : nil
        let levels = everyLevel().sorted { $0.path.count < $1.path.count }
        for (path, level) in levels {
            guard let node = level.node(nodeID) else { continue }
            if let op, !node.ops.contains(where: { $0.id == op }) { continue }
            return EnumActor(path: path, node: nodeID, op: op)
        }
        return nil
    }

    /// The columns linked to an enum, and the ops that touch its tables or name its values.
    func enumUsage(_ id: String) -> EnumUsage {
        var usage = EnumUsage()
        let all = enumColumns()
        usage.columns = all.filter { $0.enumID == id }
        for (path, level) in everyLevel() {
            let linked = Set(usage.columns.filter { $0.path == path }.map(\.column.tableRef))
            for node in level.nodes {
                for op in node.ops {
                    var values: [String] = []
                    for text in [op.query, op.payload, op.request, op.response].compactMap({ $0 }) {
                        for hit in enumOccurrences(in: text, level: level, op: op, on: node.id) where hit.enumID == id {
                            let code = hit.value ?? hit.literal
                            if !values.contains(code) { values.append(code) }
                        }
                    }
                    let touches = level.tables(touchedBy: op, on: node.id).contains { touched in
                        touched.node.map { linked.contains(TableRef(node: $0, table: touched.name)) } ?? false
                    }
                    if touches || !values.isEmpty {
                        usage.ops.append(EnumUsage.OpUse(path: path, node: node.id, op: op.id, values: values))
                    }
                }
            }
        }
        return usage
    }

    /// Finds enum values by code (`3200`), name (`scheduled`) or the enum's label or id (`campaign
    /// status`), best first. A query naming only the enum returns the enum itself.
    func searchEnums(_ query: String) -> [EnumSearchHit] {
        let tokens = Self.searchWords(query)
        guard !tokens.isEmpty else { return [] }
        var hits: [EnumSearchHit] = []
        for def in enums {
            let labelWords = Self.searchWords(def.label + " " + def.id)
            let labelMatches = tokens.filter { token in labelWords.contains { $0.hasPrefix(token) } }
            for value in def.values {
                let code = value.value.lowercased(), name = value.name.lowercased()
                var score = 0
                var unmatched = 0
                for token in tokens {
                    if token == code { score += 100 }
                    else if token == name { score += 90 }
                    else if name.hasPrefix(token) || code.hasPrefix(token) { score += 60 }
                    else if Self.searchWords(value.name).contains(where: { $0.hasPrefix(token) }) { score += 50 }
                    else if labelMatches.contains(token) { score += 10 }
                    else { unmatched += 1 }
                }
                // A value matches when something besides the enum's own name matched.
                if unmatched == 0, score > labelMatches.count * 10 {
                    hits.append(EnumSearchHit(enumID: def.id, value: value.value, score: score))
                }
            }
            if labelMatches.count == tokens.count {
                hits.append(EnumSearchHit(enumID: def.id, value: nil, score: 40 * tokens.count))
            }
        }
        let order = Dictionary(enums.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        return hits.enumerated().sorted { a, b in
            if a.element.score != b.element.score { return a.element.score > b.element.score }
            let (x, y) = (order[a.element.enumID] ?? 0, order[b.element.enumID] ?? 0)
            return x == y ? a.offset < b.offset : x < y
        }.map(\.element)
    }

    private static func searchWords(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
