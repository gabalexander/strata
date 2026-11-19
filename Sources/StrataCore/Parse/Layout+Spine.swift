import Foundation

/// The spine: the level's main path, drawn as one straight line (docs/manifest.md, Layout).
///
/// - **Choice.** The longest chain of nodes that carry the flow (sources, ports, services, workers,
///   gateways, queues and topics; not stores or external APIs, which sit beside it), heavier traffic
///   winning a tie: each edge weighs the rate of the flows that cross it. It ends on a node that
///   handles work, not a queue, and needs at least three nodes.
/// - **Straight.** Coordinates make the spine one alignment block, ahead of anything else that would
///   line up with its nodes (Layout+Coordinates.swift), and the group solver moves it as one, so every
///   spine node shares one centre line and the rest of each layer sits to its sides. Ordering treats it
///   like a group (Layout+Order.swift): every group keeps one side of it.
/// - **Groups.** A spine node between two members of a group on the spine (a queue between two services
///   of one deployment) joins that group for layout, so the group's region can run straight through it
///   instead of stepping around it. The region is still drawn from the real members, which surround it.
///   A straight line can't pass a non-member in a layer its group's region spans, or two groups it runs
///   through that share a layer without nesting: then only the longest stretch that avoids both is the
///   spine. Only top-to-bottom layouts have one (left to right, the layers' fans already read well).
extension LayeredGraph {
    static let spineWeight: Double = 40

    private func carriesFlow(_ v: Int) -> Bool {
        switch kinds[v] {
        case .database, .cache, .search, .store, .vector, .external, .note: false
        default: true
        }
    }

    /// Traffic per link: each flow's rate (1/s for a manual or parent rate), times `p:` down its steps;
    /// a consumer flow carries what was published to its buffer.
    private func linkWeights() -> [Double] {
        var byID: [String: Int] = [:]
        for (index, link) in links.enumerated() { byID[link.id] = index }
        var weights = Array(repeating: 0.0, count: links.count)
        var arriving: [String: Double] = [:]
        func walk(_ steps: [Step], from node: String, rate: Double) {
            for step in steps {
                let share = rate * (step.p ?? 1)
                switch step.action {
                case .call(let target, let inner, let miss):
                    if let index = byID["\(node)->\(target)"] { weights[index] += share }
                    walk(inner, from: target, rate: share)
                    walk(miss, from: target, rate: share)
                case .publish(let target):
                    if let index = byID["\(node)->\(target)"] { weights[index] += share }
                    arriving[target, default: 0] += share
                case .parallel(let branches):
                    walk(branches, from: node, rate: share)
                case .work:
                    continue
                }
            }
        }
        // Consumer flows follow what earlier flows published, so a chain of queues settles in a few passes.
        for _ in 0..<3 {
            weights = Array(repeating: 0, count: links.count)
            let published = arriving
            arriving = [:]
            for flow in level.flows {
                if let buffer = flow.on, let consumer = flow.by {
                    let rate = published[buffer] ?? 1
                    if let index = byID["\(buffer)->\(consumer)"] { weights[index] += rate }
                    walk(flow.steps, from: consumer, rate: rate)
                } else if let source = flow.from {
                    walk(flow.steps, from: source, rate: flow.rate.perSecondValue ?? 1)
                }
            }
        }
        return weights
    }

    /// Picks the spine (`spineNodes`, node indices from the first layer down) and lets groups take in
    /// the spine nodes between their members. Run after layers are assigned.
    mutating func chooseSpine() {
        let n = ids.count
        let weights = linkWeights()
        var incoming = Array(repeating: [Int](), count: n)
        for (index, link) in links.enumerated() where !link.reversed && carriesFlow(link.from) && carriesFlow(link.to) {
            incoming[link.to].append(index)
        }
        // Longest chain (in nodes), then the most traffic, then manifest order: deterministic.
        var best = (0..<n).map { (length: carriesFlow($0) ? 1 : 0, weight: 0.0, from: -1) }
        for v in (0..<n).sorted(by: { (layer[$0], rank[$0]) < (layer[$1], rank[$1]) }) where carriesFlow(v) {
            for index in incoming[v] {
                let u = links[index].from
                let candidate = (length: best[u].length + 1, weight: best[u].weight + weights[index], from: u)
                if (candidate.length, candidate.weight) > (best[v].length, best[v].weight) { best[v] = candidate }
            }
        }
        // It ends on the node that handles the work, not on a queue it publishes to.
        let ends = (0..<n).filter { carriesFlow($0) && kinds[$0].role != .buffer }
        guard var end = ends.max(by: { a, b in
            (best[a].length, best[a].weight, -a) < (best[b].length, best[b].weight, -b)
        }), best[end].length >= 3 else { return }
        var path = [end]
        while best[end].from >= 0 {
            end = best[end].from
            path.insert(end, at: 0)
        }

        // A spine node between two grouped spine nodes joins the deepest group they share, when it is in
        // none of its own or only in that group's ancestors.
        func groups(_ v: Int) -> [Int] { nodeGroup[v].map { groupPath[$0] } ?? [] }
        func adoption(_ segment: ArraySlice<Int>) -> [Int: Int] {
            var adopted: [Int: Int] = [:]
            for i in segment.indices {
                guard let before = segment[..<i].last(where: { nodeGroup[$0] != nil }),
                      let after = segment[(i + 1)...].first(where: { nodeGroup[$0] != nil }),
                      let shared = commonGroup(nodeGroup[before], nodeGroup[after]) else { continue }
                let own = groups(segment[i])
                guard !own.contains(shared), Array(groupPath[shared].prefix(own.count)) == own else { continue }
                adopted[segment[i]] = shared
            }
            return adopted
        }
        // The layers each group's region spans (side nodes counted in their caller's layer).
        var preds = Array(repeating: [Int](), count: n), succs = preds
        for link in links {
            succs[link.tail].append(link.head)
            preds[link.head].append(link.tail)
        }
        var callerLayer: [Int: Int] = [:]
        for (caller, sides) in sideCandidates(preds: preds, succs: succs) { for side in sides { callerLayer[side] = layer[caller] } }
        var span: [Int: ClosedRange<Int>] = [:]
        for v in 0..<n {
            let l = callerLayer[v] ?? layer[v]
            for group in groups(v) { span[group] = span[group].map { min($0.lowerBound, l)...max($0.upperBound, l) } ?? l...l }
        }
        // A straight spine can't pass a node outside a group it runs through in a layer that group's
        // region spans: the region would cover it. Keep the longest stretch that avoids it.
        // Nor can it run through two groups that share a layer unless one holds the other.
        func fits(_ segment: ArraySlice<Int>, _ adopted: [Int: Int]) -> Bool {
            func path(_ v: Int) -> [Int] { adopted[v].map { groupPath[$0] } ?? groups(v) }
            let crossed = Set(segment.flatMap(path))
            let covered = segment.allSatisfy { v in
                crossed.allSatisfy { group in path(v).contains(group) || !(span[group]?.contains(layer[v]) ?? false) }
            }
            guard covered, let top = segment.first.map({ layer[$0] }), let bottom = segment.last.map({ layer[$0] }) else { return false }
            return (top...bottom).allSatisfy { l in
                let here = crossed.filter { span[$0]?.contains(l) ?? false }
                return here.allSatisfy { a in here.allSatisfy { b in groupPath[a].contains(b) || groupPath[b].contains(a) } }
            }
        }
        var chosen: Range<Int>?
        for start in path.indices {
            for stop in stride(from: path.count, through: start + 3, by: -1) where kinds[path[stop - 1]].role != .buffer {
                if let chosen, stop - start <= chosen.count { break }
                let segment = path[start..<stop]
                if fits(segment, adoption(segment)) {
                    chosen = start..<stop
                    break
                }
            }
        }
        guard let chosen else { return }
        let segment = path[chosen]
        let adopted = adoption(segment)
        spineNodes = Array(segment)
        for (v, group) in adopted { nodeGroup[v] = group }
        adoptedGroups = adopted
    }

    /// The spine's vertices layer by layer, dummies of its long edges included. Run after the vertices
    /// are built.
    mutating func traceSpine() {
        spine = []
        guard spineNodes.count > 1 else { return }
        var byEnds: [[Int]: Int] = [:]
        for (index, link) in links.enumerated() where !link.reversed { byEnds[[link.from, link.to]] = index }
        var trace = [spineNodes[0]]
        for (a, b) in zip(spineNodes, spineNodes.dropFirst()) {
            guard let index = byEnds[[a, b]] else { return }
            trace += chains[index].dropFirst()
        }
        spine = trace
    }

    /// Each spine vertex's neighbour on the spine one layer up, and one layer down.
    var spineAbove: [Int: Int] { Dictionary(uniqueKeysWithValues: zip(spine.dropFirst(), spine)) }
    var spineBelow: [Int: Int] { Dictionary(uniqueKeysWithValues: zip(spine, spine.dropFirst())) }
}
