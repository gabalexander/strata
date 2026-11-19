import Foundation

/// Ordering within layers: barycenter sweeps down and up, each followed by transposition, keeping the
/// order with the fewest crossings. Sorting is hierarchical, so a group's members (and its nested
/// groups) stay contiguous in every layer, and sibling groups keep one order across all layers so
/// their regions never interleave.
extension LayeredGraph {
    enum Start { case hints, forward(reversed: Bool), backward(reversed: Bool) }

    /// Several deterministic starts (the author's hint rows first, then sweeps from either side, in
    /// manifest order and reversed); the order with the fewest crossings wins, the earlier on a tie.
    mutating func orderLayers() {
        let base = layers
        let hinted = hints.filter { $0 != nil }.count
        let starts: [Start] = (hinted > 0 && hinted * 2 >= ids.count ? [.hints] : [])
            + [.forward(reversed: false), .backward(reversed: false), .forward(reversed: true)]
        var best = base, bestCrossings = Int.max
        for start in starts {
            layers = base
            for l in layers.indices { reindex(l) }
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
        for l in layers.indices { reindex(l) }
    }

    private mutating func reduceCrossings() {
        var ranks = groupRanks()
        var best = layers
        var bestCrossings = crossings()
        var stale = 0
        // Sweeps alternate direction and how ties break; later rounds look both ways at once.
        for iteration in 0..<28 where layers.count > 1 && bestCrossings > 0 {
            let flip = (iteration / 2) % 2 == 1
            if iteration >= 20 {
                for l in layers.indices { order(l, toward: nil, ranks: ranks, flip: flip) }
            } else if iteration % 2 == 0 {
                for l in 1..<layers.count { order(l, toward: l - 1, ranks: ranks, flip: flip) }
            } else {
                for l in stride(from: layers.count - 2, through: 0, by: -1) { order(l, toward: l + 1, ranks: ranks, flip: flip) }
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
                if stale >= 6 { break }
            }
        }
        layers = best
        for l in layers.indices { reindex(l) }
    }

    private mutating func order(_ l: Int, toward side: Int?, ranks: [Double], flip: Bool) {
        layers[l] = arrange(layers[l], keys: barycenters(l, toward: side), ranks: ranks, flip: flip)
        reindex(l)
    }

    // MARK: - Initial order

    private mutating func initialOrder(_ start: Start) {
        if case .hints = start {
            // The author's rows, with dummies between their ends and fillers with their group.
            var key = Array(repeating: 0.0, count: vertices.count)
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
                reindex(l)
            }
            let ranks = groupRanks()
            for l in layers.indices {
                var keys = Array(repeating: 0.0, count: vertices.count)
                for (index, v) in layers[l].enumerated() { keys[v] = Double(index) }
                layers[l] = arrange(layers[l], keys: keys, ranks: ranks)
                reindex(l)
            }
            return
        }
        // One end layer in manifest order (or reversed), then each layer by the barycenter of the one
        // before it.
        let (forward, reversed): (Bool, Bool) = switch start {
        case .forward(let r): (true, r)
        case .backward(let r): (false, r)
        case .hints: (true, false)
        }
        let ranks = groupRanks()
        let sequence = forward ? Array(layers.indices) : layers.indices.reversed()
        for (step, l) in sequence.enumerated() {
            if step == 0 {
                var keys = Array(repeating: 0.0, count: vertices.count)
                for (index, v) in layers[l].enumerated() { keys[v] = Double(reversed ? -index : index) }
                layers[l] = arrange(layers[l], keys: keys, ranks: ranks)
                reindex(l)
            } else {
                order(l, toward: forward ? l - 1 : l + 1, ranks: ranks, flip: false)
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

    /// The mean normalized position of each vertex's neighbours in the adjacent layer `side` (both
    /// sides when nil). Vertices without neighbours there keep their place; fillers follow their group.
    private func barycenters(_ l: Int, toward side: Int?) -> [Double] {
        var keys = Array(repeating: 0.0, count: vertices.count)
        let own = Double(max(1, layers[l].count))
        func normalized(_ v: Int) -> Double { (Double(position[v]) + 0.5) / Double(max(1, layers[vertices[v].layer].count)) }
        for v in layers[l] {
            var sum = 0.0, count = 0.0
            if side == nil || side == l - 1 { for p in preds[v] { sum += normalized(p); count += 1 } }
            if side == nil || side == l + 1 { for s in succs[v] { sum += normalized(s); count += 1 } }
            if count > 0 {
                keys[v] = sum / count
            } else if let group = vertices[v].filler, let m = side {
                for u in layers[m] where path(of: u).contains(group) { sum += normalized(u); count += 1 }
                keys[v] = count > 0 ? sum / count : (Double(position[v]) + 0.5) / own
            } else {
                keys[v] = (Double(position[v]) + 0.5) / own
            }
        }
        return keys
    }

    private enum Item: Hashable { case vertex(Int), group(Int) }

    /// Sorts a layer by key while keeping every group's vertices contiguous (recursively), and puts
    /// sibling groups in their global order.
    private func arrange(_ layer: [Int], keys: [Double], ranks: [Double], flip: Bool = false) -> [Int] {
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
                sum[group, default: 0] += keys[v]
                count[group, default: 0] += 1
                parent = group
            }
            children[parent, default: []].append(.vertex(v))
            first[.vertex(v)] = index
        }
        func key(_ item: Item) -> Double {
            switch item {
            case .vertex(let v): keys[v]
            case .group(let g): sum[g, default: 0] / max(1, count[g, default: 1])
            }
        }
        let tie = flip ? -1 : 1
        func flatten(_ container: Int) -> [Int] {
            var items = (children[container] ?? []).sorted {
                (key($0), (first[$0] ?? 0) * tie) < (key($1), (first[$1] ?? 0) * tie)
            }
            let slots = items.indices.filter { if case .group = items[$0] { true } else { false } }
            let ordered = slots.map { items[$0] }.sorted { a, b in
                guard case .group(let x) = a, case .group(let y) = b else { return false }
                return (ranks[x], x) < (ranks[y], y)
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
    private func groupRanks() -> [Double] {
        var sum = Array(repeating: 0.0, count: groupIDs.count), count = sum
        for layer in layers {
            let size = Double(max(1, layer.count))
            for v in layer {
                for group in path(of: v) {
                    sum[group] += (Double(position[v]) + 0.5) / size
                    count[group] += 1
                }
            }
        }
        return groupIDs.indices.map { count[$0] > 0 ? sum[$0] / count[$0] : 0 }
    }

    // MARK: - Crossings

    /// Swaps neighbours while that removes crossings: two vertices in the same group, or a vertex and
    /// an adjacent group block (the whole group moves past it). Sibling groups keep their order.
    /// Only crossings between the two swapped items can change, so only those are counted.
    private mutating func transpose() {
        for _ in 0..<6 {
            var improved = false
            for l in layers.indices where layers[l].count > 1 {
                var i = 0
                while i < layers[l].count - 1 {
                    defer { i += 1 }
                    let layer = layers[l]
                    let pa = path(of: layer[i]), pb = path(of: layer[i + 1])
                    var shared = 0
                    while shared < pa.count && shared < pb.count && pa[shared] == pb[shared] { shared += 1 }
                    let left = shared < pa.count ? pa[shared] : nil, right = shared < pb.count ? pb[shared] : nil
                    if left != nil && right != nil { continue }      // two groups: their global order decides
                    var start = i, end = i + 1
                    if let left { while start > 0 && path(of: layer[start - 1]).contains(left) { start -= 1 } }
                    if let right { while end + 1 < layer.count && path(of: layer[end + 1]).contains(right) { end += 1 } }
                    let upper = Array(layer[start...i]), lower = Array(layer[(i + 1)...end])
                    if crossings(above: lower, below: upper) < crossings(above: upper, below: lower) {
                        layers[l] = Array(layer[..<start]) + lower + upper + Array(layer[(end + 1)...])
                        reindex(l)
                        improved = true
                        i = start + lower.count - 1
                    }
                }
            }
            if !improved { break }
        }
    }

    /// Crossings between the edges of two neighbouring runs of vertices when `above` sits on top.
    private func crossings(above: [Int], below: [Int]) -> Int {
        var total = 0
        for neighbors in [preds, succs] {
            for a in above {
                for x in neighbors[a] {
                    for b in below {
                        for y in neighbors[b] where position[x] > position[y] { total += 1 }
                    }
                }
            }
        }
        return total
    }

    /// Edge crossings between adjacent layers for the current order.
    func crossings() -> Int {
        var total = 0
        var segments: [(Int, Int)] = []
        for l in layers.indices.dropLast() {
            segments.removeAll(keepingCapacity: true)
            for u in layers[l] { for v in succs[u] { segments.append((position[u], position[v])) } }
            for i in segments.indices {
                let (a, b) = segments[i]
                for j in (i + 1)..<segments.count {
                    let (c, d) = segments[j]
                    if (a < c && b > d) || (a > c && b < d) { total += 1 }
                }
            }
        }
        return total
    }
}
