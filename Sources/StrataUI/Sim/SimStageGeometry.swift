import SwiftUI
import StrataCore

struct StageCamera: Equatable {
    var zoom: CGFloat = 1
    var offset: CGPoint = .zero

    init(zoom: CGFloat = 1, offset: CGPoint = .zero) {
        self.zoom = zoom
        self.offset = offset
    }

    init(fitting bounds: CGRect, in size: CGSize, inset: CGFloat) {
        let available = CGSize(width: max(1, size.width - inset * 2), height: max(1, size.height - inset * 2))
        let scale = min(1, available.width / max(1, bounds.width), available.height / max(1, bounds.height))
        self.init(zoom: scale)
        offset = CGPoint(x: size.width / 2 - bounds.midX * zoom, y: size.height / 2 - bounds.midY * zoom)
    }

    func screen(_ p: CGPoint) -> CGPoint { p * zoom + offset }
    func world(_ p: CGPoint) -> CGPoint { (p - offset) * (1 / zoom) }
    func screen(_ r: CGRect) -> CGRect { CGRect(origin: screen(r.origin), size: CGSize(width: r.width * zoom, height: r.height * zoom)) }

    mutating func pan(_ delta: CGSize) {
        offset = offset + CGPoint(x: delta.width, y: delta.height)
    }

    mutating func magnify(by factor: CGFloat, around anchor: CGPoint) {
        let point = world(anchor)
        zoom = min(3, max(min(0.3, zoom), zoom * factor))
        offset = anchor - point * zoom
    }
}

enum StageSelection: Hashable {
    case node(String), edge(String), flow(String)
}

struct StageLayout {
    struct Card {
        let node: Node
        let rect: CGRect
    }

    struct Region {
        let group: StrataCore.Group
        let rect: CGRect
        /// Where the label sits (EdgeRouter.labelRect, or slid clear of edges top to bottom).
        var label: CGRect = .null
    }

    /// One drawn edge (EdgeRouter): smooth segments from the source's side to an arrow tip on the
    /// target's border, sampled by arc length so tokens move at an even pace.
    struct Route {
        let edge: StrataCore.Edge
        let path: Path
        let arrow: Path
        let samples: [CGPoint]
        private let lengths: [CGFloat]
        let labelPoint: CGPoint
        let labelWidth: CGFloat
        /// The router found its pill a spot (a bundle member's may find none on its short stretch).
        let hasPill: Bool

        init(edge: StrataCore.Edge, geometry: EdgeRoute) {
            self.edge = edge
            path = Path { p in
                p.move(to: geometry.start)
                for segment in geometry.segments {
                    switch segment {
                    case .line(let to): p.addLine(to: to)
                    case .curve(let to, let c1, let c2): p.addCurve(to: to, control1: c1, control2: c2)
                    }
                }
            }
            let tip = geometry.tip, direction = geometry.direction.normalized
            let normal = CGPoint(x: -direction.y, y: direction.x)
            let base = tip - direction * 6.5
            arrow = Path { p in
                p.move(to: base + normal * 3.2); p.addLine(to: tip); p.addLine(to: base - normal * 3.2)
            }
            samples = geometry.polyline(curveSteps: 14)
            var lengths: [CGFloat] = [0]
            for (a, b) in zip(samples, samples.dropFirst()) { lengths.append(lengths.last! + (b - a).length) }
            self.lengths = lengths
            labelWidth = geometry.label == nil ? 72 : geometry.labelWidth
            hasPill = geometry.label != nil
            labelPoint = geometry.label ?? Self.point(0.5, samples, lengths)
        }

        /// Where state pills (cut, breaker open) sit: the label's spot.
        var midpoint: CGPoint { labelPoint }

        func point(at progress: Double) -> CGPoint { Self.point(progress, samples, lengths) }

        /// The route's length along the line.
        var length: CGFloat { lengths.last ?? 0 }

        private static func point(_ progress: Double, _ samples: [CGPoint], _ lengths: [CGFloat]) -> CGPoint {
            guard let total = lengths.last, total > 0, samples.count > 1 else { return samples.first ?? .zero }
            let target = total * min(1, max(0, CGFloat(progress)))
            var lo = 0, hi = lengths.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if lengths[mid] < target { lo = mid } else { hi = mid }
            }
            let span = max(0.0001, lengths[hi] - lengths[lo])
            return samples[lo] + (samples[hi] - samples[lo]) * ((target - lengths[lo]) / span)
        }

        func distance(to point: CGPoint) -> CGFloat {
            zip(samples, samples.dropFirst()).reduce(.infinity) { nearest, segment in
                let (a, b) = segment
                let span = b - a
                let t = min(1, max(0, (point - a).dot(span) / max(1, span.dot(span))))
                return min(nearest, (point - (a + span * t)).length)
            }
        }
    }

    let cards: [Card]
    let cardsByID: [String: Card]
    let regions: [Region]
    let routes: [Route]
    let routesByID: [String: Route]
    /// Edges into one store drawn as one link (EdgeBundling, SimStageLinks.swift), the ones that found room.
    let bundles: [Bundle]
    let bundlesByID: [String: Bundle]
    let bounds: CGRect
    /// Which way the cards run, so edges leave and enter on the matching sides.
    let direction: FlowDirection
    private let obstacles: [EdgeRouter.Card]
    private let labels: [EdgeRouter.Region]

    /// The level as laid out (`at` on every node). `rects` overrides card positions, for the frames
    /// of a "Tidy layout" animation. `direction` is the way the positions run, the level's own by default.
    /// `bundles` are routed with the edges, each as one link.
    init(level: Level, rects: [String: CGRect]? = nil, direction: FlowDirection? = nil, bundles: [EdgeBundle] = []) {
        let direction = direction ?? level.direction ?? .right
        self.direction = direction
        let cards = level.nodes.enumerated().map { i, node in
            let at = node.at ?? GridPoint(Double(i % 5), Double(i / 5))
            // A taller card (one with component chips, StageLayout.cardSize) stays centred on its row, so its edges stay level.
            return Card(node: node, rect: rects?[node.id] ?? LayoutMetrics.card(for: node, at: at))
        }
        self.cards = cards
        let byID = Dictionary(cards.map { ($0.node.id, $0) }, uniquingKeysWith: { first, _ in first })
        cardsByID = byID

        let groupMembers = Dictionary(grouping: cards, by: \.node.group)
        let children = Dictionary(grouping: level.groups, by: \.parent)
        func region(_ group: StrataCore.Group, visited: Set<String>) -> CGRect {
            guard !visited.contains(group.id) else { return .null }
            var bounds = (groupMembers[group.id] ?? []).reduce(CGRect.null) { $0.union($1.rect) }
            for child in children[group.id] ?? [] {
                bounds = bounds.union(region(child, visited: visited.union([group.id])))
            }
            guard !bounds.isNull else { return .null }
            let side = LayoutMetrics.groupSide, top = LayoutMetrics.groupTop, bottom = LayoutMetrics.groupBottom
            return CGRect(x: bounds.minX - side, y: bounds.minY - top, width: bounds.width + side * 2, height: bounds.height + top + bottom)
        }
        var regions = level.groups.compactMap {
            let rect = region($0, visited: [])
            return rect.isNull ? nil : Region(group: $0, rect: rect)
        }.sorted { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }

        obstacles = cards.map { EdgeRouter.Card(id: $0.node.id, rect: $0.rect) }
        labels = regions.map { EdgeRouter.Region(rect: $0.rect, label: $0.group.label) }
        let requests = level.edges.map { Self.request($0, direction: direction) }
        let groups = Dictionary(regions.map { ($0.group.id, $0.rect) }, uniquingKeysWith: { first, _ in first })
        let bundled = EdgeRouter.routing(cards: obstacles, regions: labels, groups: groups, edges: requests, bundles: bundles,
                                         direction: direction)
        let routing = bundled.routing
        for (index, label) in routing.labels.enumerated() { regions[index].label = label }
        self.regions = regions
        let geometry = Dictionary(routing.routes.map { ($0.edge, $0) }, uniquingKeysWith: { first, _ in first })
        routes = level.edges.compactMap { edge in geometry[edge.id].map { Route(edge: edge, geometry: $0) } }
        routesByID = Dictionary(routes.map { ($0.edge.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byBundle = Dictionary(bundles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.bundles = bundled.bundles.compactMap { route in
            byBundle[route.bundle].map { bundle in
                Bundle(bundle, geometry: route, data: byID[bundle.target].map { EdgeBundling.dataKinds.contains($0.node.kind) } ?? false)
            }
        }
        bundlesByID = Dictionary(self.bundles.map { ($0.bundle.id, $0) }, uniquingKeysWith: { first, _ in first })
        var extent = cards.reduce(CGRect.null) { $0.union($1.rect) }
        extent = regions.reduce(extent) { $0.union($1.rect) }
        extent = routes.reduce(extent) { $0.union($1.path.boundingRect) }
        extent = self.bundles.reduce(extent) { $0.union($1.bounds) }
        bounds = extent.isNull ? CGRect(x: 0, y: 0, width: 168, height: 64) : extent
    }

    /// Auto layout's tracks: across each column an edge passes (stage y), or each row top to bottom (stage x).
    private static func request(_ edge: StrataCore.Edge, direction: FlowDirection) -> EdgeRouter.Request {
        EdgeRouter.Request(id: edge.id, from: edge.from, to: edge.to, label: edge.label ?? edge.protocol,
                           via: edge.via.map { direction == .down ? $0.x * LayoutMetrics.column + LayoutMetrics.origin
                                                                  : $0.y * LayoutMetrics.row + LayoutMetrics.origin })
    }

    func connect(_ id: String) -> Route? {
        guard let edge = StrataCore.Edge.diagramEdge(id), cardsByID[edge.from] != nil, cardsByID[edge.to] != nil,
              let geometry = EdgeRouter.routes(cards: obstacles, regions: labels, edges: [Self.request(edge, direction: direction)],
                                               direction: direction).first else { return nil }
        return Route(edge: edge, geometry: geometry)
    }

    /// What is under `point`: a card, a token, a pill, then the nearest line. `links` says which lines and
    /// pills are drawn now (folded members and quiet pills are not) and where a folded edge's tokens are.
    @MainActor func hit(_ point: CGPoint, camera: StageCamera, tokens: [TokenView],
             runtimeRoutes: [String: Route] = [:], links: StageLinks? = nil) -> StageSelection? {
        let world = camera.world(point)
        if let card = cards.reversed().first(where: { $0.rect.contains(world) }) { return .node(card.node.id) }
        for token in tokens.reversed() {
            guard let at = links?.point(token, in: self) ?? (routesByID[token.edge] ?? runtimeRoutes[token.edge])?.point(at: token.progress)
            else { continue }
            if (camera.screen(at) - point).length <= max(6, camera.zoom * 5) {
                return .flow(token.flow)
            }
        }
        func style(_ id: String) -> StageLinks.Style { links?.style(id) ?? .full }
        let drawn = bundles.filter { style($0.bundle.id).alpha > 0.01 }
        for bundle in drawn {
            let p = bundle.trunk.labelPoint, width = bundle.trunk.labelWidth + 6
            if CGRect(x: p.x - width / 2, y: p.y - 8, width: width, height: 16).contains(world) { return .edge(bundle.bundle.id) }
        }
        let allRoutes = (routes + runtimeRoutes.values.sorted { $0.edge.id < $1.edge.id }).filter { style($0.edge.id).alpha > 0.01 }
        for route in allRoutes where (route.edge.label != nil || route.edge.protocol != nil) && route.hasPill && style(route.edge.id).pill > 0.01 {
            let p = route.labelPoint
            let width = route.labelWidth
            if CGRect(x: p.x - width / 2, y: p.y - 8, width: width, height: 16).contains(world) {
                return .edge(route.edge.id)
            }
        }
        let radius = max(6, 10 / camera.zoom)
        var best: StageSelection?
        var nearest = radius
        for route in allRoutes where route.path.boundingRect.insetBy(dx: -radius, dy: -radius).contains(world) {
            let distance = route.distance(to: world)
            if distance <= nearest {
                nearest = distance
                best = .edge(route.edge.id)
            }
        }
        for bundle in drawn {
            for line in [bundle.trunk] + bundle.stubs.values where line.path.boundingRect.insetBy(dx: -radius, dy: -radius).contains(world) {
                let distance = line.distance(to: world)
                if distance <= nearest {
                    nearest = distance
                    best = .edge(bundle.bundle.id)
                }
            }
        }
        return best
    }
}

extension CGPoint {
    static func + (a: Self, b: Self) -> Self { Self(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: Self, b: Self) -> Self { Self(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: Self, b: CGFloat) -> Self { Self(x: a.x * b, y: a.y * b) }
    func dot(_ b: Self) -> CGFloat { x * b.x + y * b.y }
    var length: CGFloat { hypot(x, y) }
    var normalized: Self { self * (1 / max(0.001, length)) }
}

extension StrataCore.Edge {
    static func diagramEdge(_ id: String) -> Self? {
        let parts = id.components(separatedBy: "->")
        guard parts.count == 2 else { return nil }
        var edge = Self(from: parts[0], to: parts[1])
        edge.implicit = true
        return edge
    }
}

extension Simulation {
    func diagramEdge(_ id: String) -> StrataCore.Edge? {
        if let edge = level.edges.first(where: { $0.id == id }) { return edge }
        guard let edge = StrataCore.Edge.diagramEdge(id),
              value(StrataCore.Binding(.edge(from: edge.from, to: edge.to), "latency")) != nil else { return nil }
        return edge
    }
}
