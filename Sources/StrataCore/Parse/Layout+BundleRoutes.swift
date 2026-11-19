import Foundation

/// Where bundles (EdgeBundling) are drawn. A bundle is routed like any edge, in the same pass as the level's
/// own edges, so it gets its own port on the target and its own track through each gap:
///
/// - **From a group's box:** its line starts on the side of the group's region that faces the target (the
///   bottom of a top-to-bottom map, the right of a left-to-right one), across from the target where the
///   border reaches, else as near as it does.
/// - **Trunk:** the members' lines run into a junction just past the last of them, toward the target, and
///   one line goes on from there. Only when the target is further than the next row (column) of cards.
///
/// Each member is routed from its source to where the bundle starts (the box's border, the junction) and
/// on along the bundle's line: drawn whole when it leaves the bundle (in focus), it runs into the bundle's
/// start like a harness, its pill on its own stretch, and nothing else moves. Each start is a thin card the
/// router treats as a source; a bundle that finds no room for one keeps its members routed on their own.
extension EdgeRouter {
    public struct BundleRoute: Sendable {
        public let bundle: String
        /// From the group's border, or the junction, to the target, carrying the bundle's pill.
        public let trunk: EdgeRoute
        /// Each member edge's own stretch, from its source to where the trunk starts. A trunk draws them;
        /// a group's box hides them.
        public let stubs: [String: EdgeRoute]
        /// Where the line starts: on the group's border, or the junction.
        public var origin: CGPoint { trunk.start }
    }

    public struct BundledRouting: Sendable {
        /// The level's own edges, each member as its stub and then the trunk, and the group labels.
        public let routing: Routing
        /// The bundles that found room, in the order given.
        public let bundles: [BundleRoute]
    }

    /// The thickness of a bundle's start card, and its length across the flow and along it.
    static let originThickness: CGFloat = 2
    static let originLength: CGFloat = 26

    /// Routes `edges` and `bundles` together. `groups` are the group regions by group id.
    public static func routing(cards: [Card], regions: [Region] = [], groups: [String: CGRect], edges: [Request],
                               bundles: [EdgeBundle], direction: FlowDirection = .right) -> BundledRouting {
        guard !bundles.isEmpty else {
            return BundledRouting(routing: routing(cards: cards, regions: regions, edges: edges, direction: direction), bundles: [])
        }
        let rects = Dictionary(cards.map { ($0.id, $0.rect) }, uniquingKeysWith: { first, _ in first })
        let requests = Dictionary(edges.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var starts: [Card] = []
        var extra: [Request] = []
        var placed: [EdgeBundle] = []
        for bundle in bundles {
            guard let target = rects[bundle.target], bundle.edges.allSatisfy({ requests[$0] != nil }) else { continue }
            let origin = bundle.id + "#origin"
            let start: CGRect?
            if let group = bundle.group {
                start = groups[group].flatMap { border($0, facing: target, direction: direction, clear: cards + starts) }
            } else {
                let sources = bundle.sources.compactMap { rects[$0] }
                start = sources.count == bundle.sources.count
                    ? junction(sources, toward: target, direction: direction, clear: cards + starts) : nil
            }
            guard let start else { continue }
            starts.append(Card(id: origin, rect: start))
            // The members' pills show only when they leave their bundle: theirs are placed last.
            for (edge, source) in zip(bundle.edges, bundle.sources) {
                extra.append(Request(id: bundle.id + "#" + edge, from: source, to: origin, label: requests[edge]?.label, later: true))
            }
            extra.append(Request(id: bundle.id, from: origin, to: bundle.target, label: bundle.label()))
            placed.append(bundle)
        }
        let members = Set(placed.flatMap(\.edges))
        let all = routing(cards: cards + starts, regions: regions, edges: edges.filter { !members.contains($0.id) } + extra,
                          direction: direction)
        let byID = Dictionary(all.routes.map { ($0.edge, $0) }, uniquingKeysWith: { first, _ in first })
        var joined: [String: EdgeRoute] = [:]
        let routes = placed.compactMap { bundle -> BundleRoute? in
            guard let trunk = byID[bundle.id] else { return nil }
            var stubs: [String: EdgeRoute] = [:]
            for edge in bundle.edges {
                guard let stub = byID[bundle.id + "#" + edge] else { continue }
                stubs[edge] = stub
                joined[edge] = join(stub, trunk, as: edge)
            }
            return BundleRoute(bundle: bundle.id, trunk: trunk, stubs: stubs)
        }
        let own = edges.compactMap { byID[$0.id] ?? joined[$0.id] }
        return BundledRouting(routing: Routing(routes: own, labels: all.labels), bundles: routes)
    }

    /// A member's whole line: its stub, across the start card, then the trunk; its pill stays on the stub.
    static func join(_ stub: EdgeRoute, _ trunk: EdgeRoute, as edge: String) -> EdgeRoute {
        var segments = stub.segments
        if hypot(stub.tip.x - trunk.start.x, stub.tip.y - trunk.start.y) > 0.5 { segments.append(.line(to: trunk.start)) }
        segments += trunk.segments
        return EdgeRoute(edge: edge, start: stub.start, segments: segments, tip: trunk.tip, direction: trunk.direction,
                         label: stub.label, labelWidth: stub.labelWidth)
    }

    /// A thin card on `region`'s border where a bundle's line leaves the group: on the side facing
    /// `target` (the way the level runs first), across from it where the border reaches, at the nearest
    /// spot clear of every card. Nil when the target is not clear of the region.
    static func border(_ region: CGRect, facing target: CGRect, direction: FlowDirection, clear cards: [Card]) -> CGRect? {
        let forward: Side = direction == .down ? .bottom : .right
        let room: [(side: Side, gap: CGFloat)] = [(.bottom, target.minY - region.maxY), (.top, region.minY - target.maxY),
                                                   (.right, target.minX - region.maxX), (.left, region.minX - target.maxX)]
        let enough: CGFloat = 24
        guard let side = room.first(where: { $0.side == forward && $0.gap >= enough })?.side
            ?? room.filter({ $0.gap >= enough }).max(by: { $0.gap < $1.gap })?.side else { return nil }
        let horizontal = side == .top || side == .bottom          // the border runs along x
        // The router puts a port on the middle of a side only when the side is long enough: a start across
        // the flow is twice as long, since its port sits on the router's top or bottom.
        let length = horizontal == (direction == .down) ? originLength : originLength * 2
        let lo = (horizontal ? region.minX : region.minY) + length / 2 + 14
        let hi = (horizontal ? region.maxX : region.maxY) - length / 2 - 14
        guard hi >= lo else { return nil }
        let wanted = min(max(horizontal ? target.midX : target.midY, lo), hi)
        func rect(_ c: CGFloat) -> CGRect {
            switch side {
            case .bottom: CGRect(x: c - length / 2, y: region.maxY - originThickness, width: length, height: originThickness)
            case .top: CGRect(x: c - length / 2, y: region.minY, width: length, height: originThickness)
            case .right: CGRect(x: region.maxX - originThickness, y: c - length / 2, width: originThickness, height: length)
            case .left: CGRect(x: region.minX, y: c - length / 2, width: originThickness, height: length)
            }
        }
        for step in 0..<32 {
            let c = wanted + CGFloat((step + 1) / 2) * 12 * (step.isMultiple(of: 2) ? 1 : -1)
            guard c >= lo, c <= hi else { continue }
            let candidate = rect(c)
            if !cards.contains(where: { $0.rect.insetBy(dx: -6, dy: -6).intersects(candidate) }) { return candidate }
        }
        return nil
    }

    /// The junction a trunk's members run into: just past the last of them along the flow, across from the
    /// target where their spread reaches, else at its near end. Nil without room before the target.
    static func junction(_ sources: [CGRect], toward target: CGRect, direction: FlowDirection, clear cards: [Card]) -> CGRect? {
        let down = direction == .down
        func along(_ r: CGRect) -> (lo: CGFloat, hi: CGFloat) { down ? (r.minY, r.maxY) : (r.minX, r.maxX) }
        func across(_ r: CGRect) -> CGFloat { down ? r.midX : r.midY }
        guard let last = sources.map({ along($0).hi }).max() else { return nil }
        // A trunk only pays when the target is further than the next row (column): across one gap, the lines
        // would meet where they end anyway.
        let room = along(target).lo - last
        guard room >= (down ? LayoutMetrics.cardHeight : LayoutMetrics.cardWidth) + 90 else { return nil }
        // Into the gap after the last source, less than halfway to whatever follows it.
        let next = cards.map { along($0.rect).lo }.filter { $0 > last + 4 }.min() ?? along(target).lo
        let at = last + max(18, min(36, (next - last) * 0.42))
        let centres = sources.map(across)
        let wanted = min(max(across(target), centres.min()!), centres.max()!)
        for step in 0..<24 {
            let c = wanted + CGFloat((step + 1) / 2) * 12 * (step.isMultiple(of: 2) ? 1 : -1)
            let candidate = down
                ? CGRect(x: c - originLength / 2, y: at - originThickness / 2, width: originLength, height: originThickness)
                : CGRect(x: at - originThickness / 2, y: c - originLength / 2, width: originThickness, height: originLength)
            if !cards.contains(where: { $0.rect.insetBy(dx: -6, dy: -6).intersects(candidate) }) { return candidate }
        }
        return nil
    }
}
