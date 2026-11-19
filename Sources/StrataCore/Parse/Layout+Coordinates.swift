import Foundation

/// Sizes and gaps in the layout frame, where layers follow each other along x and a layer's vertices
/// stack along y. Left to right that is the stage's frame; top to bottom it is the stage transposed, so
/// a card is as deep as it is tall and as broad as it is wide, and the gaps differ to match.
struct LayoutFrame {
    let down: Bool
    init(_ direction: FlowDirection) { down = direction == .down }

    /// A card's extent across its layer: its height (64, or 80 with chips) in a column, its width in a row.
    func breadth(_ height: Double) -> Double { down ? LayoutMetrics.cardWidth : height }
    /// Room between neighbouring cards of a layer.
    var cardGap: Double { down ? 56 : LayoutMetrics.row - LayoutMetrics.cardHeight }
    /// The least distance between the centres of two cards in a layer.
    var pitch: Double { down ? LayoutMetrics.cardWidth + cardGap : LayoutMetrics.row }
    /// A group region's padding across a layer, before its members (above in a column, left in a row)
    /// and after them.
    var padBefore: Double { down ? LayoutMetrics.groupSide : LayoutMetrics.groupTop }
    var padAfter: Double { down ? LayoutMetrics.groupSide : LayoutMetrics.groupBottom }
}

/// Coordinates: Brandes–Köpf places every layer's vertices so each lines up with a median neighbour
/// (straight main flows, straight long edges); a separation solver then moves them as little as
/// possible so group regions keep their padding and never cover a non-member; channels between
/// layers widen for the labels that sit in them; notes go to a free corner.
extension LayeredGraph {
    static let boxMargin: Double = 22
    private static let minimumChannel: Double = 100
    private static let maximumChannel: Double = 236

    func coordinates() -> AutoLayout.Result {
        let order = layers.map { $0.filter { !vertices[$0].isFiller } }
        // Brandes–Köpf's balanced placement, or one of its four alignments when that keeps more of
        // the main flow straight once groups are accounted for.
        let candidates = brandesKoepf(order).map(pinSides).map(project)
        let scores = candidates.map(straightness)
        let y = candidates[scores.indices.max { (scores[$0], -$0) < (scores[$1], -$1) }!]
        let x = frame.down ? rowOffsets(y) : layerOffsets(y)

        // Grid points name a plain card's corner; a taller card (component chips) is drawn centred on it.
        // Top to bottom, the frame is transposed back: a layer's offset is a row's top.
        var rects: [String: CGRect] = [:]
        var drawn: [String: CGRect] = [:]
        for (v, vertex) in vertices.enumerated() {
            guard let node = vertex.node else { continue }
            let rect = frame.down
                ? CGRect(x: y[v] - LayoutMetrics.cardWidth / 2, y: x[vertex.layer],
                         width: LayoutMetrics.cardWidth, height: LayoutMetrics.cardHeight)
                : CGRect(x: x[vertex.layer], y: y[v] - LayoutMetrics.cardHeight / 2,
                         width: LayoutMetrics.cardWidth, height: LayoutMetrics.cardHeight)
            rects[ids[node]] = rect
            drawn[ids[node]] = rect.insetBy(dx: 0, dy: -(heights[node] - LayoutMetrics.cardHeight) / 2)
        }
        let regions = groupRegions(drawn)
        let all = rects.merging(noteRects(cards: drawn, regions: regions)) { a, _ in a }
        let minX = all.values.map(\.minX).min() ?? 0, minY = all.values.map(\.minY).min() ?? 0
        var via: [String: [GridPoint]] = [:]
        for (index, link) in links.enumerated() where chains[index].count > 2 {
            let points = chains[index].dropFirst().dropLast().map { v in
                frame.down
                    ? GridPoint(Self.unit((y[v] - minX) / LayoutMetrics.column), Self.unit((x[vertices[v].layer] - minY) / LayoutMetrics.row))
                    : GridPoint(Self.unit((x[vertices[v].layer] - minX) / LayoutMetrics.column), Self.unit((y[v] - minY) / LayoutMetrics.row))
            }
            via[link.id] = link.reversed ? points.reversed() : points
        }
        return AutoLayout.Result(positions: Self.grid(all), via: via, issues: issues)
    }

    private static func unit(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }

    /// Notes alone (a level with no diagram nodes): side by side.
    func placeNotes(cards: [String: CGRect], regions: [CGRect]) -> [String: GridPoint] {
        Self.grid(noteRects(cards: cards, regions: regions))
    }

    private static func grid(_ rects: [String: CGRect]) -> [String: GridPoint] {
        let minX = rects.values.map(\.minX).min() ?? 0, minY = rects.values.map(\.minY).min() ?? 0
        return rects.mapValues { r in
            GridPoint(unit((r.minX - minX) / LayoutMetrics.column), unit((r.minY - minY) / LayoutMetrics.row))
        }
    }

    // MARK: - Separation

    /// The distance between the centres of `a` (above) and `b` (below), neighbours in one layer.
    func separation(_ a: Int, _ b: Int) -> Double {
        let pa = path(of: a), pb = path(of: b)
        var shared = 0
        while shared < pa.count && shared < pb.count && pa[shared] == pb[shared] { shared += 1 }
        let exits = pa.count - shared, enters = pb.count - shared
        let da = vertices[a].isDummy, db = vertices[b].isDummy
        var gap = da && db ? 18 : da || db ? 26 : frame.cardGap
        if exits + enters > 0 {
            gap = max(gap, Double(exits) * frame.padAfter + Double(enters) * frame.padBefore + Self.boxMargin)
        }
        gap = max(gap, sideGap(a, b))
        return vertices[a].breadth / 2 + gap + vertices[b].breadth / 2
    }

    /// Separations across layers that keep groups in bands: wherever a group's block meets something
    /// above or below it in a layer, that neighbour clears every member of the group, in every layer.
    func bandSeparations() -> [(upper: Int, lower: Int, gap: Double)] {
        var members: [Int: [Int]] = [:]
        for (v, vertex) in vertices.enumerated() where !vertex.isFiller {
            for group in path(of: v) { members[group, default: []].append(v) }
        }
        func side(_ v: Int, _ group: Int?, _ shared: Int) -> (vertices: [Int], depth: (Int) -> Int) {
            guard let group else { return ([v], { _ in 0 }) }
            return (members[group] ?? [], { self.path(of: $0).count - shared })
        }
        var result: [(Int, Int, Double)] = []
        var seen: Set<[Int]> = []
        for layer in layers {
            for (a, b) in zip(layer, layer.dropFirst()) {
                let pa = path(of: a), pb = path(of: b)
                var shared = 0
                while shared < pa.count && shared < pb.count && pa[shared] == pb[shared] { shared += 1 }
                let upperGroup = shared < pa.count ? pa[shared] : nil, lowerGroup = shared < pb.count ? pb[shared] : nil
                guard upperGroup != nil || lowerGroup != nil else { continue }
                let upper = side(a, upperGroup, shared), lower = side(b, lowerGroup, shared)
                for u in upper.vertices {
                    for l in lower.vertices where seen.insert([u, l]).inserted {
                        let gap = vertices[u].breadth / 2 + Double(upper.depth(u)) * frame.padAfter + Self.boxMargin
                            + Double(lower.depth(l)) * frame.padBefore + vertices[l].breadth / 2
                        result.append((u, l, gap))
                    }
                }
            }
        }
        return result
    }

    // MARK: - Brandes–Köpf

    /// How much of the flow runs straight: each edge drawn level counts, more when much of the
    /// diagram lies downstream of it.
    private func straightness(_ y: [Double]) -> Double {
        var reach = Array(repeating: 0, count: ids.count)
        var downstream: [Int: Set<Int>] = [:]
        for v in (0..<ids.count).sorted(by: { rank[$0] > rank[$1] }) {
            var seen: Set<Int> = []
            for link in links where link.tail == v {
                seen.insert(link.head)
                seen.formUnion(downstream[link.head] ?? [])
            }
            downstream[v] = seen
            reach[v] = seen.count
        }
        var score = 0.0
        for (index, link) in links.enumerated() {
            let chain = chains[index]
            guard !chain.isEmpty, zip(chain, chain.dropFirst()).allSatisfy({ abs(y[$0] - y[$1]) < 0.5 }) else { continue }
            score += 1 + 0.25 * Double(min(4, reach[link.head]))
        }
        // The spine runs straight in every candidate it can; one bent by groups reads worst.
        if let first = spine.first, spine.contains(where: { abs(y[$0] - y[first]) > 0.5 }) { score -= 1_000 }
        // Tall, stepped placements read worse than compact ones with a bend.
        let cards = vertices.indices.filter { vertices[$0].node != nil }
        let height = (cards.map { y[$0] }.max() ?? 0) - (cards.map { y[$0] }.min() ?? 0)
        score -= 0.6 * height / frame.pitch
        // A node fanning out to (or in from) three or more reads best centred on its fan.
        for v in cards {
            for fan in [succs[v], preds[v]] where fan.count >= 3 {
                let ys = fan.map { y[$0] }.sorted()
                let middle = ys.count % 2 == 1 ? ys[ys.count / 2] : (ys[ys.count / 2 - 1] + ys[ys.count / 2]) / 2
                score -= 2.5 * abs(y[v] - middle) / frame.pitch
            }
        }
        return score
    }

    /// The balanced placement first, then the four alignments (up-left, up-right, down-left, down-right).
    private func brandesKoepf(_ order: [[Int]]) -> [[Double]] {
        let count = vertices.count
        var position = Array(repeating: 0, count: count)
        for layer in order { for (index, v) in layer.enumerated() { position[v] = index } }
        func pair(_ a: Int, _ b: Int) -> Int { min(a, b) * count + max(a, b) }

        // Type 1 conflicts: a non-inner segment crossing an inner (dummy to dummy) segment loses.
        var conflicts: Set<Int> = []
        for l in order.indices.dropFirst() {
            let previous = order[l - 1], layer = order[l]
            var k0 = 0, scan = 0
            for (i, v) in layer.enumerated() {
                let inner = vertices[v].isDummy ? preds[v].first { vertices[$0].isDummy } : nil
                let k1 = inner.map { position[$0] } ?? previous.count
                guard inner != nil || i == layer.count - 1 else { continue }
                for s in layer[scan...i] {
                    for u in preds[s] where !(vertices[u].isDummy && vertices[s].isDummy) {
                        if position[u] < k0 || k1 < position[u] { conflicts.insert(pair(u, s)) }
                    }
                }
                scan = i + 1
                k0 = k1
            }
        }

        let bands = bandSeparations()
        var results: [[Double]] = []
        for up in [true, false] {
            for left in [true, false] {
                var layering = up ? order : order.reversed()
                if !left { layering = layering.map { $0.reversed() } }
                let (root, align) = verticalAlignment(layering, neighbors: up ? preds : succs, conflicts: conflicts, pair: pair,
                                                      partner: up ? spineAbove : spineBelow)
                var xs = compaction(layering, root: root, align: align, reversed: !left, bands: bands)
                if !left { xs = xs.map { -$0 } }
                results.append(xs)
            }
        }

        let members = order.flatMap { $0 }
        guard !members.isEmpty else { return [Array(repeating: 0, count: count)] }
        func extent(_ xs: [Double]) -> (Double, Double) {
            (members.map { xs[$0] - vertices[$0].breadth / 2 }.min()!, members.map { xs[$0] + vertices[$0].breadth / 2 }.max()!)
        }
        let narrowest = results.indices.min { a, b in
            let (a0, a1) = extent(results[a]), (b0, b1) = extent(results[b])
            return (a1 - a0, a) < (b1 - b0, b)
        }!
        let target = results[narrowest]
        let targetMin = members.map { target[$0] }.min()!, targetMax = members.map { target[$0] }.max()!
        for index in results.indices where index != narrowest {
            let xs = results[index]
            let delta = index.isMultiple(of: 2) ? targetMin - members.map { xs[$0] }.min()! : targetMax - members.map { xs[$0] }.max()!
            results[index] = xs.map { $0 + delta }
        }
        var balanced = Array(repeating: 0.0, count: count)
        for v in members {
            let values = results.map { $0[v] }.sorted()
            balanced[v] = (values[1] + values[2]) / 2
        }
        return [balanced] + results
    }

    /// Each vertex joins the block of a median neighbour in the layer before (in `layering` order). The
    /// spine (`partner`: a spine vertex's neighbour on the spine in that layer) is one block whatever
    /// else wants its vertices, and nothing aligns across it.
    private func verticalAlignment(_ layering: [[Int]], neighbors: [[Int]], conflicts: Set<Int>,
                                   pair: (Int, Int) -> Int, partner: [Int: Int] = [:]) -> (root: [Int], align: [Int]) {
        var root = Array(vertices.indices), align = Array(vertices.indices)
        var position = Array(repeating: 0, count: vertices.count)
        for layer in layering { for (index, v) in layer.enumerated() { position[v] = index } }
        let reserved = Set(partner.values)
        for layer in layering {
            var previous = -1
            let spine = partner.isEmpty ? nil : layer.first { partner[$0] != nil }
            var fence = spine.map { position[partner[$0]!] } ?? Int.max
            for v in layer {
                if v == spine, let w = partner[v] {
                    align[w] = v
                    root[v] = root[w]
                    align[v] = root[v]
                    previous = position[w]
                    fence = Int.max
                    continue
                }
                let ws = Array(Set(neighbors[v])).sorted { (position[$0], $0) < (position[$1], $1) }
                guard !ws.isEmpty else { continue }
                let middle = Double(ws.count - 1) / 2
                for i in Int(middle.rounded(.down))...Int(middle.rounded(.up)) {
                    let w = ws[i]
                    guard reserved.isEmpty || (!reserved.contains(w) && position[w] < fence) else { continue }
                    if align[v] == v && previous < position[w] && !conflicts.contains(pair(v, w)) {
                        align[w] = v
                        root[v] = root[w]
                        align[v] = root[v]
                        previous = position[w]
                    }
                }
            }
        }
        return (root, align)
    }

    private func compaction(_ layering: [[Int]], root: [Int], align: [Int], reversed: Bool,
                            bands: [(upper: Int, lower: Int, gap: Double)]) -> [Double] {
        var edges: [Int: [Int: Double]] = [:]
        var incoming: [Int: [Int: Double]] = [:]
        var blocks: [Int] = []
        var known: Set<Int> = []
        func separate(_ u: Int, _ v: Int, _ gap: Double) {
            let a = root[u], b = root[v]
            guard a != b else { return }
            edges[a, default: [:]][b] = max(edges[a]?[b] ?? 0, gap)
            incoming[b, default: [:]][a] = max(incoming[b]?[a] ?? 0, gap)
        }
        for layer in layering {
            for (index, v) in layer.enumerated() {
                if known.insert(root[v]).inserted { blocks.append(root[v]) }
                guard index > 0 else { continue }
                let u = layer[index - 1]
                separate(u, v, reversed ? separation(v, u) : separation(u, v))
            }
        }
        for band in bands {
            if reversed { separate(band.lower, band.upper, band.gap) } else { separate(band.upper, band.lower, band.gap) }
        }
        // Kahn's order over blocks; a cycle (never expected) falls back to discovery order.
        var pending = Dictionary(uniqueKeysWithValues: blocks.map { ($0, incoming[$0]?.count ?? 0) })
        var sorted: [Int] = []
        var ready = blocks.filter { pending[$0] == 0 }
        var head = 0
        while head < ready.count {
            let b = ready[head]; head += 1
            sorted.append(b)
            for next in (edges[b] ?? [:]).keys.sorted() {
                pending[next]! -= 1
                if pending[next] == 0 { ready.append(next) }
            }
        }
        if sorted.count < blocks.count { sorted += blocks.filter { !Set(sorted).contains($0) } }

        var xs: [Int: Double] = [:]
        for b in sorted {
            xs[b] = (incoming[b] ?? [:]).reduce(0) { max($0, (xs[$1.key] ?? 0) + $1.value) }
        }
        for b in sorted.reversed() {
            let limit = (edges[b] ?? [:]).reduce(Double.infinity) { min($0, (xs[$1.key] ?? 0) - $1.value) }
            if limit.isFinite { xs[b] = max(xs[b] ?? 0, limit) }
        }
        return vertices.indices.map { xs[root[$0]] ?? 0 }
    }

    // MARK: - Groups

    /// Moves the aligned positions as little as possible so that every group's members sit inside its
    /// band with room for the label, nested groups nest, and anything else in a layer the group spans
    /// stays clear of the band.
    private func project(_ aligned: [Double]) -> [Double] {
        let groups = occupiedGroups
        let count = vertices.count
        var top: [Int: Int] = [:], bottom: [Int: Int] = [:]
        var desired = aligned
        var weight = vertices.map { $0.isFiller ? 1e-6 : $0.isDummy ? 0.5 : 1 }
        for v in spine { weight[v] = Self.spineWeight }
        for group in groups.sorted() {
            top[group] = desired.count
            desired.append(0); weight.append(0.01)
            bottom[group] = desired.count
            desired.append(0); weight.append(0.01)
        }
        // A group's ends start tight around its members.
        var upper: [Int: Double] = [:], lower: [Int: Double] = [:]
        for (v, vertex) in vertices.enumerated() where !vertex.isFiller {
            for group in path(of: v) {
                upper[group] = min(upper[group] ?? .infinity, aligned[v] - vertex.breadth / 2 - frame.padBefore)
                lower[group] = max(lower[group] ?? -.infinity, aligned[v] + vertex.breadth / 2 + frame.padAfter)
            }
        }
        for group in groups {
            desired[top[group]!] = upper[group] ?? 0
            desired[bottom[group]!] = lower[group] ?? 0
        }
        var solver = SeparationSolver(desired: desired, weight: weight)

        for layer in layers {
            for (a, b) in zip(layer, layer.dropFirst()) {
                let pa = path(of: a), pb = path(of: b)
                var shared = 0
                while shared < pa.count && shared < pb.count && pa[shared] == pb[shared] { shared += 1 }
                let upper = shared < pa.count ? bottom[pa[shared]] : nil
                let lower = shared < pb.count ? top[pb[shared]] : nil
                switch (upper, lower) {
                case (nil, nil):
                    solver.separate(a, b, by: separation(a, b))
                case (let u?, nil):
                    solver.separate(u, b, by: vertices[b].breadth / 2 + Self.boxMargin)
                case (nil, let l?):
                    solver.separate(a, l, by: vertices[a].breadth / 2 + Self.boxMargin)
                case (let u?, let l?):
                    solver.separate(u, l, by: Self.boxMargin)
                }
            }
            let cards = layer.filter { vertices[$0].node != nil }
            for (a, b) in zip(cards, cards.dropFirst()) { solver.separate(a, b, by: frame.pitch) }
        }
        for (v, vertex) in vertices.enumerated() where !vertex.isFiller {
            guard let group = vertex.group else { continue }
            solver.separate(top[group]!, v, by: vertex.breadth / 2 + frame.padBefore)
            solver.separate(v, bottom[group]!, by: vertex.breadth / 2 + frame.padAfter)
        }
        for group in groups {
            guard let parent = groupParent[group], groups.contains(parent) else { continue }
            solver.separate(top[parent]!, top[group]!, by: frame.padBefore)
            solver.separate(bottom[group]!, bottom[parent]!, by: frame.padAfter)
        }
        // The spine moves as one: a push on any of its vertices moves all of them, unless that would
        // contradict the other constraints (the spine passing a group on both sides).
        if spine.count > 1, let rigid = solver.merging(spine) { return Array(rigid.prefix(count)) }
        return Array(solver.solve().prefix(count))
    }

    /// The regions the stage draws around groups (StageLayout), from card rects.
    func groupRegions(_ rects: [String: CGRect]) -> [CGRect] {
        var bounds: [Int: CGRect] = [:]
        for (node, id) in ids.enumerated() {
            guard let group = nodeGroup[node], let rect = rects[id] else { continue }
            for g in groupPath[group] { bounds[g] = (bounds[g] ?? .null).union(rect) }
        }
        var regions: [Int: CGRect] = [:]
        for group in groupIDs.indices.sorted(by: { (-groupPath[$0].count, $0) < (-groupPath[$1].count, $1) }) {
            guard var rect = bounds[group] else { continue }
            for (child, region) in regions where groupParent[child] == group { rect = rect.union(region) }
            regions[group] = CGRect(x: rect.minX - LayoutMetrics.groupSide, y: rect.minY - LayoutMetrics.groupTop,
                                    width: rect.width + LayoutMetrics.groupSide * 2,
                                    height: rect.height + LayoutMetrics.groupTop + LayoutMetrics.groupBottom)
        }
        return regions.keys.sorted().map { regions[$0]! }
    }

    // MARK: - Columns

    /// The left edge of every layer. A channel widens for the widest label between adjacent layers,
    /// and a little for steep bends.
    private func layerOffsets(_ y: [Double]) -> [Double] {
        var x = [0.0]
        for l in layers.indices.dropLast() {
            var channel = Self.minimumChannel
            for (index, link) in links.enumerated() {
                // A bundle's member has no lane, but its pill shows when it leaves the bundle (in focus).
                let chain = folded.contains(index) && layer[link.tail] + 1 == layer[link.head] ? [link.tail, link.head] : chains[index]
                for (a, b) in zip(chain, chain.dropFirst()) where vertices[a].layer == l {
                    channel = max(channel, 78 + min(70, abs(y[a] - y[b]) * 0.09))
                    if chain.count == 2 && link.label > 0 { channel = max(channel, link.label + 30) }
                }
            }
            x.append(x[l] + LayoutMetrics.cardWidth + min(channel, Self.maximumChannel))
        }
        return x
    }

    // MARK: - Notes

    /// Each note goes to the first free corner of the diagram (bottom left, top left, bottom right,
    /// top right), or below it.
    func noteRects(cards: [String: CGRect], regions: [CGRect]) -> [String: CGRect] {
        let notes = level.nodes.filter { $0.kind.role == .annotation }
        guard !notes.isEmpty else { return [:] }
        let w = LayoutMetrics.cardWidth, h = LayoutMetrics.cardHeight
        var taken = Array(cards.values) + regions
        var result: [String: CGRect] = [:]
        var below: CGFloat?
        for note in notes {
            let bounds = taken.reduce(CGRect.null) { $0.union($1) }
            guard !bounds.isNull else {
                let rect = CGRect(x: CGFloat(result.count) * (w + 92), y: 0, width: w, height: h)
                result[note.id] = rect
                continue
            }
            let corners = [
                CGRect(x: bounds.minX, y: bounds.maxY - h, width: w, height: h),
                CGRect(x: bounds.minX, y: bounds.minY, width: w, height: h),
                CGRect(x: bounds.maxX - w, y: bounds.maxY - h, width: w, height: h),
                CGRect(x: bounds.maxX - w, y: bounds.minY, width: w, height: h),
            ]
            let free = corners.first { corner in
                bounds.width >= w * 2 && bounds.height >= h * 2 &&
                    !taken.contains { $0.intersects(corner.insetBy(dx: -30, dy: -30)) }
            }
            let rect: CGRect
            if let free {
                rect = free
            } else {
                let x = below ?? bounds.minX
                rect = CGRect(x: x, y: bounds.maxY + 40, width: w, height: h)
                below = rect.maxX + 92
            }
            result[note.id] = rect
            taken.append(rect)
        }
        return result
    }
}

/// Minimises Σ weight·(y − desired)² subject to `y[right] − y[left] ≥ gap` (Dwyer, Marriott and
/// Stuckey's block merging, "satisfy" pass). Constraints must not form a cycle.
struct SeparationSolver {
    struct Constraint {
        let left: Int
        let right: Int
        let gap: Double
    }

    var desired: [Double]
    var weight: [Double]
    var constraints: [Constraint] = []

    mutating func separate(_ left: Int, _ right: Int, by gap: Double) {
        constraints.append(Constraint(left: left, right: right, gap: gap))
    }

    /// The solution with `members` held at one position (as one variable), or nil when the constraints
    /// can't all hold that way.
    func merging(_ members: [Int]) -> [Double]? {
        guard let first = members.first else { return solve() }
        let set = Set(members)
        func map(_ v: Int) -> Int { set.contains(v) ? first : v }
        var merged = self
        let total = members.reduce(0) { $0 + weight[$1] }
        merged.desired[first] = members.reduce(0) { $0 + desired[$1] * weight[$1] } / max(total, 1e-9)
        merged.weight[first] = total
        merged.constraints = constraints.compactMap { c in
            let left = map(c.left), right = map(c.right)
            return left == right ? nil : Constraint(left: left, right: right, gap: c.gap)
        }
        var result = merged.solve()
        for v in members { result[v] = result[first] }
        for c in constraints where result[c.right] - result[c.left] < c.gap - 0.5 { return nil }
        return result
    }

    func solve() -> [Double] {
        let n = desired.count
        var incoming = Array(repeating: [Int](), count: n), outgoing = incoming
        var pending = Array(repeating: 0, count: n)
        for (index, c) in constraints.enumerated() {
            outgoing[c.left].append(index)
            incoming[c.right].append(index)
            pending[c.right] += 1
        }
        var order: [Int] = []
        var ready = (0..<n).filter { pending[$0] == 0 }
        var head = 0
        while head < ready.count {
            let v = ready[head]; head += 1
            order.append(v)
            for index in outgoing[v] {
                let r = constraints[index].right
                pending[r] -= 1
                if pending[r] == 0 { ready.append(r) }
            }
        }
        if order.count < n {
            let placed = Set(order)
            order += (0..<n).filter { !placed.contains($0) }
        }

        var block = Array(0..<n)
        var offset = Array(repeating: 0.0, count: n)
        var members = (0..<n).map { [$0] }
        var total = weight.map { max($0, 1e-9) }
        var weighted = (0..<n).map { desired[$0] * total[$0] }
        func y(_ v: Int) -> Double { weighted[block[v]] / total[block[v]] + offset[v] }

        for v in order {
            var b = block[v]
            while true {
                var worst: Constraint?
                var violation = 1e-7
                for m in members[b] {
                    for index in incoming[m] {
                        let c = constraints[index]
                        guard block[c.left] != b else { continue }
                        let amount = y(c.left) + c.gap - y(c.right)
                        if amount > violation { violation = amount; worst = c }
                    }
                }
                guard let c = worst else { break }
                let target = block[c.left]
                let shift = offset[c.left] + c.gap - offset[c.right]
                for m in members[b] {
                    offset[m] += shift
                    block[m] = target
                }
                weighted[target] += weighted[b] - shift * total[b]
                total[target] += total[b]
                members[target] += members[b]
                members[b] = []
                b = target
            }
        }
        var result = (0..<n).map(y)
        for v in order {
            for index in incoming[v] {
                let c = constraints[index]
                result[v] = max(result[v], result[c.left] + c.gap)
            }
        }
        return result
    }
}
