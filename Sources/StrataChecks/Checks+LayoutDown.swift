import Foundation
import StrataCore

// Top-to-bottom layout (`direction: down`, and the stage's vertical/horizontal switch): every example and
// fixture laid out down, against the same level laid out left to right (helpers in Checks+Layout.swift).

@MainActor func verticalLayoutChecks() -> [CheckCase] {
    [
        CheckCase(name: "vertical layout places every level without overlaps, keeps groups clear and sources on top") {
            for sample in try verticalSamples() {
                let level = sample.level
                let rects = cardRects(level)
                check(rects.count == level.nodes.count, "\(sample.name): unplaced nodes")
                for (i, a) in rects.enumerated() {
                    for b in rects[(i + 1)...] where a.rect.insetBy(dx: 1, dy: 1).intersects(b.rect) {
                        check(false, "\(sample.name): \(a.id) overlaps \(b.id)")
                    }
                }
                let regions = groupRegions(level)
                for group in level.groups {
                    guard let region = regions[group.id] else { continue }
                    let members = groupMembers(group.id, in: level)
                    for card in rects where !members.contains(card.id) && region.intersects(card.rect) {
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
                // Sources (and ports nothing calls) start the top row; every edge outside a cycle runs down or sideways.
                let diagram = level.nodes.filter { $0.kind.role != .annotation }
                let top = diagram.compactMap { $0.at?.y }.min() ?? 0
                for node in diagram where node.kind.role == .source || (node.kind == .port && !level.edges.contains { $0.to == node.id }) {
                    check(abs((node.at?.y ?? -1) - top) < 0.001, "\(sample.name): source \(node.id) is not in the top row")
                }
                for edge in level.edges where edge.from != edge.to && !reaches(edge.to, edge.from, in: level) {
                    guard let a = level.node(edge.from)?.at, let b = level.node(edge.to)?.at else { continue }
                    check(a.y <= b.y + 0.001, "\(sample.name): \(edge.id) runs up")
                }
            }
        },
        CheckCase(name: "vertical layout routes never run through cards, end on the target's border and keep labels clear") {
            for sample in try verticalSamples() {
                let level = sample.level
                let cards = cardRects(level)
                let byID = Dictionary(cards.map { ($0.id, $0.rect) }, uniquingKeysWith: { a, _ in a })
                let routed = routing(level, .down)
                for route in routed.routes {
                    let edge = level.edges.first { $0.id == route.edge }!
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
                let pills = routed.routes.compactMap { route in
                    route.label.map { CGRect(x: $0.x - route.labelWidth / 2, y: $0.y - 8, width: route.labelWidth, height: 16) }
                }
                for (i, pill) in pills.enumerated() {
                    check(!cards.contains { $0.rect.insetBy(dx: 1, dy: 1).intersects(pill) }, "\(sample.name): a label covers a card")
                    for other in pills[(i + 1)...] where other.insetBy(dx: 2, dy: 2).intersects(pill) {
                        check(false, "\(sample.name): two labels overlap at \(Int(pill.midX)),\(Int(pill.midY))")
                    }
                }
                // A group's label stays in its region's top band, clear of the lines when there is room.
                let regions = groupRegions(level)
                let bands = level.groups.compactMap { regions[$0.id] }
                for (label, region) in zip(routed.labels, bands) {
                    check(abs(label.minY - region.minY - 3) < 0.5 && label.minX >= region.minX && label.maxX <= region.maxX,
                          "\(sample.name): a group label left its region's top band")
                }
            }
        },
        CheckCase(name: "vertical layout crosses no more edges than horizontal on every example") {
            var rows: [String] = []
            for sample in try verticalSamples(includeGenerated: false) {
                guard let across = sample.across else { continue }
                let right = crossings(routedLines(across)), down = crossings(routedLines(sample.level, .down))
                rows.append("\(sample.name) \(right)→\(down)")
                check(down <= right, "\(sample.name): \(down) crossings top to bottom, \(right) left to right")
                check(throughCards(routedLines(sample.level, .down), sample.level) == 0, "\(sample.name): an edge runs through a card")
            }
            print("Layout crossings, right→down: " + rows.joined(separator: ", "))
        },
        CheckCase(name: "vertical layout draws chains, trees and fans top to bottom without crossings") {
            for (name, text) in [("chain", chainManifest(8)), ("tree", treeManifest(depth: 4)), ("fan", fanManifest(6)),
                                 ("grouped tree", treeManifest(depth: 3, grouped: true))] {
                guard let manifest = parsed(text + "\ndirection: down") else { check(false, "\(name) did not parse"); continue }
                let level = manifest.root
                check(level.direction == .down, "\(name): direction")
                check(crossings(routedLines(level, .down)) == 0, "\(name): \(crossings(routedLines(level, .down))) crossings")
                for edge in level.edges {
                    let from = level.node(edge.from)?.at?.y ?? 0, to = level.node(edge.to)?.at?.y ?? 0
                    check(from < to, "\(name): \(edge.id) does not run top to bottom")
                }
            }
            // A chain is one straight line down.
            if let chain = parsed(chainManifest(8) + "\ndirection: down") {
                check(Set(chain.root.nodes.compactMap { $0.at?.x }).count == 1, "chain is not straight")
            }
        },
        CheckCase(name: "vertical layout puts a store beside its only caller and shared stores at the bottom") {
            guard let manifest = parsed("""
                direction: down
                nodes:
                  - { id: web, kind: client }
                  - { id: api, kind: service }
                  - { id: cache, kind: cache }
                  - { id: jobs, kind: queue }
                  - { id: worker, kind: worker }
                  - { id: mail, kind: external }
                  - { id: db, kind: database }
                edges:
                  - { from: web, to: api, protocol: https }
                  - { from: api, to: cache, protocol: redis }
                  - { from: api, to: jobs, protocol: amqp }
                  - { from: jobs, to: worker }
                  - { from: worker, to: mail, protocol: smtp }
                  - { from: api, to: db, protocol: sql }
                  - { from: worker, to: db, protocol: sql }
                """) else { check(false, "side fixture"); return }
            let level = manifest.root
            func at(_ id: String) -> GridPoint { level.node(id)?.at ?? GridPoint(-9, -9) }
            let rows = Set(level.nodes.compactMap { $0.at?.y })
            check(at("cache").y == at("api").y, "the cache is not beside api: \(at("cache")) vs \(at("api"))")
            check(at("mail").y == at("worker").y, "mail is not beside the worker")
            check(at("db").y == rows.max() && at("db").y > at("worker").y, "the shared database is not in the bottom row")
            check(at("web").y == rows.min(), "the client is not on top")
            let gap = abs(at("cache").x - at("api").x) * LayoutMetrics.column - LayoutMetrics.cardWidth
            check(gap < 120, "the cache sits \(Int(gap)) pt from api")
            let side = routes(level, .down).first { $0.edge == "api->cache" }!
            check(abs(side.start.y - side.tip.y) < 0.5, "api → cache is not level")
        },
        CheckCase(name: "vertical layout is deterministic and the switch round-trips to the parsed layout") {
            let first = try verticalSamples(), second = try verticalSamples()
            check(first.count == second.count, "sample count changed")
            for (a, b) in zip(first, second) {
                check(a.level.nodes.map(\.at) == b.level.nodes.map(\.at), "\(a.name): positions changed on a second run")
                check(a.level.edges.map(\.via) == b.level.edges.map(\.via), "\(a.name): edge tracks changed on a second run")
                check(routes(a.level, .down).map(\.label) == routes(b.level, .down).map(\.label), "\(a.name): labels moved on a second run")
            }
            for sample in try layoutSamples() {
                let back = DiagramLayout.arranged(sample.level, direction: sample.level.direction ?? .right)
                check(back.nodes.map(\.at) == sample.level.nodes.map(\.at), "\(sample.name): switching back moves cards")
                check(back.edges.map(\.via) == sample.level.edges.map(\.via), "\(sample.name): switching back moves tracks")
            }
        },
        CheckCase(name: "vertical layout places 60 nodes in about the time horizontal takes") {
            guard let manifest = parsed(generatedManifest(nodes: 60, seed: 7)) else { check(false, "60-node fixture"); return }
            var level = manifest.root
            for index in level.nodes.indices { level.nodes[index].at = nil; level.nodes[index].hint = nil }
            var times: [FlowDirection: (layout: [Double], routing: [Double])] = [:]
            for _ in 0..<7 {
                for direction in FlowDirection.allCases {
                    var start = Date()
                    let placed = DiagramLayout.arranged(level, direction: direction)
                    let layout = Date().timeIntervalSince(start) * 1000
                    start = Date()
                    _ = routes(placed, direction)
                    let routing = Date().timeIntervalSince(start) * 1000
                    times[direction, default: ([], [])].layout.append(layout)
                    times[direction, default: ([], [])].routing.append(routing)
                }
            }
            func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
            let right = median(times[.right]!.layout), down = median(times[.down]!.layout)
            let routeRight = median(times[.right]!.routing), routeDown = median(times[.down]!.routing)
            print(String(format: "Layout of 60 nodes, right %.2f ms, down %.2f ms; routing right %.2f ms, down %.2f ms",
                         right, down, routeRight, routeDown))
            check(down < max(right * 2.5, limit(4)), String(format: "vertical layout took %.2f ms, horizontal %.2f ms", down, right))
            check(routeDown < max(routeRight * 2, limit(4)), String(format: "vertical routing took %.2f ms", routeDown))
        },
        CheckCase(name: "direction parses, carries into deep dives and suggests a value") {
            let header = layoutHeader
            let (manifest, diagnostics) = ManifestParser.parse(header + """
                direction: down
                nodes:
                  - id: a
                    kind: service
                    inside:
                      nodes: [{id: x, kind: service, inside: {nodes: [{id: deep, kind: service}]}}, {id: y, kind: database}]
                      edges: [{from: x, to: y}]
                  - id: b
                    kind: service
                    inside:
                      direction: right
                      nodes: [{id: x, kind: service, inside: {nodes: [{id: deep, kind: service}]}}]
                edges: [{from: a, to: b}]
                """, source: .file(URL(fileURLWithPath: "/tmp/direction.yaml")))
            check(diagnostics.isEmpty, "unexpected diagnostics: \(diagnostics)")
            check(manifest?.root.direction == .down, "root direction")
            check(manifest?.level(at: ["a"])?.direction == .down, "a deep dive inherits down")
            check(manifest?.level(at: ["a", "x"])?.direction == .down, "a deeper dive inherits down")
            check(manifest?.level(at: ["b"])?.direction == .right, "a deep dive overrides")
            check(manifest?.level(at: ["b", "x"])?.direction == .right, "an override carries into its own deep dives")
            if let a = manifest?.root.node("a")?.at, let b = manifest?.root.node("b")?.at {
                check(a.y < b.y && a.x == b.x, "the root runs top to bottom: \(a) \(b)")
            }
            let plain = parsed(chainManifest(3))
            check(plain?.root.direction == .right, "the default direction is right")
            for (word, suggestion) in [("vertical", "down"), ("horizontal", "right"), ("top-down", "down"), ("rigth", "right")] {
                let bad = ManifestParser.parse(header + "direction: \(word)\nnodes: [{id: a, kind: service}]",
                                               source: .file(URL(fileURLWithPath: "/tmp/direction.yaml"))).1
                check(bad.contains { $0.severity == .error && $0.message.contains("did you mean '\(suggestion)'") },
                      "direction: \(word) should suggest \(suggestion): \(bad)")
            }
            let sideways = ManifestParser.parse(header + "direction: sideways\nnodes: [{id: a, kind: service}]",
                                                source: .file(URL(fileURLWithPath: "/tmp/direction.yaml"))).1
            check(sideways.contains { $0.severity == .error && $0.message.contains("expected right") }, "unknown direction: \(sideways)")
            let hinted = ManifestParser.parse(header + """
                direction: down
                nodes: [{id: a, kind: client, at: [0, 2]}, {id: b, kind: service, at: [0, 0]}]
                edges: [{from: a, to: b}]
                """, source: .file(URL(fileURLWithPath: "/tmp/hints.yaml"))).1
            check(hinted.contains { $0.severity == .warning && $0.message.contains("above 'a'") }, "missing hint warning: \(hinted)")
        },
    ]
}

/// Every level of `layoutSamples` laid out top to bottom from its hints, as the stage's switch does, with
/// the left-to-right layout kept for comparison.
private struct VerticalSample {
    let name: String
    let level: Level
    let across: Level?
}

private func verticalSamples(includeGenerated: Bool = true) throws -> [VerticalSample] {
    try layoutSamples(includeGenerated: includeGenerated).map { sample in
        VerticalSample(name: sample.name, level: DiagramLayout.arranged(sample.level, direction: .down), across: sample.level)
    }
}

/// Whether `from` reaches `to` along the level's edges.
private func reaches(_ from: String, _ to: String, in level: Level) -> Bool {
    var seen: Set<String> = [from], stack = [from]
    while let node = stack.popLast() {
        if node == to { return true }
        for edge in level.edges where edge.from == node && seen.insert(edge.to).inserted { stack.append(edge.to) }
    }
    return false
}
