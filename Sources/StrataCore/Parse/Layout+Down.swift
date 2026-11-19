import Foundation

/// What only a top-to-bottom layout does (docs/manifest.md, Layout). Read top to bottom, a map is a spine of
/// steps with what each step talks to beside it, and the stores everything shares along the bottom:
///
/// - **Side nodes.** A store or external API that one caller alone uses sits in its caller's row, next to
///   it, joined by a level edge. A caller keeps at most two this way, one each side; with more they fan
///   out in the row below. A side node shares its caller's groups or sits just outside them, and when
///   ordering leaves a card between the two it goes back to the row below.
/// - **Shared stores at the bottom.** A store or external API that callers in different rows use goes to
///   the last row, with its group if every other member of the group goes too.
/// - **Rows.** The gap under a row makes room for the group bands that close under it and open over the
///   next row, for the pills of the edges crossing it, and for gentle S-bends.
extension LayeredGraph {
    static let leafKinds: Set<NodeKind> = dataKinds.union([.external])
    /// The least room between two rows for the edges that cross it.
    static let rowGap: Double = 64

    // MARK: - Layers

    /// Moves stores and external APIs called from more than one row to `deepest`, the last row.
    mutating func sinkSharedStores(deepest: Int, preds: [[Int]], succs: [[Int]]) {
        let shared = Set(ids.indices.filter { v in
            Self.leafKinds.contains(kinds[v]) && succs[v].isEmpty && hints[v] == nil && Set(preds[v].map { layer[$0] }).count > 1
        })
        for v in shared.sorted() {
            if let group = nodeGroup[v] {
                let outer = groupPath[group][0]
                let members = ids.indices.filter { nodeGroup[$0].map { groupPath[$0].contains(outer) } ?? false }
                guard members.allSatisfy(shared.contains) else { continue }
            }
            layer[v] = deepest
        }
    }

    /// The nodes that can sit beside their caller, by caller: unhinted stores and external APIs without
    /// successors whose one caller is in the same groups or deeper ones, at most two per caller.
    func sideCandidates(preds: [[Int]], succs: [[Int]], except excluded: Set<Int> = []) -> [Int: [Int]] {
        func groups(_ v: Int) -> [Int] { nodeGroup[v].map { groupPath[$0] } ?? [] }
        var byCaller: [Int: [Int]] = [:]
        for v in ids.indices where Self.leafKinds.contains(kinds[v]) && succs[v].isEmpty && hints[v] == nil && !excluded.contains(v) {
            let callers = Set(preds[v])
            guard callers.count == 1, let caller = callers.first else { continue }
            let own = groups(v), theirs = groups(caller)
            guard own.count <= theirs.count, Array(theirs.prefix(own.count)) == own else { continue }
            byCaller[caller, default: []].append(v)
        }
        return byCaller.filter { $0.value.count <= 2 }
    }

    /// Picks the side nodes and moves each into its caller's layer. `excluded` stay in the layer below.
    mutating func placeSides(except excluded: Set<Int> = []) {
        var preds = Array(repeating: [Int](), count: ids.count), succs = preds
        for link in links {
            succs[link.tail].append(link.head)
            preds[link.head].append(link.tail)
        }
        sideOf = [:]
        for (caller, sides) in sideCandidates(preds: preds, succs: succs, except: excluded) {
            for side in sides {
                layer[side] = layer[caller]
                sideOf[side] = caller
            }
        }
        flat = Set(links.indices.filter { sideOf[links[$0].head] == links[$0].tail || sideOf[links[$0].tail] == links[$0].head })
        let used = Array(Set(layer)).sorted()
        let compact = Dictionary(uniqueKeysWithValues: used.enumerated().map { ($0.element, $0.offset) })
        layer = layer.map { compact[$0]! }
    }

    // MARK: - Order

    /// Puts each side node into its caller's layer once the layers are ordered: right next to the caller
    /// when it shares the caller's groups, otherwise just outside the caller's groups it is not in. A lone
    /// side node takes the open end of the row when the caller is at one; two take a side each.
    mutating func insertSides() {
        guard !sideOf.isEmpty else { return }
        let byCaller = Dictionary(grouping: sideOf.keys.sorted()) { sideOf[$0]! }
        for caller in byCaller.keys.sorted() {
            let l = layer[caller]
            var taken: Set<Bool> = []          // true: the right side
            for side in byCaller[caller]! {
                let own = path(of: side), theirs = path(of: caller)
                let row = layers[l]
                var start = position[caller], end = position[caller]
                if theirs.count > own.count {
                    let outer = theirs[own.count]
                    while start > 0 && path(of: row[start - 1]).contains(outer) { start -= 1 }
                    while end + 1 < row.count && path(of: row[end + 1]).contains(outer) { end += 1 }
                }
                var left = start == position[caller] && !taken.contains(false)
                var right = end == position[caller] && !taken.contains(true)
                // The end of the caller's block (or of the row) it is nearer is likely the near edge of its
                // groups' region and of the diagram: a lone side node goes there.
                let toEnd = end - position[caller], toStart = position[caller] - start
                let nearRight = toEnd != toStart ? toEnd < toStart : row.count - 1 - end <= start
                // Outside the caller's groups, the caller may move to the edge of its block (the near one
                // first) when that crosses no more edges.
                if theirs.count > own.count {
                    for toward in [nearRight, !nearRight] where !taken.contains(toward) {
                        if toward ? right : left { break }
                        guard let edge = moveToEdge(caller, outside: own.count, right: toward) else { continue }
                        (start, end) = (edge, edge)
                        (left, right) = (!toward, toward)
                        break
                    }
                }
                let count = layers[l].count
                let toRight: Bool
                if left && right {
                    toRight = taken.isEmpty ? count - 1 - end <= start : !taken.contains(true)
                } else if left || right {
                    toRight = right
                } else {
                    toRight = taken.isEmpty ? nearRight : !taken.contains(true)
                }
                taken.insert(toRight)
                layers[l].insert(side, at: toRight ? end + 1 : start)
                reindex(l)
            }
        }
    }

    /// Moves `caller` to one end of the block of its groups from depth `depth` down, in its layer, past
    /// vertices of its own groups only (sibling groups keep their order). Returns the caller's new
    /// position, or nil when that is impossible or would cross more edges than the side node's edge
    /// would cross on its way past those vertices.
    private mutating func moveToEdge(_ caller: Int, outside depth: Int, right: Bool) -> Int? {
        let l = layer[caller], before = layers[l]
        var crossed = crossings()
        let groups = path(of: caller)
        var row = before
        var item = position[caller]...position[caller]       // the block holding the caller, growing outward
        for level in stride(from: groups.count - 1, through: depth, by: -1) {
            let group = groups[level]
            var start = item.lowerBound, end = item.upperBound
            while start > 0 && path(of: row[start - 1]).contains(group) { start -= 1 }
            while end + 1 < row.count && path(of: row[end + 1]).contains(group) { end += 1 }
            let passed = right ? Array((item.upperBound + 1)..<(end + 1)) : Array(start..<item.lowerBound)
            guard passed.allSatisfy({ path(of: row[$0]).count == level + 1 }) else { return nil }
            crossed += passed.filter { vertices[row[$0]].isDummy }.count
            let block = Array(row[item])
            row.removeSubrange(item)
            let at = right ? end - block.count + 1 : start
            row.insert(contentsOf: block, at: at)
            item = start...end
        }
        layers[l] = row
        reindex(l)
        guard crossings() <= crossed else {
            layers[l] = before
            reindex(l)
            return nil
        }
        return position[caller]
    }

    /// Side nodes with a card between them and their caller.
    func strandedSides() -> Set<Int> {
        var result: Set<Int> = []
        for (side, caller) in sideOf {
            let row = layers[layer[side]]
            let a = min(position[side], position[caller]), b = max(position[side], position[caller])
            if row[(a + 1)..<b].contains(where: { vertices[$0].node != nil }) { result.insert(side) }
        }
        return result
    }

    // MARK: - Coordinates

    /// Moves each side node up against its neighbour toward the caller: alignment leaves it wherever its
    /// layer had room.
    func pinSides(_ aligned: [Double]) -> [Double] {
        guard !sideOf.isEmpty else { return aligned }
        var y = aligned
        let sides = sideOf.keys.sorted { a, b in
            (abs(position[a] - position[sideOf[a]!]), a) < (abs(position[b] - position[sideOf[b]!]), b)
        }
        for side in sides {
            let caller = sideOf[side]!
            let row = layers[layer[side]]
            let step = position[caller] > position[side] ? 1 : -1
            var i = position[side] + step
            while vertices[row[i]].isFiller { i += step }
            let neighbor = row[i]
            y[side] = step == 1 ? y[neighbor] - separation(side, neighbor) : y[neighbor] + separation(neighbor, side)
        }
        return y
    }

    /// Room between a side node and its caller for the pill on the edge between them.
    func sideGap(_ a: Int, _ b: Int) -> Double {
        guard !sideOf.isEmpty, let na = vertices[a].node, let nb = vertices[b].node,
              sideOf[na] == nb || sideOf[nb] == na else { return 0 }
        let label = flat.filter { Set([links[$0].from, links[$0].to]) == Set([na, nb]) }.map { links[$0].label }.max() ?? 0
        return label > 0 ? min(label, 160) + 24 : 0
    }

    /// The top of every row (in the layout frame, the start of every layer).
    func rowOffsets(_ y: [Double]) -> [Double] {
        let plain = LayoutMetrics.cardHeight
        var overhang = Array(repeating: 0.0, count: layers.count)   // taller cards reach above and below their row
        var span: [Int: ClosedRange<Int>] = [:]
        for vertex in vertices {
            guard let node = vertex.node else { continue }
            overhang[vertex.layer] = max(overhang[vertex.layer], (heights[node] - plain) / 2)
            for group in nodeGroup[node].map({ groupPath[$0] }) ?? [] {
                span[group] = span[group].map { min($0.lowerBound, vertex.layer)...max($0.upperBound, vertex.layer) }
                    ?? vertex.layer...vertex.layer
            }
        }
        // The most group bands a card of `row` has toward `other`: groups it is in that do not reach there.
        func bands(_ row: Int, toward other: Int) -> Double {
            Double(layers[row].filter { vertices[$0].node != nil }.map { v in
                path(of: v).filter { !(span[$0]?.contains(other) ?? false) }.count
            }.max() ?? 0)
        }
        var top = [0.0]
        for l in layers.indices.dropLast() {
            let groups = bands(l, toward: l + 1) * LayoutMetrics.groupBottom + bands(l + 1, toward: l) * LayoutMetrics.groupTop
            var travel = 0.0
            var pills: [(lo: Double, hi: Double)] = []
            for (index, link) in links.enumerated() where !flat.contains(index) {
                let chain = chains[index]
                for (a, b) in zip(chain, chain.dropFirst()) where vertices[a].layer == l {
                    travel = max(travel, abs(y[a] - y[b]))
                    if chain.count == 2 && link.label > 0 {
                        let middle = (y[a] + y[b]) / 2, half = min(link.label, 160) / 2
                        pills.append((middle - half, middle + half))
                    }
                }
            }
            let edges = max(Self.rowGap, 28 + 22 * Double(Self.stack(pills)), 46 + min(64, travel * 0.08))
            top.append(top[l] + plain + overhang[l] + groups + edges + overhang[l + 1])
        }
        return top
    }

    /// The most intervals that overlap at one point.
    static func stack(_ intervals: [(lo: Double, hi: Double)]) -> Int {
        let events = intervals.flatMap { [($0.lo, 1), ($0.hi, -1)] }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
        var open = 0, most = 0
        for (_, change) in events {
            open += change
            most = max(most, open)
        }
        return most
    }
}
