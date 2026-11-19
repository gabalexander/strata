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
            labelPoint = geometry.label ?? Self.point(0.5, samples, lengths)
        }

        /// Where state pills (cut, breaker open) sit: the label's spot.
        var midpoint: CGPoint { labelPoint }

        func point(at progress: Double) -> CGPoint { Self.point(progress, samples, lengths) }

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
    let bounds: CGRect
    private let obstacles: [EdgeRouter.Card]
    private let labels: [EdgeRouter.Region]

    /// The level as laid out (`at` on every node). `rects` overrides card positions, for the frames
    /// of a "Tidy layout" animation.
    init(level: Level, rects: [String: CGRect]? = nil) {
        let cards = level.nodes.enumerated().map { i, node in
            let at = node.at ?? GridPoint(Double(i % 5), Double(i / 5))
            return Card(node: node, rect: rects?[node.id] ?? LayoutMetrics.card(at: at))
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
        regions = level.groups.compactMap {
            let rect = region($0, visited: [])
            return rect.isNull ? nil : Region(group: $0, rect: rect)
        }.sorted { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }

        obstacles = cards.map { EdgeRouter.Card(id: $0.node.id, rect: $0.rect) }
        labels = regions.map { EdgeRouter.Region(rect: $0.rect, label: $0.group.label) }
        let requests = level.edges.map { Self.request($0) }
        let geometry = Dictionary(EdgeRouter.routes(cards: obstacles, regions: labels, edges: requests).map { ($0.edge, $0) },
                                  uniquingKeysWith: { first, _ in first })
        routes = level.edges.compactMap { edge in geometry[edge.id].map { Route(edge: edge, geometry: $0) } }
        routesByID = Dictionary(routes.map { ($0.edge.id, $0) }, uniquingKeysWith: { first, _ in first })
        var extent = cards.reduce(CGRect.null) { $0.union($1.rect) }
        extent = regions.reduce(extent) { $0.union($1.rect) }
        extent = routes.reduce(extent) { $0.union($1.path.boundingRect) }
        bounds = extent.isNull ? CGRect(x: 0, y: 0, width: 168, height: 64) : extent
    }

    private static func request(_ edge: StrataCore.Edge) -> EdgeRouter.Request {
        EdgeRouter.Request(id: edge.id, from: edge.from, to: edge.to, label: edge.label ?? edge.protocol,
                           via: edge.via.map { $0.y * LayoutMetrics.row + LayoutMetrics.origin })
    }

    func connect(_ id: String) -> Route? {
        guard let edge = StrataCore.Edge.diagramEdge(id), cardsByID[edge.from] != nil, cardsByID[edge.to] != nil,
              let geometry = EdgeRouter.routes(cards: obstacles, regions: labels, edges: [Self.request(edge)]).first else { return nil }
        return Route(edge: edge, geometry: geometry)
    }

    func hit(_ point: CGPoint, camera: StageCamera, tokens: [TokenView],
             runtimeRoutes: [String: Route] = [:]) -> StageSelection? {
        let world = camera.world(point)
        if let card = cards.reversed().first(where: { $0.rect.contains(world) }) { return .node(card.node.id) }
        for token in tokens.reversed() {
            guard let route = routesByID[token.edge] ?? runtimeRoutes[token.edge] else { continue }
            if (camera.screen(route.point(at: token.progress)) - point).length <= max(6, camera.zoom * 5) {
                return .flow(token.flow)
            }
        }
        let allRoutes = routes + runtimeRoutes.values.sorted { $0.edge.id < $1.edge.id }
        for route in allRoutes where route.edge.label != nil || route.edge.protocol != nil {
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
