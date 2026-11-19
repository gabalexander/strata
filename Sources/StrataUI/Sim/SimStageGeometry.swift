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

    struct Route {
        let edge: StrataCore.Edge
        let start: CGPoint
        let control1: CGPoint
        let control2: CGPoint
        let end: CGPoint
        let path: Path
        let arrow: Path
        let samples: [CGPoint]
        let labelWidth: CGFloat

        init(edge: StrataCore.Edge, from: CGRect, to: CGRect, lane: CGFloat) {
            self.edge = edge
            if edge.from == edge.to {
                start = CGPoint(x: from.maxX, y: from.midY - 8)
                end = CGPoint(x: to.midX + 32, y: to.minY - 4)
                control1 = start + CGPoint(x: 76 + lane, y: 0)
                control2 = end - CGPoint(x: 0, y: 75 + lane)
                labelWidth = 72
            } else {
                let dx = to.midX - from.midX
                let dy = to.midY - from.midY
                let horizontal = abs(dx) > from.width + 26 || abs(dy) < from.height + 16
                let direction: CGFloat = (horizontal ? dx : dy) >= 0 ? 1 : -1
                let out = horizontal ? CGPoint(x: direction, y: 0) : CGPoint(x: 0, y: direction)
                let sideways = horizontal ? CGPoint(x: 0, y: 1) : CGPoint(x: 1, y: 0)
                let reach = horizontal ? from.width / 2 : from.height / 2
                let gap = max(8, abs(horizontal ? dx : dy) - reach * 2)
                let splay = horizontal ? min(15, max(-15, dy * 0.12)) : min(20, max(-20, dx * 0.12))
                start = from.center + out * reach + sideways * (lane + splay)
                end = to.center - out * (reach + 4) + sideways * (lane - splay * 0.35)
                let bend = min(260, max(16, gap * 0.55))
                control1 = start + out * bend
                control2 = end - out * bend
                labelWidth = min(98, max(38, (horizontal ? gap : abs(dx) + 42) - 9))
            }
            let start = self.start, end = self.end
            let control1 = self.control1, control2 = self.control2
            path = Path { p in
                p.move(to: start)
                p.addCurve(to: end, control1: control1, control2: control2)
            }
            let tangent = (end - control2).normalized
            let normal = CGPoint(x: -tangent.y, y: tangent.x)
            let base = end - tangent * 6
            arrow = Path { p in
                p.move(to: base + normal * 3); p.addLine(to: end); p.addLine(to: base - normal * 3)
            }
            samples = (0...24).map { Self.bezier(Double($0) / 24, start, control1, control2, end) }
        }

        var midpoint: CGPoint { samples[12] }

        var labelPoint: CGPoint {
            abs(start.y - end.y) < 5 ? midpoint + CGPoint(x: 0, y: -12) : midpoint
        }

        func point(at progress: Double) -> CGPoint {
            Self.bezier(progress, start, control1, control2, end)
        }

        func distance(to point: CGPoint) -> CGFloat {
            zip(samples, samples.dropFirst()).reduce(.infinity) { nearest, segment in
                let (a, b) = segment
                let span = b - a
                let t = min(1, max(0, (point - a).dot(span) / max(1, span.dot(span))))
                return min(nearest, (point - (a + span * t)).length)
            }
        }

        private static func bezier(_ t: CGFloat, _ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> CGPoint {
            let s = 1 - t
            return a * (s * s * s) + b * (3 * s * s * t) + c * (3 * s * t * t) + d * (t * t * t)
        }
    }

    let cards: [Card]
    let cardsByID: [String: Card]
    let regions: [Region]
    let routes: [Route]
    let routesByID: [String: Route]
    let bounds: CGRect

    init(level: Level) {
        let cards = level.nodes.enumerated().map { i, node in
            let at = node.at ?? GridPoint(Double(i % 5), Double(i / 5))
            let size = StageLayout.cardSize(for: node)
            // A taller card (one with component chips) stays centred on its row, so its edges stay level.
            return Card(node: node, rect: CGRect(x: at.x * 220 + 36, y: at.y * 130 + 36 - (size.height - 64) / 2,
                                                 width: size.width, height: size.height))
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
            return CGRect(x: bounds.minX - 16, y: bounds.minY - 29, width: bounds.width + 32, height: bounds.height + 45)
        }
        regions = level.groups.compactMap {
            let rect = region($0, visited: [])
            return rect.isNull ? nil : Region(group: $0, rect: rect)
        }.sorted { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }

        let parallel = Dictionary(grouping: level.edges) { [$0.from, $0.to].sorted() }
        var laneIndices: [[String]: Int] = [:]
        routes = level.edges.compactMap { edge in
            guard let from = byID[edge.from]?.rect, let to = byID[edge.to]?.rect else { return nil }
            let pair = [edge.from, edge.to].sorted()
            let count = parallel[pair]?.count ?? 1
            let index = laneIndices[pair, default: 0]
            laneIndices[pair] = index + 1
            let spread = min(20, 52 / CGFloat(max(1, count - 1)))
            let lane = (CGFloat(index) - CGFloat(count - 1) / 2) * spread
            return Route(edge: edge, from: from, to: to, lane: lane)
        }
        routesByID = Dictionary(routes.map { ($0.edge.id, $0) }, uniquingKeysWith: { first, _ in first })
        var extent = cards.reduce(CGRect.null) { $0.union($1.rect) }
        extent = regions.reduce(extent) { $0.union($1.rect) }
        extent = routes.reduce(extent) { $0.union($1.path.boundingRect) }
        bounds = extent.isNull ? CGRect(x: 0, y: 0, width: 168, height: 64) : extent
    }

    func connect(_ id: String) -> Route? {
        guard let edge = StrataCore.Edge.diagramEdge(id), let from = cardsByID[edge.from]?.rect,
              let to = cardsByID[edge.to]?.rect else { return nil }
        return Route(edge: edge, from: from, to: to, lane: 0)
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

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
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
