import Foundation
import StrataCore

// Shared links drawn as one (EdgeBundling, EdgeRouter.BundleRoute): which edges collapse, how they come back
// out, and what the stage then draws, on two synthetic maps and every bundled example, both directions.

@MainActor func bundleChecks() -> [CheckCase] {
    [
        CheckCase(name: "bundles collapse edges into one store over one protocol, from the callers' group") {
            guard let level = parsed(dispatchManifest)?.root else { check(false, "the dispatch fixture did not parse"); return }
            let bundles = EdgeBundling.bundles(in: level)
            check(bundles.map(\.id) == ["bundle:orders-db:sql:fleet", "bundle:kv:redis:fleet", "bundle:label-store:grpc:fleet"],
                  "bundles: \(bundles.map(\.id))")
            guard bundles.count == 3 else { return }
            let (db, kv, labels) = (bundles[0], bundles[1], bundles[2])
            // postgres joins sql, valkey joins redis; the ERP outside the fleet and the scans without a protocol stay apart.
            check(db.sources == ["planner", "allocator", "packer", "courier", "returns", "rules", "ledger", "console"], "db: \(db.sources)")
            check(db.label() == "sql · 8" && kv.label() == "redis · 6" && labels.label() == "grpc · 3",
                  "labels: \(db.label()), \(kv.label()), \(labels.label())")
            check(kv.sources.contains("returns") && !db.edges.contains("erp->orders-db") && !labels.edges.contains("drivers->label-store"),
                  "members: \(kv.sources) \(db.edges) \(labels.edges)")
            check(db.group == "fleet", "the courier pods share the fleet's box: \(db.group ?? "trunk")")
            check(EdgeBundling.family("PostgreSQL") == "sql" && EdgeBundling.family("valkey") == "redis" && EdgeBundling.family(nil) == nil,
                  "families")
            // Fewer than three callers, or a target on the request path, keeps every line.
            let few = parsed("""
                strata: 1
                id: few
                title: Few
                nodes: [{id: a, kind: service}, {id: b, kind: service}, {id: q, kind: queue}, {id: c, kind: service}, {id: db, kind: database}]
                edges:
                  - { from: a, to: db, protocol: sql }
                  - { from: b, to: db, protocol: sql }
                  - { from: a, to: q, protocol: amqp }
                  - { from: b, to: q, protocol: amqp }
                  - { from: c, to: q, protocol: amqp }
                """)
            check(few.map { EdgeBundling.bundles(in: $0.root).isEmpty } == true, "nothing to bundle in the small map")
        },
        CheckCase(name: "bundled edges come back out for focus and lit paths") {
            guard let level = parsed(dispatchManifest)?.root else { return }
            let bundles = EdgeBundling.bundles(in: level)
            let edges = Set(level.edges.map(\.id)).count
            check(edges == 41, "the fixture has \(edges) edges")
            check(EdgeBundling.drawnLinks(level, bundles: bundles) == 27, "drawn: \(EdgeBundling.drawnLinks(level, bundles: bundles))")
            // The store in focus: every member on its own line.
            let store = EdgeBundling.drawn(bundles, focus: ["orders-db"], lit: [])
            check(store.bundles["bundle:orders-db:sql:fleet"] == nil && store.loose.count == 8, "store focus: \(store)")
            check(EdgeBundling.drawnLinks(level, bundles: bundles, focus: ["orders-db"]) == 34, "store focus count")
            // A member in focus leaves its bundles; the rest keep theirs, one shorter.
            let courier = EdgeBundling.drawn(bundles, focus: ["courier"], lit: [])
            check(courier.loose == ["courier->orders-db", "courier->kv", "courier->label-store"], "member focus: \(courier.loose)")
            check(courier.bundles["bundle:orders-db:sql:fleet"]?.count == 7 && courier.bundles["bundle:kv:redis:fleet"]?.count == 5
                  && courier.bundles["bundle:label-store:grpc:fleet"]?.count == 2, "kept: \(courier.bundles)")
            // A bundle left with one member draws it on its own.
            let two = EdgeBundling.drawn(bundles, focus: ["courier", "returns"], lit: [])
            check(two.bundles["bundle:label-store:grpc:fleet"] == nil && two.loose.contains("ledger->label-store"), "one left: \(two)")
            // A lit path (an op, a flow) pulls its edges out too.
            let lit = EdgeBundling.drawn(bundles, focus: [], lit: ["planner->orders-db"])
            check(lit.loose == ["planner->orders-db"] && lit.bundles["bundle:orders-db:sql:fleet"]?.count == 7, "lit: \(lit)")
            if let flow = level.flow("plan") {
                check(level.edgeIDs(of: flow).isSuperset(of: ["tick->planner", "planner->orders-db", "allocator->pack-jobs"]),
                      "flow edges: \(level.edgeIDs(of: flow))")
            }
        },
        CheckCase(name: "callers outside a group join one trunk near them") {
            guard let level = parsed(trunkManifest)?.root else { check(false, "the trunk fixture did not parse"); return }
            let bundles = EdgeBundling.bundles(in: level)
            check(bundles.map(\.id) == ["bundle:db:sql:*"] && bundles.first?.edges.count == 3, "trunk: \(bundles.map(\.id))")
            for direction in FlowDirection.allCases {
                let laid = DiagramLayout.arranged(level, direction: direction, bundled: true)
                let drawn = drawnLinks(laid, direction)
                check(drawn.bundles.count == 1 && drawn.bundles.first?.stubs.count == 3, "\(direction): the trunk was not routed")
                // The stubs meet where the trunk starts, past the last caller.
                if let route = drawn.bundles.first {
                    for stub in route.stubs.values { check(distance(stub.tip, route.origin) < 4, "\(direction): a stub misses the junction") }
                }
            }
        },
        CheckCase(name: "bundled maps draw fewer links, clear of cards, with pills apart, the same every time") {
            var rows: [String] = []
            for (name, level) in try bundleSamples() {
                let edges = Set(level.edges.map(\.id)).count
                for direction in FlowDirection.allCases {
                    let laid = DiagramLayout.arranged(level, direction: direction, bundled: true)
                    let drawn = drawnLinks(laid, direction)
                    let count = drawn.links
                    rows.append("\(name) \(direction.rawValue) \(edges)→\(count)")
                    check(count <= edges, "\(name) \(direction): \(count) drawn links for \(edges) edges")
                    let again = drawnLinks(DiagramLayout.arranged(level, direction: direction, bundled: true), direction)
                    check(again.lines.map(\.points) == drawn.lines.map(\.points) && again.pills == drawn.pills,
                          "\(name) \(direction): not deterministic")
                    let focuses: [Set<String>] = [[]] + drawn.targets.map { [$0] } + drawn.sources.prefix(2).map { [$0] }
                    for focus in focuses {
                        let state = drawnLinks(laid, direction, focus: focus)
                        clear(state, laid, "\(name) \(direction) focus \(focus.sorted())")
                    }
                }
            }
            print("Drawn links, edges→drawn: " + rows.joined(separator: ", "))
        },
        CheckCase(name: "bundled layout keeps the spine straight and draws fewer crossings") {
            var rows: [String] = []
            for (name, level) in try bundleSamples() where !EdgeBundling.bundles(in: level).isEmpty {
                for direction in FlowDirection.allCases {
                    let classic = DiagramLayout.arranged(level, direction: direction)
                    let bundled = DiagramLayout.arranged(level, direction: direction, bundled: true)
                    let before = crossings(drawnLinks(classic, direction, bundling: false).lines)
                    let routed = crossings(drawnLinks(classic, direction).lines)
                    let after = crossings(drawnLinks(bundled, direction).lines)
                    rows.append("\(name) \(direction.rawValue) \(before)→\(routed)→\(after)")
                    check(after <= before, "\(name) \(direction): \(after) crossings bundled, \(before) without")
                    let rects = cardRects(bundled)
                    for (i, a) in rects.enumerated() {
                        for b in rects[(i + 1)...] where a.rect.insetBy(dx: 1, dy: 1).intersects(b.rect) {
                            check(false, "\(name) \(direction): \(a.id) overlaps \(b.id)")
                        }
                    }
                    guard direction == .down else { continue }
                    let spine = DiagramLayout.spine(of: bundled, direction: .down)
                    let centres = spine.nodes.compactMap { id in rects.first { $0.id == id }?.rect.midX }
                    check(centres.allSatisfy { abs($0 - (centres.first ?? 0)) < 0.5 }, "\(name): the spine is not straight: \(centres)")
                }
            }
            print("Drawn crossings, every edge→bundles routed→bundled layout: " + rows.joined(separator: ", "))
        },
    ]
}

// MARK: - What the stage draws

struct DrawnLinks {
    var lines: [(from: String, to: String, points: [CGPoint])] = []
    var pills: [CGRect] = []
    var pillNames: [String] = []
    /// Links drawn: edges on their own line and kept bundles, a trunk's stubs counting with it.
    var links = 0
    var bundles: [EdgeRouter.BundleRoute] = []
    var targets: [String] = []
    var sources: [String] = []
}

/// The lines and pills the stage draws for a laid-out level with `focus` nodes hovered or selected: every edge
/// not folded into a bundle, each kept bundle's line (and a trunk's kept stubs), and the pills that show
/// (no quiet data-link pill out of focus).
func drawnLinks(_ level: Level, _ direction: FlowDirection, focus: Set<String> = [], bundling: Bool = true) -> DrawnLinks {
    let cards = cardRects(level).map { EdgeRouter.Card(id: $0.id, rect: $0.rect) }
    let regions = groupRegions(level)
    let labels = level.groups.compactMap { group in regions[group.id].map { EdgeRouter.Region(rect: $0, label: group.label) } }
    let requests = level.edges.map { edge in
        EdgeRouter.Request(id: edge.id, from: edge.from, to: edge.to, label: edge.label ?? edge.protocol,
                           via: edge.via.map { direction == .down ? $0.x * LayoutMetrics.column + LayoutMetrics.origin
                                                                  : $0.y * LayoutMetrics.row + LayoutMetrics.origin })
    }
    let bundles = bundling ? EdgeBundling.bundles(in: level) : []
    let routing = EdgeRouter.routing(cards: cards, regions: labels, groups: regions, edges: requests, bundles: bundles, direction: direction)
    let routed = Set(routing.bundles.map(\.bundle))
    let placed = bundles.filter { routed.contains($0.id) }
    let state = EdgeBundling.drawn(placed, focus: focus, lit: [])
    let folded = Set(state.bundles.values.joined())
    var result = DrawnLinks(bundles: routing.bundles, targets: placed.map(\.target), sources: placed.flatMap(\.sources))
    let byID = Dictionary(level.edges.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    for route in routing.routing.routes where !folded.contains(route.edge) {
        guard let edge = byID[route.edge] else { continue }
        result.lines.append((edge.from, edge.to, route.polyline(curveSteps: 16)))
        result.links += 1
        let quiet = EdgeBundling.isDataLink(edge, in: level) && !focus.contains(edge.from) && !focus.contains(edge.to)
        if let label = route.label, (edge.label ?? edge.protocol) != nil, !quiet {
            result.pills.append(CGRect(x: label.x - route.labelWidth / 2, y: label.y - 8, width: route.labelWidth, height: 16))
            result.pillNames.append(edge.id)
        }
    }
    for route in routing.bundles {
        guard let kept = state.bundles[route.bundle], let bundle = placed.first(where: { $0.id == route.bundle }) else { continue }
        result.lines.append((route.bundle, bundle.target, route.trunk.polyline(curveSteps: 16)))
        result.links += 1
        // A trunk's stubs show; a group's box hides them.
        for edge in kept where bundle.group == nil {
            if let stub = route.stubs[edge] { result.lines.append((byID[edge]?.from ?? edge, route.bundle, stub.polyline(curveSteps: 16))) }
        }
        if let label = route.trunk.label {
            result.pills.append(CGRect(x: label.x - route.trunk.labelWidth / 2, y: label.y - 8, width: route.trunk.labelWidth, height: 16))
            result.pillNames.append(route.bundle)
        }
    }
    return result
}

/// No drawn line runs through a card it doesn't end on, and no two pills, or a pill and a card, overlap.
private func clear(_ drawn: DrawnLinks, _ level: Level, _ name: String) {
    let cards = cardRects(level)
    for line in drawn.lines {
        for card in cards where card.id != line.from && card.id != line.to {
            check(!LayoutQuality.polyline(line.points, crosses: card.rect.insetBy(dx: 1, dy: 1)), "\(name): \(line.from)→\(line.to) runs through \(card.id)")
        }
    }
    for (i, pill) in drawn.pills.enumerated() {
        check(!cards.contains { $0.rect.insetBy(dx: 1, dy: 1).intersects(pill) }, "\(name): a pill covers a card at \(Int(pill.midX)),\(Int(pill.midY))")
        for (j, other) in drawn.pills.enumerated() where j > i && other.insetBy(dx: 2, dy: 2).intersects(pill) {
            check(false, "\(name): the pills of \(drawn.pillNames[i]) and \(drawn.pillNames[j]) overlap at \(Int(pill.midX)),\(Int(pill.midY))")
        }
    }
}

private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

/// The two fixtures and every level of every bundled example.
func bundleSamples() throws -> [(String, Level)] {
    var samples: [(String, Level)] = []
    for (name, text) in [("dispatch", dispatchManifest), ("trunk", trunkManifest), ("messy-shop", messyManifest(manual: false))] {
        guard let manifest = parsed(text) else { check(false, "\(name) did not parse"); continue }
        samples.append((name, manifest.root))
    }
    let directory = try requiredResource("Examples")
    for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter({ $0.pathExtension == "yaml" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let name = url.deletingPathExtension().lastPathComponent
        guard let manifest = parsed(try String(contentsOf: url, encoding: .utf8)) else { check(false, "\(name) did not parse"); continue }
        samples += levels(manifest.root, path: name)
    }
    return samples
}

// MARK: - Fixtures

/// A neutral map shaped like a real one: a spine of services and queues in one cluster (two workers in a
/// nested group), side APIs, and three shared stores most of the cluster talks to.
let dispatchManifest = """
    strata: 1
    id: parcel-dispatch
    title: Parcel dispatch
    kind: architecture
    direction: down
    groups:
      - { id: fleet, label: Dispatch fleet, kind: cluster }
      - { id: courier-pods, label: courier pods, parent: fleet }
    nodes:
      - { id: tick, kind: cron, label: plan tick }
      - { id: erp, kind: client, label: legacy ERP }
      - { id: retry-timer, kind: cron, label: retry timer }
      - { id: sweeper, kind: cron, label: sweeper }
      - { id: clerk, kind: user, label: clerk }
      - { id: drivers, kind: user, label: drivers }
      - { id: planner, kind: service, group: fleet }
      - { id: allocator, kind: service, group: fleet }
      - { id: packer, kind: worker, group: fleet }
      - { id: courier, kind: worker, group: courier-pods }
      - { id: returns, kind: worker, group: courier-pods }
      - { id: rules, kind: service, group: fleet }
      - { id: ledger, kind: worker, group: fleet }
      - { id: console, kind: service, group: fleet }
      - { id: pack-jobs, kind: queue, label: pack.jobs }
      - { id: route-jobs, kind: queue, label: route.jobs }
      - { id: done-events, kind: queue, label: done.events }
      - { id: carrier-out, kind: queue, label: carrier.out }
      - { id: carrier-back, kind: queue, label: carrier.back }
      - { id: orders-db, kind: database, label: orders-db }
      - { id: kv, kind: cache, label: kv }
      - { id: label-store, kind: external, label: label-store }
      - { id: maps, kind: external, label: maps-api }
      - { id: audit, kind: external, label: audit-log }
      - { id: carrier, kind: external, label: carrier hub }
      - { id: rulebook, kind: external, label: rulebook }
      - { id: billing, kind: external, label: billing }
    edges:
      - { from: tick, to: planner, label: tick }
      - { from: planner, to: allocator, protocol: grpc, label: Reserve }
      - { from: planner, to: maps, protocol: grpc }
      - { from: planner, to: audit, protocol: http }
      - { from: allocator, to: pack-jobs, protocol: amqp }
      - { from: pack-jobs, to: packer, protocol: amqp }
      - { from: packer, to: route-jobs, protocol: amqp }
      - { from: route-jobs, to: courier, protocol: amqp }
      - { from: courier, to: rules, protocol: grpc }
      - { from: rules, to: rulebook, protocol: grpc }
      - { from: courier, to: carrier-out, protocol: amqp }
      - { from: courier, to: done-events, protocol: amqp }
      - { from: carrier-out, to: carrier, protocol: amqp }
      - { from: carrier, to: carrier-back, protocol: amqp }
      - { from: carrier-back, to: ledger, protocol: amqp }
      - { from: done-events, to: ledger, protocol: amqp }
      - { from: retry-timer, to: returns, label: poll }
      - { from: returns, to: carrier-out, protocol: amqp }
      - { from: returns, to: rules, protocol: grpc }
      - { from: returns, to: billing, protocol: http }
      - { from: sweeper, to: ledger, label: sweep }
      - { from: clerk, to: console, protocol: https }
      - { from: drivers, to: label-store, label: scans }
      - { from: ledger, to: label-store, protocol: grpc, label: Fetch }
      - { from: courier, to: label-store, protocol: grpc }
      - { from: returns, to: label-store, protocol: grpc }
      - { from: erp, to: orders-db, protocol: sql }
      - { from: planner, to: orders-db, protocol: sql }
      - { from: allocator, to: orders-db, protocol: sql }
      - { from: packer, to: orders-db, protocol: sql }
      - { from: courier, to: orders-db, protocol: sql }
      - { from: returns, to: orders-db, protocol: sql }
      - { from: rules, to: orders-db, protocol: postgres }
      - { from: ledger, to: orders-db, protocol: sql }
      - { from: console, to: orders-db, protocol: sql }
      - { from: planner, to: kv, protocol: redis }
      - { from: allocator, to: kv, protocol: redis }
      - { from: courier, to: kv, protocol: redis }
      - { from: returns, to: kv, protocol: valkey }
      - { from: ledger, to: kv, protocol: redis }
      - { from: console, to: kv, protocol: redis }
    flows:
      - id: plan
        label: Plan a round
        from: tick
        rate: 4/s
        steps:
          - call: planner
            steps:
              - { call: kv }
              - { call: orders-db }
              - call: allocator
                steps:
                  - { call: orders-db }
                  - { publish: pack-jobs }
      - id: pack
        label: Pack
        on: pack-jobs
        by: packer
        steps: [ { call: orders-db }, { publish: route-jobs } ]
      - id: deliver
        label: Deliver
        on: route-jobs
        by: courier
        steps:
          - { call: kv }
          - call: rules
            steps: [ { call: orders-db } ]
          - { call: orders-db }
          - { call: label-store }
          - { publish: done-events }
      - id: settle
        label: Settle
        on: done-events
        by: ledger
        steps: [ { call: orders-db }, { call: kv } ]
    """

/// Ungrouped services sharing a database two rows on: their lines join one trunk. A caller with one more
/// store further on takes the database there (stores called together share a row).
let trunkManifest = """
    strata: 1
    id: trunk
    title: Trunk
    nodes:
      - { id: web, kind: client }
      - { id: api, kind: gateway }
      - { id: search-svc, kind: service }
      - { id: cart-svc, kind: service }
      - { id: price-svc, kind: service }
      - { id: jobs, kind: queue }
      - { id: indexer, kind: worker }
      - { id: db, kind: database }
      - { id: files, kind: store }
    edges:
      - { from: web, to: api, protocol: https }
      - { from: api, to: search-svc, protocol: grpc }
      - { from: api, to: cart-svc, protocol: grpc }
      - { from: api, to: price-svc, protocol: grpc }
      - { from: search-svc, to: db, protocol: sql }
      - { from: cart-svc, to: db, protocol: sql }
      - { from: price-svc, to: db, protocol: sql }
      - { from: price-svc, to: jobs, protocol: amqp }
      - { from: jobs, to: indexer, protocol: amqp }
      - { from: indexer, to: files, protocol: s3 }
      - { from: price-svc, to: files, protocol: s3 }
    """
