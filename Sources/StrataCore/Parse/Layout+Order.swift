import Foundation

/// Ordering within layers: barycenter sweeps down and up, each followed by transposition, keeping the
/// order with the fewest crossings. Sorting is hierarchical, so a group's members (and its nested
/// groups) stay contiguous in every layer, and sibling groups keep one order across all layers so
/// their regions never interleave.
extension LayeredGraph {
    /// Several deterministic starts (the author's hint rows first, then sweeps from either side in
    /// manifest order and reversed); the order with the fewest crossings wins, the earlier on a tie.
    mutating func orderLayers() {
        let base = layers
        let hinted = hints.filter { $0 != nil }.count
        let starts: [Start] = (hinted > 0 && hinted * 2 >= ids.count ? [.hints] : [])
            + [.forward(reversed: false), .backward(reversed: false), .forward(reversed: true), .backward(reversed: true)]
        var best = base, bestCrossings = Int.max
        for start in starts {
            layers = base
            initialOrder(start)
            reduceCrossings()
            let count = crossings()
            if count < bestCrossings {
                best = layers
                bestCrossings = count
            }
            if bestCrossings == 0 { break }
        }
        layers = best
    }

    enum Start { case hints, forward(reversed: Bool), backward(reversed: Bool) }

    private mutating func reduceCrossings() {
        var ranks = groupRanks()
        var best = layers
        var bestCrossings = crossings()
        var stale = 0
        // Sweeps alternate direction and how ties break; later rounds look both ways at once.
        for iteration in 0..<40 where layers.count > 1 && bestCrossings > 0 {
            let flip = (iteration / 2).isMultiple(of: 2) == false
            if iteration >= 24 {
                for l in layers.indices { layers[l] = arrange(layers[l], keys: barycenters(l, toward: nil), ranks: ranks, flip: flip) }
            } else if iteration.isMultiple(of: 2) {
                for l in 1..<layers.count {
                    layers[l] = arrange(layers[l], keys: barycenters(l, toward: l - 1), ranks: ranks, flip: flip)
                }
            } else {
                for l in stride(from: layers.count - 2, through: 0, by: -1) {
                    layers[l] = arrange(layers[l], keys: barycenters(l, toward: l + 1), ranks: ranks, flip: flip)
                }
            }
            transpose()
            ranks = groupRanks()
            let count = crossings()
            if count < bestCrossings {
                best = layers
                bestCrossings = count
                stale = 0
            } else {
                stale += 1
                if stale >= 12 { break }
            }
        }
        layers = best
    }

    /// Positions within each layer.
    var positions: [Int] {
        var result = Array(repeating: 0, count: vertices.count)
        for layer in layers { for (index, v) in layer.enumerated() { result[v] = index } }
        return result
    }

    // MARK: - Initial order

    private mutating func initialOrder(_ start: Start) {
        var key = Array(repeating: 0.0, count: vertices.count)
        if case .hints = start {
            // The author's rows, with dummies between their ends and fillers with their group.
            let rows = hints.map { $0?.y }
            for (v, vertex) in vertices.enumerated() {
                if let node = vertex.node {
                    key[v] = rows[node] ?? neighborRows(of: node, rows) ?? 0
                } else if let link = vertex.link {
                    let tail = links[link].tail, head = links[link].head
                    let a = rows[tail] ?? neighborRows(of: tail, rows) ?? 0
                    let b = rows[head] ?? neighborRows(of: head, rows) ?? a
                    let t = Double(vertex.layer - layer[tail]) / Double(max(1, layer[head] - layer[tail]))
                    key[v] = a + (b - a) * t
                }
            }
            for (v, vertex) in vertices.enumerated() {
                guard let group = vertex.filler else { continue }
                let members = ids.indices.filter { nodeGroup[$0].map { groupPath[$0].contains(group) } ?? false }
                key[v] = members.isEmpty ? 0 : members.map { key[$0] }.reduce(0, +) / Double(members.count)
            }
            for l in layers.indices {
                layers[l].sort { (key[$0], $0) < (key[$1], $1) }
            }
            let ranks = groupRanks()
            for l in layers.indices {
                var keys: [Int: Double] = [:]
                for (index, v) in layers[l].enumerated() { keys[v] = Double(index) }
                layers[l] = arrange(layers[l], keys: keys, ranks: ranks)
            }
        } else {
            // One end layer in manifest order (or reversed), then each layer by the barycenter of the
            // one before it.
            let (forward, reversed): (Bool, Bool) = switch start {
            case .forward(let r): (true, r)
            case .backward(let r): (false, r)
            case .hints: (true, false)
            }
            let ranks = groupRanks()
            let sequence = forward ? Array(layers.indices) : layers.indices.reversed()
            for (step, l) in sequence.enumerated() {
                if step == 0 {
                    var keys: [Int: Double] = [:]
                    for (index, v) in layers[l].enumerated() { keys[v] = Double(reversed ? -index : index) }
                    layers[l] = arrange(layers[l], keys: keys, ranks: ranks)
                } else {
                    layers[l] = arrange(layers[l], keys: barycenters(l, toward: forward ? l - 1 : l + 1), ranks: ranks)
                }
            }
        }
    }

    private func neighborRows(of node: Int, _ rows: [Double?]) -> Double? {
        let around = links.compactMap { link -> Double? in
            if link.from == node { return rows[link.to] }
            if link.to == node { return rows[link.from] }
            return nil
        }
        return around.isEmpty ? nil : around.reduce(0, +) / Double(around.count)
    }

    // MARK: - Sorting

    /// The mean normalized position of each vertex's neighbors in the adjacent layer `toward`.
    /// Vertices without neighbors there keep their place; fillers follow their group.
    private func barycenters(_ l: Int, toward side: Int?) -> [Int: Double] {
        guard let m = side else {
            // Both sides at once: the mean over every neighbour.
            let position = positions
            var keys: [Int: Double] = [:]
            let own = Double(max(1, layers[l].count))
            for v in layers[l] {
                let around = preds[v].map { (Double(position[$0]) + 0.5) / Double(max(1, layers[l - 1].count)) }
                    + succs[v].map { (Double(position[$0]) + 0.5) / Double(max(1, layers[l + 1].count)) }
                keys[v] = around.isEmpty ? (Double(position[v]) + 0.5) / own : around.reduce(0, +) / Double(around.count)
            }
            return keys
        }
        let position = positions
        let size = Double(max(1, layers[m].count)), own = Double(max(1, layers[l].count))
        var keys: [Int: Double] = [:]
        for v in layers[l] {
            let neighbors = m < l ? preds[v] : succs[v]
            if !neighbors.isEmpty {
                keys[v] = neighbors.map { (Double(position[$0]) + 0.5) / size }.reduce(0, +) / Double(neighbors.count)
            } else if let group = vertices[v].filler {
                let mates = layers[m].filter { path(of: $0).contains(group) }
                keys[v] = mates.isEmpty ? (Double(position[v]) + 0.5) / own
                    : mates.map { (Double(position[$0]) + 0.5) / size }.reduce(0, +) / Double(mates.count)
            } else {
                keys[v] = (Double(position[v]) + 0.5) / own
            }
        }
        return keys
    }

    private enum Item: Hashable { case vertex(Int), group(Int) }

    /// Sorts a layer by key while keeping every group's vertices contiguous (recursively), and puts
    /// sibling groups in their global order.
    private func arrange(_ layer: [Int], keys: [Int: Double], ranks: [Int: Double], flip: Bool = false) -> [Int] {
        var children: [Int: [Item]] = [:]       // -1 is the root
        var seen: Set<Int> = []
        var sum: [Int: Double] = [:], count: [Int: Double] = [:]
        var first: [Item: Int] = [:]
        for (index, v) in layer.enumerated() {
            var parent = -1
            for group in path(of: v) {
                if seen.insert(group).inserted {
                    children[parent, default: []].append(.group(group))
                    first[.group(group)] = index
                }
                sum[group, default: 0] += keys[v] ?? 0
                count[group, default: 0] += 1
                parent = group
            }
            children[parent, default: []].append(.vertex(v))
            first[.vertex(v)] = index
        }
        func key(_ item: Item) -> Double {
            switch item {
            case .vertex(let v): keys[v] ?? 0
            case .group(let g): sum[g, default: 0] / max(1, count[g, default: 1])
            }
        }
        func flatten(_ container: Int) -> [Int] {
            let tie = flip ? -1 : 1
            var items = (children[container] ?? []).sorted {
                (key($0), (first[$0] ?? 0) * tie) < (key($1), (first[$1] ?? 0) * tie)
            }
            let slots = items.indices.filter { if case .group = items[$0] { true } else { false } }
            let ordered = slots.map { items[$0] }.sorted { a, b in
                guard case .group(let x) = a, case .group(let y) = b else { return false }
                return (ranks[x] ?? 0, x) < (ranks[y] ?? 0, y)
            }
            for (slot, item) in zip(slots, ordered) { items[slot] = item }
            return items.flatMap { item -> [Int] in
                switch item {
                case .vertex(let v): [v]
                case .group(let g): flatten(g)
                }
            }
        }
        return flatten(-1)
    }

    /// Each group's mean normalized position over all layers: the order sibling groups keep everywhere.
    private func groupRanks() -> [Int: Double] {
        let position = positions
        var sum: [Int: Double] = [:], count: [Int: Double] = [:]
        for layer in layers {
            let size = Double(max(1, layer.count))
            for v in layer {
                for group in path(of: v) {
                    sum[group, default: 0] += (Double(position[v]) + 0.5) / size
                    count[group, default: 0] += 1
                }
            }
        }
        return sum.reduce(into: [:]) { $0[$1.key] = $1.value / count[$1.key, default: 1] }
    }

    // MARK: - Crossings

    /// Swaps neighbours while that removes crossings: two vertices in the same group, or a vertex and
    /// an adjacent group block (a whole group moves past it). Sibling groups keep their order.
    private mutating func transpose() {
        for _ in 0..<8 {
            var improved = false
            for l in layers.indices where layers[l].count > 1 {
                var i = 0
                while i < layers[l].count - 1 {
                    defer { i += 1 }
                    let layer = layers[l]
                    // The items meeting at i | i+1: the deepest containers that differ.
                    let pa = path(of: layer[i]), pb = path(of: layer[i + 1])
                    var shared = 0
                    while shared < pa.count && shared < pb.count && pa[shared] == pb[shared] { shared += 1 }
                    let left = shared < pa.count ? pa[shared] : nil, right = shared < pb.count ? pb[shared] : nil
                    if left != nil && right != nil { continue }      // two groups: global order decides
                    func extent(_ group: Int?, from index: Int, step: Int) -> Int {
                        guard let group else { return index }
                        var j = index
                        while j + step >= 0 && j + step < layer.count && path(of: layer[j + step]).contains(group) { j += step }
                        return j
                    }
                    let start = extent(left, from: i, step: -1), end = extent(right, from: i + 1, step: 1)
                    let candidate = Array(layer[..<start]) + Array(layer[(i + 1)...end]) + Array(layer[start...i]) + Array(layer[(end + 1)...])
                    let before = localCrossings(l)
                    layers[l] = candidate
                    if localCrossings(l) < before {
                        improved = true
                    } else {
                        layers[l] = layer
                    }
                }
            }
            if !improved { break }
        }
    }

    /// Crossings on both sides of layer `l`.
    private func localCrossings(_ l: Int) -> Int {
        let position = positions
        var total = 0
        for m in [l - 1, l] where m >= 0 && m + 1 < layers.count {
            total += crossings(between: m, position)
        }
        return total
    }

    /// Edge crossings between adjacent layers for the current order.
    func crossings() -> Int {
        let position = positions
        return layers.indices.dropLast().reduce(0) { $0 + crossings(between: $1, position) }
    }

    private func crossings(between l: Int, _ position: [Int]) -> Int {
        var segments: [(Int, Int)] = []
        for u in layers[l] { for v in succs[u] { segments.append((position[u], position[v])) } }
        var total = 0
        for i in segments.indices {
            for j in (i + 1)..<segments.count {
                let (a, b) = segments[i], (c, d) = segments[j]
                if (a < c && b > d) || (a > c && b < d) { total += 1 }
            }
        }
        return total
    }
}
