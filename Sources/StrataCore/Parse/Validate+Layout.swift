import Foundation

/// Places a level and reports layout problems as warnings:
///
/// - `auto`: hints (`at`) the layout could not follow;
/// - `manual`: overlapping nodes, group regions that overlap or cover other nodes, edges whose straight
///   line runs through another node, and more than a few crossing edges.
enum LayoutValidation {
    static let crossingLimit = 3

    static func place(_ level: inout Level, at field: Field, mode: LayoutMode) {
        var nodeFields: [String: Field] = [:]
        for (node, location) in zip(level.nodes, field["nodes"].items(named: true)) where nodeFields[node.id] == nil {
            nodeFields[node.id] = location
        }
        func location(of id: String) -> Field {
            guard let node = nodeFields[id] else { return field }
            return node["at"].present ? node["at"] : node
        }

        switch mode {
        case .auto:
            var reported: Set<String> = []
            for issue in DiagramLayout.place(&level, mode: .auto) where reported.insert(issue.message).inserted {
                location(of: issue.node).diagnose(issue.message, .warning)
            }
        case .manual:
            DiagramLayout.place(&level, mode: .manual)
            for (a, b) in LayoutQuality.overlaps(level) {
                location(of: b).diagnose("'\(a)' and '\(b)' overlap; move one of them, or remove layout: manual", .warning)
            }
            var edgeFields: [String: Field] = [:]
            for (edge, location) in zip(level.edges, field["edges"].items()) { edgeFields[edge.id] = location }
            var reported: Set<String> = []
            for (edge, node) in LayoutQuality.edgesThroughNodes(level) where reported.insert(edge).inserted {
                (edgeFields[edge] ?? field).diagnose(
                    "edge \(edge.replacingOccurrences(of: "->", with: " → ")) runs straight through '\(node)'; move one of them, or remove layout: manual",
                    .warning)
            }
            var groupFields: [String: Field] = [:]
            for (group, location) in zip(level.groups, field["groups"].items(named: true)) { groupFields[group.id] = location }
            for problem in LayoutQuality.groupProblems(level) {
                (groupFields[problem.group] ?? field).diagnose(problem.message, .warning)
            }
            let crossings = LayoutQuality.straightCrossings(level)
            if crossings > crossingLimit {
                (field["edges"].present ? field["edges"] : field).diagnose(
                    "\(crossings) edges cross each other in this manual layout; consider layout: auto", .warning)
            }
        }
    }
}

/// Measures of a placed level, for validation, checks and reports. Cards are where the stage draws
/// them (LayoutMetrics); notes count as cards.
public enum LayoutQuality {
    static func cards(_ level: Level) -> [String: CGRect] {
        var rects: [String: CGRect] = [:]
        for node in level.nodes { if let at = node.at, rects[node.id] == nil { rects[node.id] = LayoutMetrics.card(for: node, at: at) } }
        return rects
    }

    /// Pairs of nodes whose cards overlap (not counting nodes at the very same position).
    public static func overlaps(_ level: Level) -> [(String, String)] {
        let placed = level.nodes.filter { $0.at != nil }
        var result: [(String, String)] = []
        for (i, a) in placed.enumerated() {
            for b in placed[(i + 1)...] where a.at != b.at {
                if LayoutMetrics.card(for: a, at: a.at!).insetBy(dx: 1, dy: 1).intersects(LayoutMetrics.card(for: b, at: b.at!)) {
                    result.append((a.id, b.id))
                }
            }
        }
        return result
    }

    /// Group regions (as the stage draws them) that overlap another group's region or cover a node
    /// that is not a member. Nested groups may contain each other.
    public static func groupProblems(_ level: Level) -> [(group: String, message: String)] {
        let rects = cards(level)
        var children: [String: [String]] = [:]
        for group in level.groups { if let parent = group.parent { children[parent, default: []].append(group.id) } }
        func members(_ id: String, _ seen: Set<String> = []) -> Set<String> {
            guard !seen.contains(id) else { return [] }
            var result = Set(level.nodes.filter { $0.group == id }.map(\.id))
            for child in children[id] ?? [] { result.formUnion(members(child, seen.union([id]))) }
            return result
        }
        func ancestors(_ id: String) -> Set<String> {
            var result: Set<String> = [], current = level.groups.first { $0.id == id }?.parent
            while let parent = current, result.insert(parent).inserted { current = level.groups.first { $0.id == parent }?.parent }
            return result
        }
        var regions: [(id: String, rect: CGRect, members: Set<String>)] = []
        for group in level.groups {
            let inside = members(group.id)
            let bounds = inside.compactMap { rects[$0] }.reduce(CGRect.null) { $0.union($1) }
            guard !bounds.isNull else { continue }
            let rect = CGRect(x: bounds.minX - LayoutMetrics.groupSide, y: bounds.minY - LayoutMetrics.groupTop,
                              width: bounds.width + LayoutMetrics.groupSide * 2,
                              height: bounds.height + LayoutMetrics.groupTop + LayoutMetrics.groupBottom)
            regions.append((group.id, rect, inside))
        }
        var result: [(String, String)] = []
        for (i, a) in regions.enumerated() {
            let covered = level.nodes.filter { !a.members.contains($0.id) && rects[$0.id].map { a.rect.insetBy(dx: 2, dy: 2).intersects($0) } == true }
            if let node = covered.first {
                result.append((a.id, "group '\(a.id)' covers '\(node.id)', which is not in it; move them apart, or remove layout: manual"))
            }
            for b in regions[(i + 1)...] where !ancestors(a.id).contains(b.id) && !ancestors(b.id).contains(a.id) {
                if a.rect.insetBy(dx: 1, dy: 1).intersects(b.rect) {
                    result.append((b.id, "groups '\(a.id)' and '\(b.id)' overlap; move their nodes apart, or remove layout: manual"))
                }
            }
        }
        return result
    }

    /// Edges whose straight line between card centres crosses a third card.
    public static func edgesThroughNodes(_ level: Level) -> [(edge: String, node: String)] {
        let rects = cards(level)
        var result: [(String, String)] = []
        for edge in level.edges where edge.from != edge.to {
            guard let a = rects[edge.from], let b = rects[edge.to] else { continue }
            let p = CGPoint(x: a.midX, y: a.midY), q = CGPoint(x: b.midX, y: b.midY)
            for node in level.nodes where node.id != edge.from && node.id != edge.to {
                guard let r = rects[node.id]?.insetBy(dx: 6, dy: 6), !a.intersects(r), !b.intersects(r) else { continue }
                if segment(p, q, crosses: r) { result.append((edge.id, node.id)); break }
            }
        }
        return result
    }

    /// Pairs of edges (not sharing a node) whose straight lines between card centres cross.
    public static func straightCrossings(_ level: Level) -> Int {
        let rects = cards(level)
        let lines = level.edges.compactMap { edge -> (String, String, [CGPoint])? in
            guard edge.from != edge.to, let a = rects[edge.from], let b = rects[edge.to] else { return nil }
            return (edge.from, edge.to, [CGPoint(x: a.midX, y: a.midY), CGPoint(x: b.midX, y: b.midY)])
        }
        return crossings(lines)
    }

    /// Pairs of polylines (not sharing an end node) that cross.
    public static func crossings(_ paths: [(from: String, to: String, points: [CGPoint])]) -> Int {
        var count = 0
        let boxes = paths.map { path in path.points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) } }
        for i in paths.indices {
            for j in paths.indices where j > i {
                let a = paths[i], b = paths[j]
                if Set([a.from, a.to]).intersection([b.from, b.to]).isEmpty == false { continue }
                guard boxes[i].insetBy(dx: -1, dy: -1).intersects(boxes[j]) else { continue }
                if polylines(a.points, b.points) { count += 1 }
            }
        }
        return count
    }

    /// Whether a polyline passes through a rectangle.
    public static func polyline(_ points: [CGPoint], crosses rect: CGRect) -> Bool {
        zip(points, points.dropFirst()).contains { segment($0, $1, crosses: rect) }
    }

    static func polylines(_ a: [CGPoint], _ b: [CGPoint]) -> Bool {
        for (p1, p2) in zip(a, a.dropFirst()) {
            for (q1, q2) in zip(b, b.dropFirst()) where segments(p1, p2, q1, q2) { return true }
        }
        return false
    }

    static func segments(_ p1: CGPoint, _ p2: CGPoint, _ q1: CGPoint, _ q2: CGPoint) -> Bool {
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        let d1 = cross(q1, q2, p1), d2 = cross(q1, q2, p2), d3 = cross(p1, p2, q1), d4 = cross(p1, p2, q2)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }

    static func segment(_ p: CGPoint, _ q: CGPoint, crosses r: CGRect) -> Bool {
        if r.contains(p) || r.contains(q) { return true }
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                       CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        return (0..<4).contains { segments(p, q, corners[$0], corners[($0 + 1) % 4]) }
    }
}
