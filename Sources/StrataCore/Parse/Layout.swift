import Foundation

enum Layout {
    static func place(_ level: inout Level) {
        guard level.nodes.contains(where: { $0.at == nil }) else { return }
        let diagram = level.nodes.filter { $0.kind.role != .annotation }
        let nodeByID = Dictionary(diagram.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = diagram.map(\.id)
        let order = Dictionary(ids.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let edges = level.edges.filter { nodeByID[$0.from] != nil && nodeByID[$0.to] != nil && $0.from != $0.to }
        let incoming = Dictionary(grouping: edges, by: \.to).mapValues { $0.map(\.from) }
        let outgoing = Dictionary(grouping: edges, by: \.from).mapValues { $0.map(\.to) }
        let columns = assignColumns(diagram, incoming: incoming, outgoing: outgoing, nodes: nodeByID)
        let layers = Dictionary(grouping: ids) { columns[$0, default: 0] }
        let layerOrder = layers.keys.sorted()
        let center = Double(max(0, (layers.values.map(\.count).max() ?? 1) - 1)) / 2
        let fixed = level.nodes.compactMap(\.at)
        var positions = Dictionary(diagram.compactMap { n in n.at.map { (n.id, $0) } }, uniquingKeysWith: { first, _ in first })

        func sweep(_ columns: [Double], neighbors: [String: [String]]) {
            for column in columns {
                let layer = layers[column, default: []].filter { nodeByID[$0]?.at == nil }
                let preferred = layer.map { id -> (id: String, row: Double) in
                    let rows = neighbors[id, default: []].compactMap { positions[$0]?.y }
                    // Keep an earlier ordering when this sweep has no evidence to move it.
                    let row = rows.isEmpty ? (positions[id]?.y ?? center) : rows.reduce(0, +) / Double(rows.count)
                    return (id, row)
                }.sorted { ($0.row, order[$0.id, default: 0]) < ($1.row, order[$1.id, default: 0]) }
                let reserved = fixed + positions.values.filter { $0.x != column }
                let start = preferred.enumerated().map { $0.element.row - Double($0.offset) }.sorted()
                guard !start.isEmpty else { continue }
                let middle = start.count / 2
                let median = start.count.isMultiple(of: 2) ? start[middle - 1] / 2 + start[middle] / 2 : start[middle]
                var row = median.rounded(.toNearestOrEven)
                for item in preferred {
                    while reserved.contains(where: { abs($0.x - column) < 1 && abs($0.y - row) < 1 }) {
                        row = max(row + 1, row.nextUp)
                    }
                    positions[item.id] = GridPoint(column, row)
                    row = max(row + 1, row.nextUp)
                }
            }
        }

        sweep(layerOrder, neighbors: incoming)
        for _ in 0..<2 {
            sweep(layerOrder.reversed(), neighbors: outgoing)
            sweep(layerOrder, neighbors: incoming)
        }
        if fixed.isEmpty, let top = positions.values.map(\.y).min() {
            positions = positions.mapValues { GridPoint($0.x, $0.y - top) }
        }

        let bottom = (fixed + positions.values).map(\.y).max()
        let noteRow = bottom.map { max($0 + 1, $0.nextUp) } ?? 0
        var noteColumn = (fixed + positions.values).map(\.x).min() ?? 0
        for index in level.nodes.indices where level.nodes[index].at == nil {
            if level.nodes[index].kind.role == .annotation {
                level.nodes[index].at = GridPoint(noteColumn, noteRow)
                noteColumn = max(noteColumn + 1, noteColumn.nextUp)
            } else {
                level.nodes[index].at = positions[level.nodes[index].id]
            }
        }
    }

    private static func assignColumns(_ diagram: [Node], incoming: [String: [String]], outgoing: [String: [String]],
                                      nodes: [String: Node]) -> [String: Double] {
        let ids = diagram.map(\.id)
        let sources = Set(diagram.filter { $0.kind.role == .source || ($0.kind == .port && incoming[$0.id] == nil) }.map(\.id))
        var pending = Dictionary(ids.map { ($0, sources.contains($0) ? 0 : incoming[$0, default: []].count) },
                                 uniquingKeysWith: { first, _ in first })
        var ready = ids.filter { pending[$0] == 0 }
        var next = 0
        var columns: [String: Double] = [:]
        var remaining = ids.makeIterator()
        while columns.count < nodes.count {
            if next == ready.count {
                // Declared edges may form cycles. Break the cycle at the first unplaced node.
                while let id = remaining.next() {
                    if columns[id] == nil { ready.append(id); break }
                }
            }
            let id = ready[next]
            next += 1
            guard columns[id] == nil else { continue }
            let previous = incoming[id, default: []].compactMap { columns[$0] }.max()
            let base = sources.isEmpty || sources.contains(id) ? 0.0 : 1.0
            columns[id] = nodes[id]?.at?.x ?? (sources.contains(id) ? base : previous.map { max($0 + 1, $0.nextUp) } ?? base)
            for target in outgoing[id, default: []] where !sources.contains(target) {
                pending[target, default: 0] -= 1
                if pending[target] == 0 { ready.append(target) }
            }
        }
        return columns
    }
}
