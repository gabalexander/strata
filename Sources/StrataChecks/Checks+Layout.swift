import Foundation
import StrataCore

// Auto layout (DiagramLayout) and edge routing (EdgeRouter): placement, groups, crossings against the
// old layout, determinism, timing, and the layout warnings.

@MainActor func layoutChecks() -> [CheckCase] {
    [
        CheckCase(name: "layout places every level without overlapping cards") {
            for sample in try layoutSamples() {
                let rects = cardRects(sample.level)
                check(rects.count == sample.level.nodes.count, "\(sample.name): unplaced nodes")
                for (i, a) in rects.enumerated() {
                    for b in rects[(i + 1)...] where a.rect.insetBy(dx: 1, dy: 1).intersects(b.rect) {
                        check(false, "\(sample.name): \(a.id) overlaps \(b.id)")
                    }
                }
            }
        },
        CheckCase(name: "layout keeps group regions clear of non-members and nests groups") {
            for sample in try layoutSamples() {
                let level = sample.level
                let regions = groupRegions(level)
                let cards = cardRects(level)
                for group in level.groups {
                    guard let region = regions[group.id] else { continue }
                    let members = groupMembers(group.id, in: level)
                    for card in cards where !members.contains(card.id) && region.intersects(card.rect) {
                        check(false, "\(sample.name): \(card.id) sits inside group \(group.id)")
                    }
                    if let parent = group.parent, let outer = regions[parent] {
                        check(outer.contains(region), "\(sample.name): group \(group.id) is not inside \(parent)")
                    }
                    for other in level.groups where other.id < group.id && other.parent == group.parent {
                        guard let second = regions[other.id] else { continue }
                        check(!region.intersects(second), "\(sample.name): groups \(group.id) and \(other.id) overlap")
                    }
                }
            }
        },
        CheckCase(name: "layout draws chains, trees and fans without crossings") {
            for (name, text) in [("chain", chainManifest(8)), ("tree", treeManifest(depth: 4)), ("fan", fanManifest(6)),
                                 ("grouped tree", treeManifest(depth: 3, grouped: true))] {
                guard let manifest = parsed(text) else { check(false, "\(name) did not parse"); continue }
                check(crossings(routedLines(manifest.root)) == 0, "\(name): \(crossings(routedLines(manifest.root))) crossings")
                for edge in manifest.root.edges {
                    let from = manifest.root.node(edge.from)?.at?.x ?? 0, to = manifest.root.node(edge.to)?.at?.x ?? 0
                    check(from < to, "\(name): \(edge.id) does not run left to right")
                }
            }
            // A chain is one straight line.
            if let chain = parsed(chainManifest(8)) {
                check(Set(chain.root.nodes.compactMap { $0.at?.y }).count == 1, "chain is not straight")
            }
        },
        CheckCase(name: "layout crosses no more edges than the old layout on every example") {
            var rows: [String] = []
            for sample in try layoutSamples(includeGenerated: false) {
                guard let old = sample.legacy else { continue }
                let before = crossings(legacyLines(old)), after = crossings(routedLines(sample.level))
                let through = throughCards(legacyLines(old), old, old: true)
                rows.append("\(sample.name) \(before)→\(after)" + (through > 0 ? " (old: \(through) through cards)" : ""))
                // The messy company map is not bundled; the old layout "avoided" crossings by drawing
                // edges through cards, so it is reported, not compared.
                if !sample.name.hasPrefix("messy") {
                    check(after <= before, "\(sample.name): \(after) crossings, the old layout had \(before)")
                }
                check(throughCards(routedLines(sample.level), sample.level) == 0, "\(sample.name): an edge runs through a card")
            }
            print("Layout crossings, old→new: " + rows.joined(separator: ", "))
        },
        CheckCase(name: "layout routes never run through cards and end on the target's border") {
            for sample in try layoutSamples() {
                let cards = cardRects(sample.level)
                let byID = Dictionary(cards.map { ($0.id, $0.rect) }, uniquingKeysWith: { a, _ in a })
                for route in routes(sample.level) {
                    let edge = sample.level.edges.first { $0.id == route.edge }!
                    let line = route.polyline(curveSteps: 16)
                    for card in cards where card.id != edge.from && card.id != edge.to {
                        check(!LayoutQuality.polyline(line, crosses: card.rect.insetBy(dx: 1, dy: 1)),
                              "\(sample.name): \(route.edge) runs through \(card.id)")
                    }
                    guard let target = byID[edge.to], edge.from != edge.to else { continue }
                    let onBorder = (abs(route.tip.x - target.minX) < 0.5 || abs(route.tip.x - target.maxX) < 0.5 ||
                                    abs(route.tip.y - target.minY) < 0.5 || abs(route.tip.y - target.maxY) < 0.5)
                        && target.insetBy(dx: -0.5, dy: -0.5).contains(route.tip)
                    check(onBorder, "\(sample.name): \(route.edge) does not end on \(edge.to)'s border")
                    let inside = CGPoint(x: route.tip.x + route.direction.x * 4, y: route.tip.y + route.direction.y * 4)
                    check(target.contains(inside), "\(sample.name): \(route.edge)'s arrow does not point into \(edge.to)")
                }
            }
        },
        CheckCase(name: "layout keeps parallel and opposite edges apart and labels clear") {
            guard let manifest = parsed("""
                nodes:
                  - { id: a, kind: service }
                  - { id: b, kind: service }
                  - { id: c, kind: database }
                edges:
                  - { from: a, to: b, label: request }
                  - { from: b, to: a, label: callback }
                  - { from: b, to: c, protocol: sql }
                """) else { check(false, "pair did not parse"); return }
            let lines = routes(manifest.root)
            let ab = lines.first { $0.edge == "a->b" }!.polyline(), ba = lines.first { $0.edge == "b->a" }!.polyline()
            let gap = ab.map { p in ba.map { hypot($0.x - p.x, $0.y - p.y) }.min()! }.min()!
            check(gap >= 8, "opposite edges stack: \(gap) pt apart")
            for sample in try layoutSamples() {
                let cards = cardRects(sample.level).map(\.rect)
                let labels = routes(sample.level).compactMap { route in
                    route.label.map { CGRect(x: $0.x - route.labelWidth / 2, y: $0.y - 8, width: route.labelWidth, height: 16) }
                }
                for (i, label) in labels.enumerated() {
                    check(!cards.contains { $0.insetBy(dx: 1, dy: 1).intersects(label) }, "\(sample.name): a label covers a card")
                    for other in labels[(i + 1)...] where other.insetBy(dx: 2, dy: 2).intersects(label) {
                        check(false, "\(sample.name): two labels overlap at \(Int(label.midX)),\(Int(label.midY))")
                    }
                }
            }
        },
        CheckCase(name: "layout is deterministic") {
            let first = try layoutSamples(), second = try layoutSamples()
            check(first.count == second.count, "sample count changed")
            for (a, b) in zip(first, second) {
                check(a.level.nodes.map(\.at) == b.level.nodes.map(\.at), "\(a.name): positions changed on a second run")
                check(a.level.edges.map(\.via) == b.level.edges.map(\.via), "\(a.name): edge tracks changed on a second run")
                check(routes(a.level).map(\.label) == routes(b.level).map(\.label), "\(a.name): labels moved on a second run")
            }
        },
        CheckCase(name: "layout places 60 nodes in under 10 ms (release build)") {
            guard let manifest = parsed(generatedManifest(nodes: 60, seed: 7)) else { check(false, "60-node fixture"); return }
            var level = manifest.root
            for index in level.nodes.indices { level.nodes[index].at = nil }
            var layout: [Double] = [], routing: [Double] = []
            for _ in 0..<7 {
                var start = Date()
                let placed = DiagramLayout.tidy(level)
                layout.append(Date().timeIntervalSince(start) * 1000)
                start = Date()
                _ = routes(placed)
                routing.append(Date().timeIntervalSince(start) * 1000)
            }
            let median = layout.sorted()[3], route = routing.sorted()[3]
            print(String(format: "Layout of 60 nodes, %d edges: %.2f ms; routing %.2f ms", level.edges.count, median, route))
            check(median < limit(10), String(format: "layout took %.2f ms", median))
        },
        CheckCase(name: "layout warns about manual overlaps, edges through nodes, crossings and contradictory hints") {
            let manual = ManifestParser.parse(messyManifest(manual: true), source: .file(URL(fileURLWithPath: "/tmp/messy.yaml"))).1
            check(manual.contains { $0.message.contains("overlap") } == false, "unexpected overlap warning: \(manual)")
            check(manual.contains { $0.message.contains("runs straight through") }, "missing edge-through-node warning")
            check(manual.contains { $0.message.contains("consider layout: auto") }, "missing crossings warning")
            let overlap = ManifestParser.parse(layoutHeader + """
                layout: manual
                nodes: [{id: a, kind: service, at: [0, 0]}, {id: b, kind: service, at: [0.3, 0.2]}]
                """, source: .file(URL(fileURLWithPath: "/tmp/overlap.yaml"))).1
            check(overlap.contains { $0.severity == .warning && $0.message.contains("overlap") }, "missing overlap warning: \(overlap)")
            let auto = ManifestParser.parse(messyManifest(manual: false), source: .file(URL(fileURLWithPath: "/tmp/messy.yaml"))).1
            check(auto.isEmpty, "auto layout should not warn without hints: \(auto)")
            let hinted = ManifestParser.parse(layoutHeader + """
                nodes: [{id: a, kind: client, at: [2, 0]}, {id: b, kind: service, at: [0, 0]}]
                edges: [{from: a, to: b}]
                """, source: .file(URL(fileURLWithPath: "/tmp/hints.yaml"))).1
            check(hinted.contains { $0.severity == .warning && $0.message.contains("left of 'a'") }, "missing hint warning: \(hinted)")
        },
        CheckCase(name: "layout tidies a manual level and puts notes in a free corner") {
            guard let manifest = parsed(messyManifest(manual: true)) else { check(false, "messy fixture"); return }
            let before = crossings(routedLines(manifest.root))
            let tidy = DiagramLayout.tidy(manifest.root)
            let after = crossings(routedLines(tidy))
            check(after < before, "tidy layout did not reduce crossings: \(before) → \(after)")
            check(LayoutQuality.overlaps(tidy).isEmpty, "tidy layout overlaps cards")
            guard let noted = parsed(chainManifest(4) + "\n  - { id: memo, kind: note, doc: Read me }") else { check(false, "note fixture"); return }
            let note = LayoutMetrics.card(at: noted.root.node("memo")!.at!)
            let others = cardRects(noted.root).filter { $0.id != "memo" }.map(\.rect)
            check(!others.contains { $0.insetBy(dx: -10, dy: -10).intersects(note) }, "the note crowds a card")
        },
    ]
}

/// The limit holds for release builds (the app); checks usually run as a debug build, which is about
/// 12× slower here, so they allow 15×.
private func limit(_ milliseconds: Double) -> Double {
    #if DEBUG
    milliseconds * 15
    #else
    milliseconds
    #endif
}

// MARK: - Samples

private struct LayoutSample {
    let name: String
    let level: Level
    let legacy: Level?
}

private let layoutHeader = "strata: 1\nid: layout-check\ntitle: Layout check\n"

private func parsed(_ text: String) -> Manifest? {
    let full = text.hasPrefix("strata:") ? text : layoutHeader + text
    let (manifest, diagnostics) = ManifestParser.parse(full, source: .file(URL(fileURLWithPath: "/tmp/layout-check.yaml")))
    if manifest == nil { print(diagnostics) }
    return manifest
}

/// Every level of every bundled example (with the same text laid out the old way: `layout: manual`
/// keeps hand positions and fills the rest with the old algorithm), the messy company map, and
/// generated graphs.
private func layoutSamples(includeGenerated: Bool = true) throws -> [LayoutSample] {
    var texts: [(String, String)] = []
    let directory = try requiredResource("Examples")
    for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter({ $0.pathExtension == "yaml" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        texts.append((url.deletingPathExtension().lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
    }
    texts.append(("messy-shop", messyManifest(manual: false)))
    if includeGenerated {
        for seed in 1...4 { texts.append(("generated-\(seed)", generatedManifest(nodes: 12 + seed * 6, seed: UInt64(seed)))) }
    }
    var samples: [LayoutSample] = []
    for (name, text) in texts {
        guard let manifest = parsed(text) else { check(false, "\(name) did not parse"); continue }
        let old = parsed(text.replacingOccurrences(of: "\nlayout: auto", with: "").replacingOccurrences(of: "strata: 1\n", with: "strata: 1\nlayout: manual\n"))
        for (path, level) in levels(manifest.root, path: name) {
            let legacy = old.flatMap { levels($0.root, path: name).first { $0.0 == path }?.1 }
            samples.append(LayoutSample(name: path, level: level, legacy: legacy))
        }
    }
    return samples
}

private func levels(_ level: Level, path: String) -> [(String, Level)] {
    var result = [(path, level)]
    for node in level.nodes {
        if let inside = node.inside { result += levels(inside, path: "\(path)/\(node.id)") }
        for op in node.ops { if let inside = op.inside { result += levels(inside, path: "\(path)/\(node.id)#\(op.id)") } }
    }
    return result
}

// MARK: - Geometry

private func cardRects(_ level: Level) -> [(id: String, rect: CGRect)] {
    level.nodes.compactMap { node in node.at.map { (node.id, LayoutMetrics.card(at: $0)) } }
}

private func groupMembers(_ group: String, in level: Level) -> Set<String> {
    var groups: Set<String> = [group]
    var changed = true
    while changed {
        changed = false
        for g in level.groups where g.parent.map(groups.contains) == true && groups.insert(g.id).inserted { changed = true }
    }
    return Set(level.nodes.filter { $0.group.map(groups.contains) ?? false }.map(\.id))
}

/// The regions the stage draws (StageLayout): members' cards, nested regions, and padding.
private func groupRegions(_ level: Level) -> [String: CGRect] {
    let cards = Dictionary(cardRects(level).map { ($0.id, $0.rect) }, uniquingKeysWith: { a, _ in a })
    func region(_ id: String, _ visited: Set<String>) -> CGRect {
        guard !visited.contains(id) else { return .null }
        var bounds = level.nodes.filter { $0.group == id }.compactMap { cards[$0.id] }.reduce(CGRect.null) { $0.union($1) }
        for child in level.groups where child.parent == id { bounds = bounds.union(region(child.id, visited.union([id]))) }
        guard !bounds.isNull else { return .null }
        return CGRect(x: bounds.minX - LayoutMetrics.groupSide, y: bounds.minY - LayoutMetrics.groupTop,
                      width: bounds.width + LayoutMetrics.groupSide * 2,
                      height: bounds.height + LayoutMetrics.groupTop + LayoutMetrics.groupBottom)
    }
    var result: [String: CGRect] = [:]
    for group in level.groups {
        let rect = region(group.id, [])
        if !rect.isNull { result[group.id] = rect }
    }
    return result
}

/// The routes the stage draws for a level.
private func routes(_ level: Level) -> [EdgeRoute] {
    let cards = cardRects(level).map { EdgeRouter.Card(id: $0.id, rect: $0.rect) }
    let regions = groupRegions(level)
    let labels = level.groups.compactMap { group in regions[group.id].map { EdgeRouter.Region(rect: $0, label: group.label) } }
    let requests = level.edges.map { edge in
        EdgeRouter.Request(id: edge.id, from: edge.from, to: edge.to, label: edge.label ?? edge.protocol,
                           via: edge.via.map { $0.y * LayoutMetrics.row + LayoutMetrics.origin })
    }
    return EdgeRouter.routes(cards: cards, regions: labels, edges: requests)
}

private func routedLines(_ level: Level) -> [(from: String, to: String, points: [CGPoint])] {
    let byID = Dictionary(level.edges.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    return routes(level).compactMap { route in
        byID[route.edge].map { ($0.from, $0.to, route.polyline(curveSteps: 16)) }
    }
}

/// The old stage's edges: a cubic between card sides on a 220 × 130 grid, parallel edges in lanes.
private func legacyLines(_ level: Level) -> [(from: String, to: String, points: [CGPoint])] {
    var rects: [String: CGRect] = [:]
    for (i, node) in level.nodes.enumerated() {
        let at = node.at ?? GridPoint(Double(i % 5), Double(i / 5))
        rects[node.id] = CGRect(x: at.x * 220 + 36, y: at.y * 130 + 36, width: 168, height: 64)
    }
    let parallel = Dictionary(grouping: level.edges) { [$0.from, $0.to].sorted() }
    var lanes: [[String]: Int] = [:]
    return level.edges.compactMap { edge in
        guard edge.from != edge.to, let from = rects[edge.from], let to = rects[edge.to] else { return nil }
        let pair = [edge.from, edge.to].sorted()
        let count = parallel[pair]?.count ?? 1
        let index = lanes[pair, default: 0]
        lanes[pair] = index + 1
        let lane = (CGFloat(index) - CGFloat(count - 1) / 2) * min(20, 52 / CGFloat(max(1, count - 1)))
        let dx = to.midX - from.midX, dy = to.midY - from.midY
        let horizontal = abs(dx) > from.width + 26 || abs(dy) < from.height + 16
        let direction: CGFloat = (horizontal ? dx : dy) >= 0 ? 1 : -1
        let out = horizontal ? CGPoint(x: direction, y: 0) : CGPoint(x: 0, y: direction)
        let sideways = horizontal ? CGPoint(x: 0, y: 1) : CGPoint(x: 1, y: 0)
        let reach = horizontal ? from.width / 2 : from.height / 2
        let gap = max(8, abs(horizontal ? dx : dy) - reach * 2)
        let splay = horizontal ? min(15, max(-15, dy * 0.12)) : min(20, max(-20, dx * 0.12))
        func add(_ a: CGPoint, _ b: CGPoint, _ k: CGFloat) -> CGPoint { CGPoint(x: a.x + b.x * k, y: a.y + b.y * k) }
        let start = add(add(CGPoint(x: from.midX, y: from.midY), out, reach), sideways, lane + splay)
        let end = add(add(CGPoint(x: to.midX, y: to.midY), out, -(reach + 4)), sideways, lane - splay * 0.35)
        let bend = min(260, max(16, gap * 0.55))
        let c1 = add(start, out, bend), c2 = add(end, out, -bend)
        let points = (0...24).map { i -> CGPoint in
            let t = CGFloat(i) / 24, s = 1 - t
            return CGPoint(x: start.x * s * s * s + c1.x * 3 * s * s * t + c2.x * 3 * s * t * t + end.x * t * t * t,
                           y: start.y * s * s * s + c1.y * 3 * s * s * t + c2.y * 3 * s * t * t + end.y * t * t * t)
        }
        return (edge.from, edge.to, points)
    }
}

private func crossings(_ lines: [(from: String, to: String, points: [CGPoint])]) -> Int {
    LayoutQuality.crossings(lines)
}

/// Edges whose drawn line crosses a card other than their own ends (old cards on the old grid).
private func throughCards(_ lines: [(from: String, to: String, points: [CGPoint])], _ level: Level, old: Bool = false) -> Int {
    let rects = level.nodes.enumerated().map { i, node -> (String, CGRect) in
        let at = node.at ?? GridPoint(Double(i % 5), Double(i / 5))
        return (node.id, old ? CGRect(x: at.x * 220 + 36, y: at.y * 130 + 36, width: 168, height: 64) : LayoutMetrics.card(at: at))
    }
    return lines.filter { line in
        rects.contains { $0.0 != line.from && $0.0 != line.to && LayoutQuality.polyline(line.points, crosses: $0.1.insetBy(dx: 2, dy: 2)) }
    }.count
}

// MARK: - Fixtures

private func chainManifest(_ count: Int) -> String {
    let nodes = (0..<count).map { "  - { id: n\($0), kind: \($0 == 0 ? "client" : "service") }" }.joined(separator: "\n")
    let edges = (1..<count).map { "  - { from: n\($0 - 1), to: n\($0), protocol: grpc }" }.joined(separator: "\n")
    return "edges:\n\(edges)\nnodes:\n\(nodes)"
}

private func treeManifest(depth: Int, grouped: Bool = false) -> String {
    var nodes = ["  - { id: t1, kind: client }"], edges: [String] = []
    var groups: [String] = []
    for i in 2..<(1 << depth) {
        var top = i
        while top > 3 { top /= 2 }
        let group = grouped && i >= 2 ? ", group: g\(top % 2)" : ""
        nodes.append("  - { id: t\(i), kind: service\(group) }")
        edges.append("  - { from: t\(i / 2), to: t\(i), label: call \(i) }")
    }
    if grouped { groups = ["groups:", "  - { id: g0, label: Even }", "  - { id: g1, label: Odd }"] }
    return (groups + ["nodes:"] + nodes + ["edges:"] + edges).joined(separator: "\n")
}

private func fanManifest(_ count: Int) -> String {
    let nodes = ["  - { id: src, kind: client }", "  - { id: hub, kind: gateway }"]
        + (0..<count).map { "  - { id: s\($0), kind: service }" }
    let edges = ["  - { from: src, to: hub }"] + (0..<count).map { "  - { from: hub, to: s\($0), protocol: http }" }
    return (["nodes:"] + nodes + ["edges:"] + edges).joined(separator: "\n")
}

/// A layered graph with groups, a few long edges and a back edge, from a fixed seed.
private func generatedManifest(nodes count: Int, seed: UInt64) -> String {
    var state = seed &* 6364136223846793005 &+ 1442695040888963407
    func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }
    let kinds = ["service", "service", "worker", "database", "cache", "queue"]
    var nodes = ["  - { id: n0, kind: client }"], edges: [String] = []
    var seen: Set<String> = []
    for i in 1..<count {
        let group = i % 5 == 0 ? "" : ", group: g\(i * 3 / count)"
        nodes.append("  - { id: n\(i), kind: \(kinds[next(kinds.count)])\(group) }")
        let from = max(0, i - 1 - next(min(i, 6)))
        if seen.insert("\(from)-\(i)").inserted { edges.append("  - { from: n\(from), to: n\(i), protocol: grpc }") }
        if i > 4 && next(3) == 0 {
            let other = next(i)
            if seen.insert("\(other)-\(i)").inserted { edges.append("  - { from: n\(other), to: n\(i) }") }
        }
    }
    edges.append("  - { from: n\(count - 1), to: n\(count / 2), label: back }")
    let groups = ["groups:", "  - { id: g0, label: Edge }", "  - { id: g1, label: Core, kind: cluster }",
                  "  - { id: g2, label: Data, kind: vpc }"]
    return (groups + ["nodes:"] + nodes + ["edges:"] + edges).joined(separator: "\n")
}

/// The company map an agent drew: 14 nodes, two groups, Kafka with two consumers, a cron and an
/// external API. `manual` keeps the agent's scattered positions.
private func messyManifest(manual: Bool) -> String {
    func at(_ x: Int, _ y: Int) -> String { manual ? ", at: [\(x), \(y)]" : "" }
    return """
        strata: 1
        id: messy-shop
        title: Shop platform
        kind: architecture
        \(manual ? "layout: manual" : "")
        groups:
          - { id: services, label: Shop services (EKS), kind: cluster }
          - { id: data, label: Managed data (AWS), kind: vpc }
        nodes:
          - { id: postgres, kind: database, label: shop-db, group: data\(at(1, 0)) }
          - { id: orders-api, kind: service, group: services\(at(3, 2)) }
          - { id: app, kind: client, label: Mobile app\(at(0, 2)) }
          - { id: kafka, kind: topic, label: shop-events, group: data\(at(2, 3)) }
          - { id: billing-worker, kind: worker, group: services\(at(4, 0)) }
          - { id: gateway, kind: gateway, label: api-gateway\(at(1, 2)) }
          - { id: valkey, kind: cache, group: data\(at(4, 3)) }
          - { id: catalog-api, kind: service, group: services\(at(2, 1)) }
          - { id: stripe, kind: external, label: Stripe\(at(0, 0)) }
          - { id: orders-worker, kind: worker, group: services\(at(3, 0)) }
          - { id: billing-api, kind: service, group: services\(at(2, 2)) }
          - { id: cron, kind: cron, label: nightly-reindex\(at(4, 1)) }
          - { id: catalog-sync, kind: worker, group: services\(at(3, 1)) }
          - { id: admin, kind: user, label: Ops console\(at(0, 3)) }
        edges:
          - { from: app, to: gateway, protocol: https }
          - { from: admin, to: gateway, protocol: https }
          - { from: gateway, to: orders-api, protocol: grpc }
          - { from: gateway, to: catalog-api, protocol: grpc }
          - { from: gateway, to: billing-api, protocol: grpc }
          - { from: orders-api, to: catalog-api, protocol: grpc, label: GetPrice }
          - { from: orders-api, to: postgres, protocol: sql }
          - { from: orders-api, to: valkey, protocol: redis, label: idempotency }
          - { from: orders-api, to: kafka, protocol: kafka, label: OrderPlaced }
          - { from: catalog-api, to: valkey, protocol: redis }
          - { from: catalog-api, to: postgres, protocol: sql }
          - { from: billing-api, to: postgres, protocol: sql }
          - { from: billing-api, to: stripe, protocol: https, label: refunds }
          - { from: stripe, to: billing-api, protocol: https, label: webhooks }
          - { from: kafka, to: billing-worker, label: order-events }
          - { from: kafka, to: orders-worker, label: payment-events }
          - { from: billing-worker, to: stripe, protocol: https, label: charge }
          - { from: billing-worker, to: kafka, protocol: kafka, label: PaymentCaptured }
          - { from: billing-worker, to: postgres, protocol: sql }
          - { from: orders-worker, to: postgres, protocol: sql }
          - { from: cron, to: catalog-sync, label: "0 3 * * *" }
          - { from: catalog-sync, to: postgres, protocol: sql }
          - { from: catalog-sync, to: valkey, protocol: redis, label: warm prices }
        """
}
