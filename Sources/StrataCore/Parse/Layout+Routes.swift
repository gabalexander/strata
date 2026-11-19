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
        /// Where auto layout reserved this edge's track in each column it passes (stage y), if it did.
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

    public static func routes(cards: [Card], regions: [Region] = [], edges: [Request]) -> [EdgeRoute] {
        var index: [String: Int] = [:]
        for (i, card) in cards.enumerated() where index[card.id] == nil { index[card.id] = i }
        let labelRects = regions.map(labelRect)
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
            let length = side == .left || side == .right ? rect.height : rect.width
            let room = length - (side == .left || side == .right ? 24 : 48)
            let spacing = ends.count > 1 ? min(portSpacing, room / CGFloat(ends.count - 1)) : 0
            for (i, end) in ends.enumerated() {
                let offset = (CGFloat(i) - CGFloat(ends.count - 1) / 2) * spacing
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
        var placed: [CGRect] = []
        let obstacles = cards.map(\.rect)
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

        // 5. Labels, once every line is known: off cards, off other labels, and off other lines when possible.
        let lines = routes.map { $0.polyline(curveSteps: 10) }
        for index in routes.indices {
            guard let request = edges.first(where: { $0.id == routes[index].edge }), let text = request.label, !text.isEmpty else { continue }
            let others = lines.indices.filter { $0 != index }.map { lines[$0] }
            placeLabel(&routes[index], width: min(maxLabel, CGFloat(LayoutMetrics.pillWidth(text))), plan: routePlans[index],
                       obstacles: obstacles, labels: labelRects, lines: others, placed: &placed)
        }
        return routes
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
    static func spread(_ wanted: [CGFloat], within lo: CGFloat, _ hi: CGFloat) -> [CGFloat] {
        guard !wanted.isEmpty else { return [] }
        let room = max(0, hi - lo)
        let spacing = wanted.count > 1 ? min(trackSpacing, room / CGFloat(wanted.count - 1)) : 0
        var ys = wanted
        // Push apart around the mean of each cluster, then keep inside the gap.
        for _ in 0..<wanted.count {
            var moved = false
            var i = 0
            while i < ys.count - 1 {
                var j = i
                while j + 1 < ys.count && ys[j + 1] - ys[j] < spacing - 0.01 { j += 1 }
                if j > i {
                    let mean = ys[i...j].reduce(0, +) / CGFloat(j - i + 1)
                    let center = wanted[i...j].reduce(0, +) / CGFloat(j - i + 1)
                    let start = min(mean, center) - spacing * CGFloat(j - i) / 2
                    for k in i...j { ys[k] = start + spacing * CGFloat(k - i) }
                    moved = true
                }
                i = j + 1
            }
            if !moved { break }
        }
        if let first = ys.first, first < lo { ys = ys.map { $0 + (lo - first) } }
        if let last = ys.last, last > hi, room > 0 { ys = ys.map { $0 - (last - hi) } }
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

        var best: (score: CGFloat, center: CGPoint, width: CGFloat)?
        let margin: CGFloat = min(14, total / 4)
        var s = margin
        while s <= total - margin {
            let p = point(at: s)
            // The widest pill here that stays off cards.
            var left = width / 2, right = width / 2
            for r in obstacles where r.minY < p.y + 10 && r.maxY > p.y - 10 {
                if r.maxX <= p.x + 1 { left = min(left, p.x - r.maxX - 4) }
                else if r.minX >= p.x - 1 { right = min(right, r.minX - p.x - 4) }
                else { left = -1; right = -1 }
            }
            let fit = max(0, min(left, right)) * 2
            var score = abs(s - preferred) * 0.6 + (width - min(width, fit)) * 12
            if fit < min(width, 34) { score += 2_000 }
            let rect = CGRect(x: p.x - min(width, fit) / 2, y: p.y - 8, width: min(width, fit), height: 16)
            for other in placed where other.insetBy(dx: -3, dy: -2).intersects(rect) { score += 900 }
            for label in labels where label.intersects(rect) { score += 300 }
            let pill = rect.insetBy(dx: -2, dy: -1)
            for (line, box) in zip(lines, boxes) where box.intersects(pill) && LayoutQuality.polyline(line, crosses: pill) { score += 45 }
            if best.map({ score < $0.score }) ?? true { best = (score, p, min(width, fit)) }
            s += 3
        }
        guard let best else { return }
        route.label = best.center
        route.labelWidth = max(best.width, 24)
        placed.append(CGRect(x: best.center.x - route.labelWidth / 2, y: best.center.y - 8, width: route.labelWidth, height: 16))
    }
}
