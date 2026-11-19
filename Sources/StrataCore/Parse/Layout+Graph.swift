import Foundation

/// The auto layout pipeline (docs/manifest.md, Layout). Each step lives in its own file: layers here,
/// ordering in Layout+Order.swift, coordinates in Layout+Coordinates.swift, and what only a top-to-bottom
/// layout does (side nodes, shared stores at the bottom) in Layout+Down.swift.
///
/// The pipeline works in one frame whatever the direction: layers follow each other along x and a
/// layer's vertices stack along y. A `down` layout runs it with card sizes and gaps swapped (cards are
/// as wide as they are, so the spacing differs by axis) and transposes the result.
enum AutoLayout {
    struct Result {
        var positions: [String: GridPoint]
        var via: [String: [GridPoint]] = [:]
        var issues: [DiagramLayout.Issue]
    }

    /// `hints` is the direction the level's positions were written for.
    static func run(_ level: Level, direction: FlowDirection = .right, hints: FlowDirection = .right) -> Result {
        var graph = LayeredGraph(level: level, direction: direction, hints: hints)
        guard !graph.ids.isEmpty else {
            return Result(positions: graph.placeNotes(cards: [:], regions: []), issues: [])
        }
        graph.breakCycles()
        graph.assignLayers()
        if direction == .down { graph.chooseSpine() }
        guard direction == .down else {
            graph.buildVertices()
            graph.orderLayers()
            return graph.coordinates()
        }
        // A side node that ordering could not put next to its caller goes back to the next row.
        let first = graph
        graph.placeSides()
        graph.buildVertices()
        graph.orderLayers()
        graph.insertSides()
        let stranded = graph.strandedSides()
        if !stranded.isEmpty {
            graph = first
            graph.placeSides(except: stranded)
            graph.buildVertices()
            graph.orderLayers()
            graph.insertSides()
        }
        return graph.coordinates()
    }
}

/// A level as a layered graph: real nodes, plus dummy vertices where an edge spans several layers
/// and filler vertices where a group spans a layer it has no member in.
struct LayeredGraph {
    struct Link {
        let from: Int
        let to: Int
        let id: String
        let label: Double          // estimated pill width, 0 without a label
        var reversed = false       // broken out of a cycle: laid out from `to` to `from`
        var tail: Int { reversed ? to : from }
        var head: Int { reversed ? from : to }
    }

    struct Vertex {
        var node: Int?             // a real node (index into ids)
        var link: Int?             // a dummy on this link
        var filler: Int?           // a filler for this group
        var layer: Int
        var group: Int?            // deepest group
        var breadth: Double        // extent across the layer: a card's height in columns, its width in rows
        var isDummy: Bool { link != nil }
        var isFiller: Bool { filler != nil }
    }

    let level: Level
    let direction: FlowDirection
    let hintDirection: FlowDirection   // the way the level's positions were written
    let frame: LayoutFrame
    var ids: [String] = []
    var kinds: [NodeKind] = []
    var hints: [GridPoint?] = []   // in this frame: x picks the layer, y orders it
    var heights: [Double] = []     // card heights (taller with component chips)
    var hintColumn: [Int?] = []
    var nodeGroup: [Int?] = []
    var groupIDs: [String] = []
    var groupParent: [Int?] = []
    var groupPath: [[Int]] = []    // top-level first, ending with the group itself
    var links: [Link] = []
    var layer: [Int] = []
    var rank: [Int] = []

    var vertices: [Vertex] = []
    var preds: [[Int]] = []
    var succs: [[Int]] = []
    var chains: [[Int]] = []       // per link: vertices from tail to head
    var layers: [[Int]] = []       // per layer: vertices top to bottom
    var issues: [DiagramLayout.Issue] = []
    var position: [Int] = []       // index of each vertex within its layer, kept current by ordering
    /// Top to bottom only (Layout+Down.swift): a side node sits in its caller's row, next to it.
    var sideOf: [Int: Int] = [:]
    var flat: Set<Int> = []        // links between a side node and its caller, inside one layer
    /// The main path drawn straight (Layout+Spine.swift): its nodes, its vertices layer by layer, and the
    /// spine nodes a group took in for layout.
    var spineNodes: [Int] = []
    var spine: [Int] = []
    var adoptedGroups: [Int: Int] = [:]

    init(level: Level, direction: FlowDirection = .right, hints hintDirection: FlowDirection = .right) {
        self.level = level
        self.direction = direction
        self.hintDirection = hintDirection
        frame = LayoutFrame(direction)
        let diagram = level.nodes.filter { $0.kind.role != .annotation }
        var index: [String: Int] = [:]
        for node in diagram where index[node.id] == nil {
            index[node.id] = ids.count
            ids.append(node.id)
            kinds.append(node.kind)
            hints.append(hintDirection == .down ? node.at.map { GridPoint($0.y, $0.x) } : node.at)
            heights.append(LayoutMetrics.cardHeight(for: node))
        }

        var groupIndex: [String: Int] = [:]
        for group in level.groups where groupIndex[group.id] == nil {
            groupIndex[group.id] = groupIDs.count
            groupIDs.append(group.id)
        }
        groupParent = groupIDs.map { _ in nil }
        for group in level.groups {
            guard let child = groupIndex[group.id], let parent = group.parent.flatMap({ groupIndex[$0] }) else { continue }
            groupParent[child] = parent
        }
        for group in groupIDs.indices {
            var path = [group]
            var seen: Set<Int> = [group]
            while let parent = groupParent[path[0]], seen.insert(parent).inserted { path.insert(parent, at: 0) }
            if let parent = groupParent[path[0]], seen.contains(parent) { groupParent[path[0]] = nil }   // a cycle: cut it
            groupPath.append(path)
        }
        nodeGroup = ids.map { id in diagram.first { $0.id == id }?.group.flatMap { groupIndex[$0] } }

        var seen: Set<String> = []
        for edge in level.edges {
            guard let from = index[edge.from], let to = index[edge.to], from != to, seen.insert(edge.id).inserted else { continue }
            let text = edge.label ?? edge.protocol ?? ""
            links.append(Link(from: from, to: to, id: edge.id, label: text.isEmpty ? 0 : LayoutMetrics.pillWidth(text)))
        }

        // Hint columns: hinted x positions that lie close together share a column.
        let xs = hints.compactMap { $0?.x }.sorted()
        var starts: [Double] = []
        for x in xs where starts.last.map({ x - $0 > 0.45 }) ?? true { starts.append(x) }
        hintColumn = hints.map { hint in hint.map { h in starts.lastIndex { $0 <= h.x + 1e-9 } ?? 0 } }
    }

    /// The deepest group containing both groups, or nil.
    func commonGroup(_ a: Int?, _ b: Int?) -> Int? {
        guard let a, let b else { return nil }
        let pa = groupPath[a], pb = groupPath[b]
        var common: Int?
        for (x, y) in zip(pa, pb) where x == y { common = x }
        return common
    }

    func path(of vertex: Int) -> [Int] {
        vertices[vertex].group.map { groupPath[$0] } ?? []
    }

    private func roleRank(_ node: Int) -> Int {
        switch kinds[node].role {
        case .source: 0
        case .buffer, .annotation: 2
        case .server: kinds[node] == .port ? 1 : (Self.dataKinds.contains(kinds[node]) || kinds[node] == .external ? 3 : 2)
        }
    }

    static let dataKinds: Set<NodeKind> = [.database, .cache, .store, .search, .vector]

    // MARK: - Cycles

    /// Breaks cycles inside each strongly connected component: nodes are ranked by how many hops
    /// they are from a source (then by hint column and role), and an edge in a cycle that points back
    /// in that ranking is laid out reversed. A relay polling a database or a worker publishing back
    /// to its own topic stays a back edge, and the main flow keeps its direction.
    mutating func breakCycles() {
        let n = ids.count
        var outgoing = Array(repeating: [Int](), count: n), incoming = outgoing
        for link in links {
            outgoing[link.from].append(link.to)
            incoming[link.to].append(link.from)
        }

        // Hops from the sources; nodes no source reaches start a search of their own.
        var depth = Array(repeating: -1, count: n)
        var queue = (0..<n).filter { incoming[$0].isEmpty || kinds[$0].role == .source }
        for v in queue { depth[v] = 0 }
        var head = 0
        func search() {
            while head < queue.count {
                let v = queue[head]; head += 1
                for w in outgoing[v] where depth[w] < 0 {
                    depth[w] = depth[v] + 1
                    queue.append(w)
                }
            }
        }
        search()
        while let seed = (0..<n).filter({ depth[$0] < 0 }).min(by: { key($0, depth).lexicographicallyPrecedes(key($1, depth)) }) {
            depth[seed] = 0
            queue.append(seed)
            search()
        }

        let component = stronglyConnected(outgoing)
        for index in links.indices {
            let link = links[index]
            links[index].reversed = component[link.from] == component[link.to] && key(link.to, depth).lexicographicallyPrecedes(key(link.from, depth))
        }

        // A topological order of the acyclic graph, for layering.
        var successors = Array(repeating: [Int](), count: n)
        var pending = Array(repeating: 0, count: n)
        for link in links {
            successors[link.tail].append(link.head)
            pending[link.head] += 1
        }
        var order: [Int] = []
        var ready = (0..<n).filter { pending[$0] == 0 }
        while let v = ready.min() {
            ready.removeAll { $0 == v }
            order.append(v)
            for w in successors[v] {
                pending[w] -= 1
                if pending[w] == 0 { ready.append(w) }
            }
        }
        rank = Array(repeating: 0, count: n)
        for (position, v) in order.enumerated() { rank[v] = position }
    }

    private func key(_ v: Int, _ depth: [Int]) -> [Int] {
        [depth[v], hintColumn[v] ?? Int.max / 2, roleRank(v), v]
    }

    /// Tarjan's strongly connected components: the component index of each node.
    private func stronglyConnected(_ outgoing: [[Int]]) -> [Int] {
        let n = outgoing.count
        var index = Array(repeating: -1, count: n), low = Array(repeating: 0, count: n)
        var onStack = Array(repeating: false, count: n)
        var stack: [Int] = []
        var component = Array(repeating: -1, count: n)
        var counter = 0, components = 0
        func visit(_ v: Int) {
            index[v] = counter; low[v] = counter; counter += 1
            stack.append(v); onStack[v] = true
            for w in outgoing[v] {
                if index[w] < 0 {
                    visit(w)
                    low[v] = min(low[v], low[w])
                } else if onStack[w] {
                    low[v] = min(low[v], index[w])
                }
            }
            if low[v] == index[v] {
                while let w = stack.popLast() {
                    onStack[w] = false
                    component[w] = components
                    if w == v { break }
                }
                components += 1
            }
        }
        for v in 0..<n where index[v] < 0 { visit(v) }
        return component
    }

    // MARK: - Layers

    /// Longest path from the sources, then: sources sit just before their first callee, data stores
    /// called together share a column, and outbound ports form the right edge. Hinted nodes prefer
    /// their hint column-mates' layer.
    mutating func assignLayers() {
        let n = ids.count
        var dagPreds = Array(repeating: [Int](), count: n), dagSuccs = dagPreds
        for link in links {
            dagPreds[link.head].append(link.tail)
            dagSuccs[link.tail].append(link.head)
        }
        let order = (0..<n).sorted { rank[$0] < rank[$1] }
        layer = Array(repeating: 0, count: n)
        for v in order {
            layer[v] = dagPreds[v].map { layer[$0] + 1 }.max() ?? 0
        }

        // Top to bottom, a node's side nodes move with it, so they never hold it up.
        let followers = direction == .down ? Set(sideCandidates(preds: dagPreds, succs: dagSuccs).values.joined()) : []
        func range(_ v: Int) -> ClosedRange<Int> {
            let lo = dagPreds[v].map { layer[$0] + 1 }.max() ?? 0
            let next = followers.isEmpty ? dagSuccs[v] : dagSuccs[v].filter { !followers.contains($0) }
            let hi = next.map { layer[$0] - 1 }.min() ?? (dagSuccs[v].isEmpty ? Int.max / 2 : lo)
            return lo...max(lo, hi)
        }

        // Isolated nodes join their group, or sit with the sources (or the stores).
        let isolated = (0..<n).filter { dagPreds[$0].isEmpty && dagSuccs[$0].isEmpty }

        // A node fed only by sources (a cron's job, say) slides toward its callees when it calls more
        // than it is called. Everything else stays right after its last caller, so a callee is never
        // pulled away from the flow that reaches it, and sources stay on the left.
        for v in order.reversed() where !dagPreds[v].isEmpty && dagSuccs[v].count > dagPreds[v].count
            && dagPreds[v].allSatisfy({ dagPreds[$0].isEmpty }) {
            layer[v] = range(v).upperBound
        }
        for v in followers { layer[v] = max(layer[v], dagPreds[v].map { layer[$0] + 1 }.max() ?? 0) }

        // Stores called by the same caller share a column (the furthest one).
        let sinks = (0..<n).filter { Self.dataKinds.contains(kinds[$0]) && dagSuccs[$0].isEmpty && !dagPreds[$0].isEmpty }
        let sinkSet = Set(sinks)
        for _ in 0..<n {
            var changed = false
            for caller in 0..<n {
                let stores = dagSuccs[caller].filter { sinkSet.contains($0) }
                guard stores.count > 1, let furthest = stores.map({ layer[$0] }).max() else { continue }
                for store in stores where layer[store] < furthest { layer[store] = furthest; changed = true }
            }
            if !changed { break }
        }

        // Hinted nodes follow their hint column-mates when the edges allow it.
        let columns = Dictionary(grouping: (0..<n).filter { hintColumn[$0] != nil }) { hintColumn[$0]! }
        for _ in 0..<3 {
            for v in order {
                guard let column = hintColumn[v], let mates = columns[column], mates.count > 1,
                      !dagPreds[v].isEmpty else { continue }    // sources stay on the left
                let others = mates.filter { $0 != v }.map { layer[$0] }.sorted()
                let wanted = others[others.count / 2]
                let bounds = range(v)
                if sinkSet.contains(v) && wanted < layer[v] { continue }
                layer[v] = min(max(wanted, bounds.lowerBound), bounds.upperBound)
            }
        }

        let deepest = layer.max() ?? 0
        for v in 0..<n where kinds[v] == .port && dagSuccs[v].isEmpty && !dagPreds[v].isEmpty {
            layer[v] = max(layer[v], deepest)
        }
        if direction == .down { sinkSharedStores(deepest: deepest, preds: dagPreds, succs: dagSuccs) }
        for v in isolated {
            if let hint = hintColumn[v], let mates = columns[hint]?.filter({ !isolated.contains($0) }), !mates.isEmpty {
                layer[v] = mates.map { layer[$0] }.sorted()[mates.count / 2]
            } else if let group = nodeGroup[v] {
                let mates = (0..<n).filter { nodeGroup[$0] == group && !isolated.contains($0) }.map { layer[$0] }.sorted()
                layer[v] = mates.isEmpty ? 0 : mates[mates.count / 2]
            } else {
                layer[v] = Self.dataKinds.contains(kinds[v]) || kinds[v] == .external ? deepest : 0
            }
        }

        // Drop empty layers.
        let used = Array(Set(layer)).sorted()
        let compact = Dictionary(uniqueKeysWithValues: used.enumerated().map { ($0.element, $0.offset) })
        layer = layer.map { compact[$0]! }

        // Hints the layout could not follow: one warning per node, naming the first sender.
        var behind: [Int: [Int]] = [:], beside: [Int: [Int]] = [:]
        for link in links where !link.reversed {
            guard let a = hintColumn[link.from], let b = hintColumn[link.to] else { continue }
            if b < a { behind[link.to, default: []].append(link.from) }
            else if a == b { beside[link.to, default: []].append(link.from) }
        }
        func others(_ count: Int) -> String {
            count == 0 ? ", which sends to it" : count == 1 ? " and 1 other node that send to it" : " and \(count) other nodes that send to it"
        }
        let down = hintDirection == .down
        for node in behind.keys.sorted() {
            let senders = behind[node]!
            let first = ids[senders[0]]
            issues.append(DiagramLayout.Issue(node: ids[node], message: down
                ? "the hint puts '\(ids[node])' above '\(first)'\(others(senders.count - 1)); auto layout keeps the flow top to bottom (move the hint, or use layout: manual)"
                : "the hint puts '\(ids[node])' left of '\(first)'\(others(senders.count - 1)); auto layout keeps the flow left to right (move the hint, or use layout: manual)"))
        }
        for node in beside.keys.sorted() where behind[node] == nil {
            let senders = beside[node]!
            let first = ids[senders[0]]
            issues.append(DiagramLayout.Issue(node: ids[node], message: down
                ? "'\(ids[node])' shares a hint row with '\(first)'\(others(senders.count - 1)); auto layout puts it further down (move the hint, or use layout: manual)"
                : "'\(ids[node])' shares a hint column with '\(first)'\(others(senders.count - 1)); auto layout puts it further right (move the hint, or use layout: manual)"))
        }
    }

    // MARK: - Vertices

    /// Real vertices, a chain of dummies for every edge spanning more than one layer, and fillers that
    /// hold a group's place in the layers it crosses without a member.
    mutating func buildVertices() {
        vertices = ids.indices.map { Vertex(node: $0, layer: layer[$0], group: nodeGroup[$0], breadth: frame.breadth(heights[$0])) }
        preds = Array(repeating: [], count: vertices.count)
        succs = preds
        chains = []
        // The layers each group's region covers (its members' layers, nested groups included).
        var cover: [Int: ClosedRange<Int>] = [:]
        for node in ids.indices {
            for group in nodeGroup[node].map({ groupPath[$0] }) ?? [] {
                cover[group] = cover[group].map { min($0.lowerBound, layer[node])...max($0.upperBound, layer[node]) }
                    ?? layer[node]...layer[node]
            }
        }
        // An edge travels inside the region of the group it enters (or leaves) wherever that region
        // spans its layer, instead of detouring around it: only nodes must keep out of other groups.
        func dummyGroup(_ tail: Int, _ head: Int, _ l: Int) -> Int? {
            let common = commonGroup(nodeGroup[tail], nodeGroup[head])
            for end in [tail, head] {
                guard let deepest = nodeGroup[end] else { continue }
                for group in groupPath[deepest].reversed() where cover[group]?.contains(l) == true {
                    if group == common || common.map({ groupPath[group].contains($0) }) ?? true { return group }
                }
            }
            return common
        }
        for (index, link) in links.enumerated() {
            let tail = link.tail, head = link.head
            var chain = [tail]
            if layer[tail] + 1 < layer[head] {
                for l in (layer[tail] + 1)..<layer[head] {
                    vertices.append(Vertex(link: index, layer: l, group: dummyGroup(tail, head, l), breadth: 0))
                    preds.append([]); succs.append([])
                    chain.append(vertices.count - 1)
                }
            }
            chain.append(head)
            chains.append(chain)
            // A side node's link stays inside the layer, out of ordering and alignment.
            guard !flat.contains(index) else { continue }
            for (a, b) in zip(chain, chain.dropFirst()) {
                succs[a].append(b)
                preds[b].append(a)
            }
        }

        var span: [Int: ClosedRange<Int>] = [:]
        var present: Set<[Int]> = []
        for (index, vertex) in vertices.enumerated() {
            for group in path(of: index) {
                if vertex.node != nil {
                    span[group] = span[group].map { min($0.lowerBound, vertex.layer)...max($0.upperBound, vertex.layer) }
                        ?? vertex.layer...vertex.layer
                }
                present.insert([group, vertex.layer])
            }
        }
        // Deeper groups first, so a nested filler also holds its parents' place.
        for group in groupIDs.indices.sorted(by: { (-groupPath[$0].count, $0) < (-groupPath[$1].count, $1) }) {
            guard let range = span[group] else { continue }
            for l in range where !present.contains([group, l]) {
                vertices.append(Vertex(filler: group, layer: l, group: group, breadth: 0))
                preds.append([]); succs.append([])
                for ancestor in groupPath[group] { present.insert([ancestor, l]) }
            }
        }
        layers = Array(repeating: [], count: (layer.max() ?? 0) + 1)
        // Side nodes join their caller's layer after ordering (insertSides).
        for (index, vertex) in vertices.enumerated() where vertex.node.map({ sideOf[$0] == nil }) ?? true {
            layers[vertex.layer].append(index)
        }
        position = Array(repeating: 0, count: vertices.count)
        for l in layers.indices { reindex(l) }
        traceSpine()
    }

    mutating func reindex(_ l: Int) {
        for (index, v) in layers[l].enumerated() { position[v] = index }
    }

    /// Groups that have at least one real member, directly or through a nested group.
    var occupiedGroups: Set<Int> {
        var result: Set<Int> = []
        for group in nodeGroup.compactMap({ $0 }) { result.formUnion(groupPath[group]) }
        return result
    }
}
