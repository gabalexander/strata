import Foundation

/// One drawn edge: a start point and smooth segments ending with the arrow tip on the target's border.
public struct EdgeRoute: Sendable {
    public enum Segment: Sendable, Equatable {
        case line(to: CGPoint)
        case curve(to: CGPoint, control1: CGPoint, control2: CGPoint)

        public var end: CGPoint {
            switch self {
            case .line(let to), .curve(let to, _, _): to
            }
        }
    }

    public let edge: String
    public let start: CGPoint
    public let segments: [Segment]
    /// The arrow tip (on the target card's border) and the unit direction the arrow points.
    public let tip: CGPoint
    public let direction: CGPoint
    /// Where the label pill sits, and the width it may take there without covering a card.
    public var label: CGPoint?
    public var labelWidth: CGFloat = 0

    /// The route mirrored across the diagonal (x and y swapped), label included.
    var transposed: EdgeRoute {
        let segments = segments.map { segment -> Segment in
            switch segment {
            case .line(let to): .line(to: to.transposed)
            case .curve(let to, let c1, let c2): .curve(to: to.transposed, control1: c1.transposed, control2: c2.transposed)
            }
        }
        return EdgeRoute(edge: edge, start: start.transposed, segments: segments, tip: tip.transposed,
                         direction: direction.transposed, label: label?.transposed, labelWidth: labelWidth)
    }

    /// The route as points: lines as they are, curves split into `curveSteps` pieces.
    public func polyline(curveSteps: Int = 12) -> [CGPoint] {
        var points = [start]
        var current = start
        for segment in segments {
            switch segment {
            case .line(let to):
                points.append(to)
            case .curve(let to, let c1, let c2):
                for i in 1...curveSteps {
                    points.append(EdgeRouter.bezier(CGFloat(i) / CGFloat(curveSteps), current, c1, c2, to))
                }
            }
            current = segment.end
        }
        return points
    }
}

/// Routes edges around cards on the stage, for any placement (auto or manual):
///
/// - Cards that overlap horizontally form a column; the space between columns is a channel, and the
///   free space between cards in a column is a gap.
/// - An edge leaves its source's side facing the target, crosses each channel with one smooth
///   S-bend, and passes intermediate columns through gaps, choosing the gaps with the least vertical
///   travel, bends and crowding. So it never runs through a card.
/// - Edges ending on the same side of a card get separate ports, ordered by where they head, and
///   edges sharing a gap get separate tracks: parallel and opposite edges run side by side.
/// - Edges within a column go straight down when nothing is between, otherwise around the side.
/// - Labels take the spot along their edge that covers no card and no other label, nearest the middle
///   of the edge's longest straight run or its middle bend.
///
/// A top-to-bottom level (`direction: down`) is routed in the transposed frame, where its rows are
/// columns, and transposed back: edges leave a card's bottom, cross each gap between rows with one
/// S-bend, and edges within a row run sideways. Labels stay horizontal text, so they are placed after
/// transposing back.
public enum EdgeRouter {
    public struct Card: Sendable {
        public let id: String
        public let rect: CGRect
        public init(id: String, rect: CGRect) { self.id = id; self.rect = rect }
    }

    public struct Region: Sendable {
        public let rect: CGRect
        public let label: String
        public init(rect: CGRect, label: String) { self.rect = rect; self.label = label }
    }

    public struct Request: Sendable {
        public let id: String
        public let from: String
        public let to: String
        public let label: String?
        /// Where auto layout reserved this edge's track in each column it passes (stage y), if it did; in
        /// each row it passes (stage x) for a top-to-bottom level.
        public let via: [CGFloat]
        public init(id: String, from: String, to: String, label: String?, via: [CGFloat] = []) {
            self.id = id; self.from = from; self.to = to; self.label = label; self.via = via
        }
    }

    static let clearance: CGFloat = 12
    static let trackSpacing: CGFloat = 12
    static let portSpacing: CGFloat = 12
    static let maxLabel: CGFloat = 160

    struct Column {
        var x0: CGFloat
        var x1: CGFloat
        var cards: [Int]
        var gaps: [(lo: CGFloat, hi: CGFloat)] = []
    }

    enum Side: Int { case left, right, top, bottom }

    enum Plan {
        case loop
        case vertical(down: Bool)
        case around
        case through(columns: [Int], gaps: [Int], forward: Bool)
    }

    /// Routed edges, and where each region's label sits (in the order of `regions`).
    public struct Routing: Sendable {
        public let routes: [EdgeRoute]
        public let labels: [CGRect]
    }

    public static func routes(cards: [Card], regions: [Region] = [], edges: [Request],
                              direction: FlowDirection = .right) -> [EdgeRoute] {
        routing(cards: cards, regions: regions, edges: edges, direction: direction).routes
    }

    public static func routing(cards: [Card], regions: [Region] = [], edges: [Request],
                               direction: FlowDirection = .right) -> Routing {
        var labelRects = regions.map(labelRect)
        var (routes, plans) = geometry(cards: direction == .down ? cards.map { Card(id: $0.id, rect: $0.rect.transposed) } : cards,
                                       labels: direction == .down ? labelRects.map(\.transposed) : labelRects, edges: edges)
        if direction == .down {
            // Loops keep their usual shape, over the card's top right corner.
            let rects = Dictionary(cards.map { ($0.id, $0.rect) }, uniquingKeysWith: { first, _ in first })
            let sources = Dictionary(edges.map { ($0.id, $0.from) }, uniquingKeysWith: { first, _ in first })
            for i in routes.indices {
                if case .loop = plans[i], let rect = sources[routes[i].edge].flatMap({ rects[$0] }) {
                    routes[i] = loop(routes[i].edge, rect)
                } else {
                    routes[i] = routes[i].transposed
                }
            }
        }

        let lines = routes.map { $0.polyline(curveSteps: 10) }
        // Top to bottom, edges enter a group through the band that holds its label: the label moves along
        // the band to where no line crosses it.
        if direction == .down {
            for index in regions.indices { labelRects[index] = clearLabel(labelRects[index], in: regions[index].rect, lines: lines) }
        }

        // 5. Labels, once every line is known: off cards, off other labels, and off other lines when possible.
        var placed: [CGRect] = []
        let obstacles = cards.map(\.rect)
        for index in routes.indices {
            guard let request = edges.first(where: { $0.id == routes[index].edge }), let text = request.label, !text.isEmpty else { continue }
            let others = lines.indices.filter { $0 != index }.map { lines[$0] }
            placeLabel(&routes[index], width: min(maxLabel, CGFloat(LayoutMetrics.pillWidth(text))), plan: plans[index],
                       obstacles: obstacles, labels: labelRects, lines: others, placed: &placed)
        }
        return Routing(routes: routes, labels: labelRects)
    }

    /// The leftmost spot in the region's top band where `label` crosses no line, or `label` itself.
    static func clearLabel(_ label: CGRect, in region: CGRect, lines: [[CGPoint]]) -> CGRect {
        var blocked: [(lo: CGFloat, hi: CGFloat)] = []
        for line in lines {
            for (a, b) in zip(line, line.dropFirst()) where max(a.y, b.y) >= label.minY && min(a.y, b.y) <= label.maxY {
                // The part of the segment inside the band.
                func x(at y: CGFloat) -> CGFloat { abs(b.y - a.y) < 0.001 ? a.x : a.x + (b.x - a.x) * (y - a.y) / (b.y - a.y) }
                let top = min(max(label.minY, min(a.y, b.y)), label.maxY), bottom = max(min(label.maxY, max(a.y, b.y)), label.minY)
                let xs = abs(b.y - a.y) < 0.001 ? [a.x, b.x] : [x(at: top), x(at: bottom)]
                blocked.append((xs.min()! - 5, xs.max()! + 5))
            }
        }
        let first = region.minX + 8, last = region.maxX - 8 - label.width
        guard last >= first else { return label }
        for x in ([first] + blocked.map(\.hi)).sorted() where x >= first && x <= last {
            if !blocked.contains(where: { $0.hi > x && $0.lo < x + label.width }) {
                return CGRect(x: x, y: label.minY, width: label.width, height: label.height)
            }
        }
        return label
    }

    /// Steps 1 to 4 for cards placed left to right: each edge's plan and its drawn route.
    private static func geometry(cards: [Card], labels labelRects: [CGRect], edges: [Request]) -> ([EdgeRoute], [Plan]) {
        var index: [String: Int] = [:]
        for (i, card) in cards.enumerated() where index[card.id] == nil { index[card.id] = i }
        let columns = makeColumns(cards, labels: labelRects)
        var columnOf = Array(repeating: 0, count: cards.count)
        for (c, column) in columns.enumerated() { for card in column.cards { columnOf[card] = c } }

        // 1. Plans: which columns and gaps each edge passes.
        var plans: [Plan?] = []
        var usage: [[Int]: Int] = [:]
        for edge in edges {
            guard let u = index[edge.from], let v = index[edge.to] else { plans.append(nil); continue }
            if u == v { plans.append(.loop); continue }
            let a = cards[u].rect, b = cards[v].rect
            let cu = columnOf[u], cv = columnOf[v]
            if cu == cv {
                let lo = min(a.maxY, b.maxY), hi = max(a.minY, b.minY)
                let between = columns[cu].cards.contains { c in
                    c != u && c != v && cards[c].rect.maxY > lo && cards[c].rect.minY < hi
                }
                plans.append(between || hi <= lo ? .around : .vertical(down: b.midY > a.midY))
                continue
            }
            let forward = cu < cv
            let through = forward ? Array((cu + 1)..<cv) : Array(((cv + 1)..<cu).reversed())
            let gaps = reserved(edge.via, through, columns: columns)
                ?? choose(through, columns: columns, from: a.midY, to: b.midY, usage: usage)
            for (c, g) in zip(through, gaps) { usage[[c, g], default: 0] += 1 }
            plans.append(.through(columns: through, gaps: gaps, forward: forward))
        }

        // 2. Ports: each end gets its own spot on its card's side, ordered by where the edge heads.
        struct End { let edge: Int; let start: Bool; let approach: CGFloat }
        var sides: [[Int]: [End]] = [:]
        func trackY(_ y: CGFloat, _ column: Int, _ gap: Int) -> CGFloat {
            let g = columns[column].gaps[gap]
            return min(max(y, g.lo + clearance), g.hi - clearance)
        }
        for (e, plan) in plans.enumerated() {
            guard let plan, let u = index[edges[e].from], let v = index[edges[e].to] else { continue }
            let a = cards[u].rect, b = cards[v].rect
            switch plan {
            case .loop: continue
            case .vertical(let down):
                sides[[u, (down ? Side.bottom : .top).rawValue], default: []].append(End(edge: e, start: true, approach: b.midX))
                sides[[v, (down ? Side.top : .bottom).rawValue], default: []].append(End(edge: e, start: false, approach: a.midX))
            case .around:
                sides[[u, Side.right.rawValue], default: []].append(End(edge: e, start: true, approach: b.midY))
                sides[[v, Side.right.rawValue], default: []].append(End(edge: e, start: false, approach: a.midY))
            case .through(let through, let gaps, let forward):
                var first = b.midY, last = a.midY
                let via = edges[e].via.count == through.count ? edges[e].via : []
                if let c = through.first, let g = gaps.first { first = trackY(via.first ?? a.midY, c, g) }
                if let c = through.last, let g = gaps.last { last = trackY(via.last ?? first, c, g) }
                sides[[u, (forward ? Side.right : .left).rawValue], default: []].append(End(edge: e, start: true, approach: first))
                sides[[v, (forward ? Side.left : .right).rawValue], default: []].append(End(edge: e, start: false, approach: last))
            }
        }
        var ports: [[Int]: CGPoint] = [:]      // [edge, 0 start / 1 end]
        for key in sides.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            let ends = sides[key]!.sorted { ($0.approach, $0.edge, $0.start ? 0 : 1) < ($1.approach, $1.edge, $1.start ? 0 : 1) }
            let rect = cards[key[0]].rect
            let side = Side(rawValue: key[1])!
            let vertical = side == .left || side == .right
            let length = vertical ? rect.height : rect.width
            let half = (length - (vertical ? 24 : 48)) / 2
            let middle = vertical ? rect.midY : rect.midX
            // A port sits level with where its edge heads when that is on this side, so edges between
            // aligned cards run straight; the rest keep to the side's ends; then they spread apart.
            let wanted = ends.map { end -> CGFloat in
                let offset = end.approach - middle
                if abs(offset) <= half { return end.approach }
                return ends.count == 1 ? middle : middle + (offset > 0 ? half : -half)
            }
            // Closer ports are fine when that keeps an edge between aligned cards straight.
            var placed = spread(wanted, within: middle - half, middle + half, spacing: portSpacing)
            let aligned = ends.indices.filter { abs(ends[$0].approach - middle) <= half }
            if aligned.contains(where: { abs(placed[$0] - wanted[$0]) > 0.5 }) {
                let tighter = spread(wanted, within: middle - half, middle + half, spacing: portSpacing * 0.7)
                if aligned.allSatisfy({ abs(tighter[$0] - wanted[$0]) <= 0.5 }) { placed = tighter }
            }
            for (i, end) in ends.enumerated() {
                let offset = placed[i] - middle
                let point: CGPoint = switch side {
                case .left: CGPoint(x: rect.minX, y: rect.midY + offset)
                case .right: CGPoint(x: rect.maxX, y: rect.midY + offset)
                case .top: CGPoint(x: rect.midX + offset, y: rect.minY)
                case .bottom: CGPoint(x: rect.midX + offset, y: rect.maxY)
                }
                ports[[end.edge, end.start ? 0 : 1]] = point
            }
        }

        // 3. Tracks: edges sharing a gap spread out around where they want to pass.
        var wanted: [[Int]: [(edge: Int, step: Int, y: CGFloat)]] = [:]
        for (e, plan) in plans.enumerated() {
            guard case .through(let through, let gaps, _)? = plan, let start = ports[[e, 0]] else { continue }
            let via = edges[e].via.count == through.count ? edges[e].via : []
            var y = start.y
            for (step, (c, g)) in zip(through, gaps).enumerated() {
                y = trackY(via.isEmpty ? y : via[step], c, g)
                wanted[[c, g], default: []].append((e, step, y))
            }
        }
        var tracks: [[Int]: CGFloat] = [:]   // [edge, step]
        for key in wanted.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            let gap = columns[key[0]].gaps[key[1]]
            let items = wanted[key]!.sorted { a, b in
                let pa = ports[[a.edge, 0]]?.y ?? 0, pb = ports[[b.edge, 0]]?.y ?? 0
                return (a.y, pa, a.edge) < (b.y, pb, b.edge)
            }
            let ys = spread(items.map(\.y), within: gap.lo + clearance, gap.hi - clearance)
            for (item, y) in zip(items, ys) { tracks[[item.edge, item.step]] = y }
        }

        // 4. Geometry.
        var routes: [EdgeRoute] = []
        var routePlans: [Plan] = []
        for (e, plan) in plans.enumerated() {
            guard let plan, let u = index[edges[e].from], let v = index[edges[e].to] else { continue }
            let a = cards[u].rect
            var route: EdgeRoute
            switch plan {
            case .loop:
                route = loop(edges[e].id, a)
            case .vertical(let down):
                let s = ports[[e, 0]]!, t = ports[[e, 1]]!
                let bend = max(18, abs(t.y - s.y) * 0.5)
                route = EdgeRoute(edge: edges[e].id, start: s,
                                  segments: [.curve(to: t, control1: CGPoint(x: s.x, y: s.y + (down ? bend : -bend)),
                                                    control2: CGPoint(x: t.x, y: t.y - (down ? bend : -bend)))],
                                  tip: t, direction: CGPoint(x: 0, y: down ? 1 : -1))
            case .around:
                let s = ports[[e, 0]]!, t = ports[[e, 1]]!
                let reach = columns[columnOf[u]].x1 + 26 + CGFloat(e % 3) * 6
                route = EdgeRoute(edge: edges[e].id, start: s,
                                  segments: [.curve(to: t, control1: CGPoint(x: reach + (reach - s.x) * 0.35, y: s.y),
                                                    control2: CGPoint(x: reach + (reach - t.x) * 0.35, y: t.y))],
                                  tip: t, direction: CGPoint(x: -1, y: 0))
            case .through(let through, _, let forward):
                let s = ports[[e, 0]]!, t = ports[[e, 1]]!
                let sign: CGFloat = forward ? 1 : -1
                var segments: [EdgeRoute.Segment] = []
                var current = s
                func move(to point: CGPoint) {
                    if abs(point.y - current.y) < 0.5 {
                        if abs(point.x - current.x) > 0.5 { segments.append(.line(to: CGPoint(x: point.x, y: current.y))) }
                    } else {
                        let half = (point.x - current.x) / 2
                        segments.append(.curve(to: point, control1: CGPoint(x: current.x + half, y: current.y),
                                               control2: CGPoint(x: point.x - half, y: point.y)))
                    }
                    current = CGPoint(x: point.x, y: abs(point.y - current.y) < 0.5 ? current.y : point.y)
                }
                // Leave the source's column, cross each channel, pass each column on its track.
                let home = columns[columnOf[u]]
                move(to: CGPoint(x: forward ? max(s.x, home.x1) : min(s.x, home.x0), y: s.y))
                for (step, c) in through.enumerated() {
                    let y = tracks[[e, step]] ?? current.y
                    let column = columns[c]
                    move(to: CGPoint(x: forward ? column.x0 : column.x1, y: y))
                    move(to: CGPoint(x: forward ? column.x1 : column.x0, y: y))
                }
                let away = columns[columnOf[v]]
                move(to: CGPoint(x: forward ? min(t.x, away.x0) : max(t.x, away.x1), y: t.y))
                move(to: t)
                route = EdgeRoute(edge: edges[e].id, start: s, segments: segments, tip: t, direction: CGPoint(x: sign, y: 0))
            }
            routes.append(route)
            routePlans.append(plan)
        }
        return (routes, routePlans)
    }

    // MARK: - Columns and gaps

    static func makeColumns(_ cards: [Card], labels: [CGRect]) -> [Column] {
        var columns: [Column] = []
        for i in cards.indices.sorted(by: { (cards[$0].rect.minX, $0) < (cards[$1].rect.minX, $1) }) {
            let r = cards[i].rect
            if var last = columns.last, r.minX < last.x1 + 8 {
                last.x1 = max(last.x1, r.maxX)
                last.cards.append(i)
                columns[columns.count - 1] = last
            } else {
                columns.append(Column(x0: r.minX, x1: r.maxX, cards: [i]))
            }
        }
        for c in columns.indices {
            // Free space between cards (and group labels); a track keeps `clearance` from both ends.
            var blocked = columns[c].cards.map { (cards[$0].rect.minY, cards[$0].rect.maxY) }
            for label in labels where label.maxX > columns[c].x0 && label.minX < columns[c].x1 {
                blocked.append((label.minY, label.maxY))
            }
            blocked.sort { $0.0 < $1.0 }
            var gaps: [(lo: CGFloat, hi: CGFloat)] = []
            var cursor: CGFloat = -1_000_000
            for (top, bottom) in blocked {
                if top > cursor { gaps.append((cursor, top)) }
                cursor = max(cursor, bottom)
            }
            gaps.append((cursor, 1_000_000))
            columns[c].gaps = gaps
        }
        return columns
    }

    /// The gaps holding the tracks auto layout reserved, when every one still lies in a gap.
    static func reserved(_ via: [CGFloat], _ through: [Int], columns: [Column]) -> [Int]? {
        guard !through.isEmpty, via.count == through.count else { return nil }
        var gaps: [Int] = []
        for (y, c) in zip(via, through) {
            guard let g = columns[c].gaps.firstIndex(where: { y >= $0.lo + clearance - 2 && y <= $0.hi - clearance + 2 }) else { return nil }
            gaps.append(g)
        }
        return gaps
    }

    /// The cheapest gap in each column an edge passes: vertical travel, bends and crowding.
    static func choose(_ through: [Int], columns: [Column], from y0: CGFloat, to y1: CGFloat,
                       usage: [[Int]: Int]) -> [Int] {
        guard !through.isEmpty else { return [] }
        struct State { var cost: CGFloat; var y: CGFloat; var path: [Int] }
        let bend: CGFloat = 26
        func step(_ y: CGFloat, _ c: Int, _ g: Int) -> (CGFloat, CGFloat) {
            let gap = columns[c].gaps[g]
            let lo = gap.lo + clearance, hi = gap.hi - clearance
            let next = hi < lo ? (gap.lo + gap.hi) / 2 : min(max(y, lo), hi)
            let cramped: CGFloat = hi < lo ? 400 : 0
            return (next, abs(next - y) + (abs(next - y) > 0.5 ? bend : 0) + cramped + CGFloat(usage[[c, g], default: 0]) * 6)
        }
        var states = [State(cost: 0, y: y0, path: [])]
        for c in through {
            var next: [State] = []
            for g in columns[c].gaps.indices {
                var best: State?
                for state in states {
                    let (y, cost) = step(state.y, c, g)
                    let candidate = State(cost: state.cost + cost, y: y, path: state.path + [g])
                    if best.map({ candidate.cost < $0.cost - 1e-9 }) ?? true { best = candidate }
                }
                if let best { next.append(best) }
            }
            states = next
        }
        let finished = states.map { state in
            State(cost: state.cost + abs(y1 - state.y) + (abs(y1 - state.y) > 0.5 ? bend : 0), y: y1, path: state.path)
        }
        return finished.min { a, b in
            abs(a.cost - b.cost) > 1e-9 ? a.cost < b.cost : a.path.lexicographicallyPrecedes(b.path)
        }?.path ?? []
    }

    /// Positions as close to `wanted` (sorted) as possible, at least `trackSpacing` apart, within lo...hi.
    static func spread(_ wanted: [CGFloat], within lo: CGFloat, _ hi: CGFloat, spacing preferred: CGFloat = trackSpacing) -> [CGFloat] {
        guard !wanted.isEmpty else { return [] }
        let room = max(0, hi - lo)
        let spacing = wanted.count > 1 ? min(preferred, room / CGFloat(wanted.count - 1)) : 0
        // Runs that sit too close merge into evenly spaced blocks centred where they wanted to be.
        var blocks: [(start: Int, count: Int, center: CGFloat)] = []
        for (i, y) in wanted.enumerated() {
            blocks.append((i, 1, min(max(y, lo), max(lo, hi))))
            while blocks.count > 1 {
                let b = blocks[blocks.count - 1], a = blocks[blocks.count - 2]
                let aLast = a.center + spacing * CGFloat(a.count - 1) / 2
                let bFirst = b.center - spacing * CGFloat(b.count - 1) / 2
                guard bFirst - aLast < spacing - 0.01 else { break }
                let count = a.count + b.count
                let center = (a.center * CGFloat(a.count) + b.center * CGFloat(b.count)) / CGFloat(count)
                blocks.removeLast(2)
                blocks.append((a.start, count, center))
            }
        }
        var ys = wanted
        for block in blocks {
            for k in 0..<block.count {
                ys[block.start + k] = block.center - spacing * CGFloat(block.count - 1) / 2 + spacing * CGFloat(k)
            }
        }
        // Then inside lo...hi: push down from the top, then up from the bottom.
        ys[0] = max(ys[0], lo)
        for i in ys.indices.dropFirst() { ys[i] = max(ys[i], ys[i - 1] + spacing) }
        ys[ys.count - 1] = min(ys[ys.count - 1], max(lo, hi))
        for i in ys.indices.dropLast().reversed() { ys[i] = min(ys[i], ys[i + 1] - spacing) }
        return ys.map { min(max($0, lo), max(lo, hi)) }
    }

    // MARK: - Shapes

    static func loop(_ id: String, _ r: CGRect) -> EdgeRoute {
        let start = CGPoint(x: r.maxX, y: r.midY - 8)
        let tip = CGPoint(x: r.maxX - 30, y: r.minY)
        return EdgeRoute(edge: id, start: start,
                         segments: [.curve(to: tip, control1: CGPoint(x: r.maxX + 58, y: start.y),
                                           control2: CGPoint(x: tip.x, y: r.minY - 62))],
                         tip: tip, direction: CGPoint(x: 0, y: 1),
                         label: CGPoint(x: r.maxX + 14, y: r.minY - 30), labelWidth: 72)
    }

    static func bezier(_ t: CGFloat, _ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> CGPoint {
        let s = 1 - t
        let x = a.x * s * s * s + b.x * 3 * s * s * t + c.x * 3 * s * t * t + d.x * t * t * t
        let y = a.y * s * s * s + b.y * 3 * s * s * t + c.y * 3 * s * t * t + d.y * t * t * t
        return CGPoint(x: x, y: y)
    }

    static func labelRect(_ region: Region) -> CGRect {
        CGRect(x: region.rect.minX + 8, y: region.rect.minY + 3, width: CGFloat(region.label.count) * 6.4 + 14, height: 22)
    }

    // MARK: - Labels

    /// Picks the spot along the route for the label: no card, no other label, nearest the preferred
    /// spot (the middle of the longest straight run, or of the middle bend), and as little truncation as possible.
    static func placeLabel(_ route: inout EdgeRoute, width: CGFloat, plan: Plan, obstacles: [CGRect], labels: [CGRect],
                           lines: [[CGPoint]], placed: inout [CGRect]) {
        let boxes = lines.map { line in line.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) } }
        if case .loop = plan { placed.append(CGRect(x: route.label!.x - 36, y: route.label!.y - 8, width: 72, height: 16)); return }
        let points = route.polyline(curveSteps: 24)
        var lengths: [CGFloat] = [0]
        for (a, b) in zip(points, points.dropFirst()) { lengths.append(lengths.last! + hypot(b.x - a.x, b.y - a.y)) }
        let total = lengths.last!
        guard total > 1 else { return }

        // The preferred spot: the longest straight horizontal run that fits the label, else the middle.
        var preferred = total / 2
        var bestRun: CGFloat = 0
        var cursor = route.start, travelled: CGFloat = 0
        for (index, segment) in route.segments.enumerated() {
            let length: CGFloat
            switch segment {
            case .line(let to):
                length = hypot(to.x - cursor.x, to.y - cursor.y)
                let isStub = index == 0 || index == route.segments.count - 1
                if !isStub && length > bestRun && length >= width + 16 { bestRun = length; preferred = travelled + length / 2 }
            case .curve(let to, let c1, let c2):
                var l: CGFloat = 0, p = cursor
                for i in 1...24 {
                    let q = bezier(CGFloat(i) / 24, cursor, c1, c2, to)
                    l += hypot(q.x - p.x, q.y - p.y); p = q
                }
                length = l
            }
            travelled += length
            cursor = segment.end
        }
        if bestRun == 0, case .through(let through, _, _) = plan, !through.isEmpty {
            preferred = total / 2
        }

        func point(at s: CGFloat) -> CGPoint {
            var i = 1
            while i < lengths.count - 1 && lengths[i] < s { i += 1 }
            let span = max(0.001, lengths[i] - lengths[i - 1])
            let t = (s - lengths[i - 1]) / span
            return CGPoint(x: points[i - 1].x + (points[i].x - points[i - 1].x) * t, y: points[i - 1].y + (points[i].y - points[i - 1].y) * t)
        }

        // Cheap terms first (distance from the preferred spot, truncation, cards, labels) for spots
        // every 4 pt; then other lines only for the dozen best.
        var candidates: [(score: CGFloat, center: CGPoint, width: CGFloat)] = []
        let margin: CGFloat = min(14, total / 4)
        var s = margin
        while s <= total - margin {
            let p = point(at: s)
            var left = width / 2, right = width / 2
            for r in obstacles where r.minY < p.y + 10 && r.maxY > p.y - 10 {
                if r.maxX <= p.x + 1 { left = min(left, p.x - r.maxX - 4) }
                else if r.minX >= p.x - 1 { right = min(right, r.minX - p.x - 4) }
                else { left = -1; right = -1 }
            }
            let fit = min(width, max(0, min(left, right)) * 2)
            var score = abs(s - preferred) * 0.6 + (width - fit) * 12
            if fit < min(width, 34) { score += 2_000 }
            let rect = CGRect(x: p.x - fit / 2, y: p.y - 8, width: fit, height: 16)
            for other in placed where other.insetBy(dx: -3, dy: -2).intersects(rect) { score += 900 }
            for label in labels where label.intersects(rect) { score += 300 }
            candidates.append((score, p, fit))
            s += 4
        }
        candidates.sort { ($0.score, $0.center.x, $0.center.y) < ($1.score, $1.center.x, $1.center.y) }
        var best: (score: CGFloat, center: CGPoint, width: CGFloat)?
        for candidate in candidates.prefix(12) {
            var score = candidate.score
            let pill = CGRect(x: candidate.center.x - candidate.width / 2 - 2, y: candidate.center.y - 9,
                              width: candidate.width + 4, height: 18)
            for (line, box) in zip(lines, boxes) where box.intersects(pill) && LayoutQuality.polyline(line, crosses: pill) { score += 45 }
            if best.map({ score < $0.score }) ?? true { best = (score, candidate.center, candidate.width) }
        }
        guard let best else { return }
        route.label = best.center
        route.labelWidth = max(best.width, 24)
        placed.append(CGRect(x: best.center.x - route.labelWidth / 2, y: best.center.y - 8, width: route.labelWidth, height: 16))
    }
}

extension CGPoint {
    /// Mirrored across the diagonal: x and y swapped.
    var transposed: CGPoint { CGPoint(x: y, y: x) }
}

extension CGRect {
    /// Mirrored across the diagonal: the frame a top-to-bottom level is routed and laid out in.
    var transposed: CGRect { CGRect(x: minY, y: minX, width: height, height: width) }
}
