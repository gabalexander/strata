import AppKit
import SwiftUI
import StrataCore
@_spi(Snapshots) import StrataUI

// Pressure: the dock tab in each section, heat mode and a blast radius on the stage, the node menu
// and ⌘K. The numbers come from `PressurePreview`, a small hand-built capacity model of the checkout
// fixture that follows the sim's own rates and replicas, so "Try it" and the live leaves agree.

@MainActor func pressureScenes() -> [Scene] {
    let size = CGSize(width: 1400, height: 880)
    return [
        pressureScene("pressure-now-culprits", size: size, rate: 55, section: .now),
        pressureScene("pressure-now-calm", size: size, rate: 10, section: .now),
        pressureScene("pressure-bottlenecks", size: size, rate: 55, section: .bottlenecks),
        pressureScene("pressure-scale-plan", size: size, rate: 55, section: .scale),
        pressureScene("pressure-scale-tried", size: size, rate: 55, section: .scale) { sim in
            SimPressureSnapshot.tryFirstStep(sim)
        },
        pressureScene("pressure-stores", size: size, rate: 55, section: .stores),
        pressureScene("pressure-volumes", size: size, rate: 55, section: .volumes),
        pressureScene("pressure-capacity", size: size, rate: 55, section: .capacity),
        pressureScene("pressure-heat", size: size, rate: 55, section: .capacity) { sim in
            SimPressureSnapshot.heat(sim)
        },
        pressureScene("pressure-blast", size: size, rate: 55, section: .now, selected: "db"),
        pressureScene("pressure-blast-pinned", size: size, rate: 55, tab: .controls, selected: "smtp") { sim in
            SimPressureSnapshot.blast(sim, node: "smtp")
        },
        pressureScene("pressure-node-menu", size: size, rate: 55, tab: .controls, selected: "db", menu: true),
        pressurePaletteScene(size: size),
    ] + [SimPressureSection.bottlenecks, .scale, .stores, .volumes, .capacity].map { section in
        // Each section whole, at the dock's width but taller than the dock, so nothing hides past the fold.
        Scene(name: "pressure-full-\(section.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))",
              size: CGSize(width: 1080, height: 470)) {
            let manifest = pressureManifest(rate: 55)
            let model = pressureModel(manifest)
            let sim = Simulation(manifest: manifest)
            SimPressureSnapshot.preview(sim, source: PressurePreview())
            SimPressureSnapshot.section(sim, section)
            sim.playing = true
            for _ in 0..<480 { sim.tick(1.0 / 60) }
            sim.playing = false
            return SimPressureSnapshot.tab(sim, model: model)
        }
    }
}

@MainActor private func pressureScene(_ name: String, size: CGSize, rate: Double, tab: SimDockTab = .pressure,
                                      section: SimPressureSection = .now, selected: String? = nil, menu: Bool = false,
                                      prepare: @escaping (Simulation) -> Void = { _ in }) -> Scene {
    Scene(name: name, size: size) {
        let manifest = pressureManifest(rate: rate)
        let model = pressureModel(manifest)
        let sim = Simulation(manifest: manifest)
        SimPressureSnapshot.preview(sim, source: PressurePreview())
        SimPressureSnapshot.section(sim, section)
        sim.playing = true
        for _ in 0..<480 { sim.tick(1.0 / 60) }
        sim.playing = false
        model.sessions[AppModel.sessionKey(manifest.id, [])] = sim
        prepare(sim)
        return AnyView(SimScreen(model: model, id: manifest.id, path: [],
                                 snapshot: SimSnapshotOptions(selectedNode: selected, dockTab: tab, previewMenu: menu)))
    }
}

/// ⌘K filtered to the Pressure commands.
@MainActor private func pressurePaletteScene(size: CGSize) -> Scene {
    Scene(name: "pressure-palette", size: size, hosted: true) {
        let manifest = pressureManifest(rate: 55)
        let model = pressureModel(manifest)
        model.open(.sim(manifest.id, path: []))
        let sim = Simulation(manifest: manifest)
        SimPressureSnapshot.preview(sim, source: PressurePreview())
        sim.playing = true
        for _ in 0..<180 { sim.tick(1.0 / 60) }
        model.sessions[AppModel.sessionKey(manifest.id, [])] = sim
        model.paletteOpen = true
        return AnyView(RootView(model: model, fixtureEntries: model.library.entries, fixtureNotes: [:],
                                fixturePaletteQuery: "pressure"))
    }
}

@MainActor private func pressureModel(_ manifest: Manifest) -> AppModel {
    AppModel(library: Library(manifests: [manifest]),
             vault: Vault(root: FileManager.default.temporaryDirectory.appendingPathComponent("strata-snap-vault")))
}

/// The checkout fixture with operations, sized so the database is the first thing to saturate:
/// an 8-connection pool at 120 ms a query, declared traffic and an SLO on checkout.
private func pressureManifest(rate: Double) -> Manifest {
    var manifest = Fixtures.checkoutWithOps
    for index in manifest.root.edges.indices { manifest.root.edges[index].latency = .fixed(0.008) }
    for index in manifest.root.nodes.indices {
        switch manifest.root.nodes[index].id {
        case "orders":
            manifest.root.nodes[index].params.concurrency = 16
            manifest.root.nodes[index].params.replicas = 2
        case "db":
            manifest.root.nodes[index].params.concurrency = 8
            manifest.root.nodes[index].params.latency = .jitter(0.12)
        case "payments":
            manifest.root.nodes[index].params.concurrency = 8
            manifest.root.nodes[index].params.latency = .jitter(0.08)
        case "mailer":
            manifest.root.nodes[index].params.concurrency = 16
        case "smtp":
            manifest.root.nodes[index].params.latency = .jitter(0.2)
        default: break
        }
    }
    var traffic = FlowTraffic()
    traffic.peak = 120
    traffic.daily = 4_200_000
    var slo = SLO()
    slo.p99 = 0.5
    slo.errors = 0.001
    manifest.root.flows[0].rate = .perSecond(rate)
    manifest.root.flows[0].traffic = traffic
    manifest.root.flows[0].slo = slo
    return manifest
}

/// A hand-built capacity model of `pressureManifest`: hold times worked out from its latencies
/// (own work plus each synchronous wait, 16 ms network round trips), demand from the sim's current
/// rates, slots from its current concurrency × replicas. Culprits read the live sim.
@MainActor
struct PressurePreview: SimPressureSource {
    private struct Load {
        let node: String
        let hold: Double
        let visits: [String: Double]
    }

    private static let loads = [
        Load(node: "db", hold: 0.12, visits: ["place-order": 1.1, "nightly": 1]),
        Load(node: "orders", hold: 0.302, visits: ["place-order": 1]),
        Load(node: "payments", hold: 0.08, visits: ["place-order": 1]),
        Load(node: "api", hold: 0.32, visits: ["place-order": 1]),
        Load(node: "cache", hold: 0.002, visits: ["place-order": 1]),
        Load(node: "mailer", hold: 0.221, visits: ["email": 1]),
        Load(node: "smtp", hold: 0.2, visits: ["email": 1]),
    ]
    private static let unlimited = ["web", "reporting", "events"]
    private static let peak = 120.0

    private func rates(_ sim: Simulation) -> [String: Double] {
        let checkout = sim.value(StrataCore.Binding(.flow("place-order"), "rate"))?.number ?? 0
        return ["place-order": checkout, "email": checkout, "nightly": 0.5]
    }

    private func slots(_ node: String, _ sim: Simulation, replicas: [String: Int] = [:]) -> Int {
        let params = sim.effective(node)
        return (params.concurrency ?? 1) * (replicas[node] ?? params.replicas ?? 1)
    }

    private func demand(_ load: Load, _ rates: [String: Double]) -> Double {
        load.visits.reduce(0) { $0 + (rates[$1.key] ?? 0) * $1.value * load.hold }
    }

    /// Where `flow` saturates with the given replicas, and on which node.
    private func maxRate(_ flow: String, _ sim: Simulation, _ rates: [String: Double],
                         replicas: [String: Int] = [:]) -> (rate: Double, node: String)? {
        Self.loads.compactMap { load -> (Double, String)? in
            guard let visits = load.visits[flow], visits > 0 else { return nil }
            let others = demand(load, rates) - (rates[flow] ?? 0) * visits * load.hold
            return ((Double(slots(load.node, sim, replicas: replicas)) - others) / (visits * load.hold), load.node)
        }.min { $0.0 < $1.0 }.map { (rate: $0.0, node: $0.1) }
    }

    func capacityReport(_ sim: Simulation) -> CapacityReport {
        let rates = rates(sim)
        var report = CapacityReport()
        report.nodes = Self.loads.map { load in
            let slots = slots(load.node, sim)
            let demand = demand(load, rates)
            return NodeCapacity(node: load.node, slots: slots, holdTime: load.hold, demand: demand,
                                utilization: demand / Double(slots), visits: load.visits)
        }.sorted { $0.utilization > $1.utilization }
            + Self.unlimited.map { NodeCapacity(node: $0, slots: nil, holdTime: 0, demand: 0, utilization: 0, visits: [:]) }
        report.flows = sim.level.flows.map { flow in
            let rate = rates[flow.id] ?? 0
            var capacity = FlowCapacity(flow: flow.id, rate: rate, daily: flow.traffic?.daily ?? rate * 86_400)
            if let limit = maxRate(flow.id, sim, rates) {
                capacity.maxRate = limit.rate
                capacity.bottleneck = limit.node
            }
            capacity.declared = flow.traffic
            capacity.slo = flow.slo
            return capacity
        }
        report.scalePlan = plan(sim, rates)
        report.pressure = [
            "db": [
                LoadSource(node: "orders", op: "insert-order", flow: "place-order", tables: ["orders", "outbox"], access: .write,
                           rate: rates["place-order"]! * 1, busyShare: 0),
                LoadSource(node: "orders", op: "select-price", flow: "place-order", tables: ["prices"], access: .read,
                           rate: rates["place-order"]! * 0.1, busyShare: 0),
                LoadSource(node: "reporting", op: "daily-totals", flow: "nightly", tables: ["orders"], access: .read,
                           rate: 0.5, busyShare: 0),
            ],
            "cache": [
                LoadSource(node: "orders", op: "price", flow: "place-order", tables: [], access: .read,
                           rate: rates["place-order"]!, busyShare: 0),
            ],
        ].mapValues { sources in
            let total = sources.reduce(0) { $0 + $1.rate }
            return sources.map { var s = $0; s.busyShare = total > 0 ? s.rate / total : 0; return s }
                .sorted { $0.busyShare > $1.busyShare }
        }
        return report
    }

    /// Scale checkout's bottleneck until it stops being one, then the next, until the declared peak fits.
    private func plan(_ sim: Simulation, _ rates: [String: Double]) -> [ScaleStep] {
        var replicas = Dictionary(uniqueKeysWithValues: Self.loads.map { ($0.node, sim.effective($0.node).replicas ?? 1) })
        var steps: [ScaleStep] = []
        while steps.count < 4, let limit = maxRate("place-order", sim, rates, replicas: replicas), limit.rate < Self.peak {
            let node = limit.node
            guard let load = Self.loads.first(where: { $0.node == node }) else { break }
            var others = replicas
            others[node] = 1_000
            let target = min(Self.peak, maxRate("place-order", sim, rates, replicas: others)?.rate ?? Self.peak)
            var next = replicas[node, default: 1]
            while next < 64, maxRate("place-order", sim, rates, replicas: replicas.merging([node: next]) { $1 })
                .map({ $0.node == node && $0.rate < target }) ?? false { next += 1 }
            replicas[node] = next
            var step = ScaleStep(node: node, replicas: next,
                                 reason: "First to fill: \(slots(node, sim)) \(node == "db" ? "connections" : "slots") held \(Int(load.hold * 1000)) ms per visit.")
            let after = maxRate("place-order", sim, rates, replicas: replicas)
            step.newMaxRate = after?.rate
            step.nextBottleneck = after.map(\.node) == node ? nil : after?.node
            steps.append(step)
        }
        return steps
    }

    func culprits(_ sim: Simulation) -> [Culprit] {
        let report = capacityReport(sim)
        var list: [Culprit] = []
        for capacity in report.nodes {
            guard let slots = capacity.slots, let state = sim.nodeState(capacity.node) else { continue }
            let label = sim.level.node(capacity.node)?.label ?? capacity.node
            let noun = capacity.node == "db" ? "connections" : "slots"
            if capacity.utilization >= 0.9 {
                list.append(Culprit(kind: .saturated, severity: .critical, subject: capacity.node,
                                    message: "\(label): \(state.busy)/\(slots) \(noun) busy, \(state.queued) queued"))
            } else if capacity.utilization >= 0.75 {
                list.append(Culprit(kind: .saturated, severity: .warn, subject: capacity.node,
                                    message: "\(label): \(state.busy)/\(slots) \(noun) busy, \(SimPressureFormatPreview.percent(capacity.utilization)) of capacity on average"))
            }
        }
        let checkout = sim.metrics(flow: "place-order")
        if let p99 = checkout.p99, p99 > 0.5 {
            list.append(Culprit(kind: .sloBreach, severity: .critical, subject: "place-order",
                                message: "Place order p99 is \(Int(p99 * 1000)) ms, over its 500 ms SLO"))
        }
        if let lag = sim.nodeState("events")?.groupLag["email"], lag > 20 {
            list.append(Culprit(kind: .lagging, severity: .warn, subject: "mailer",
                                message: "mailer is \(lag) messages behind on order-events"))
        }
        if checkout.retries > 0 {
            list.append(Culprit(kind: .timeouts, severity: .watch, subject: "api->orders",
                                message: "API gateway retries \(Int(checkout.retries.rounded()))/s against orders-svc"))
        }
        return list.sorted { $0.severity > $1.severity }
    }

    /// Synchronous callers, nearest first; buffers they publish to absorb it; their consumers lag.
    func blastRadius(_ node: String, in sim: Simulation) -> BlastRadius {
        let level = sim.level
        func isBuffer(_ id: String) -> Bool { level.node(id)?.kind.role == .buffer }
        var radius = BlastRadius(node: node)
        var frontier = [node]
        var seen: Set<String> = [node]
        while !frontier.isEmpty {
            var next: [String] = []
            for target in frontier where !isBuffer(target) {
                for edge in level.edges where edge.to == target && !isBuffer(edge.from) && seen.insert(edge.from).inserted {
                    radius.upstream.append(edge.from)
                    radius.edges.append(edge.id)
                    next.append(edge.from)
                }
            }
            frontier = next
        }
        let hot = Set([node] + radius.upstream)
        for edge in level.edges where hot.contains(edge.from) && isBuffer(edge.to) && !radius.absorbers.contains(edge.to) {
            radius.absorbers.append(edge.to)
            radius.edges.append(edge.id)
        }
        // A slow consumer backs up into the buffer it reads from.
        for flow in level.flows {
            guard let on = flow.on, let by = flow.by, hot.contains(by), !radius.absorbers.contains(on) else { continue }
            radius.absorbers.append(on)
        }
        for flow in level.flows {
            guard let on = flow.on, let by = flow.by, radius.absorbers.contains(on) else { continue }
            if !radius.lagging.contains(by) { radius.lagging.append(by) }
            if level.edges.contains(where: { $0.id == "\(on)->\(by)" }) { radius.edges.append("\(on)->\(by)") }
            radius.flows.append(flow.id)
        }
        if isBuffer(node) {
            radius.absorbers = [node]
            radius.lagging = level.flows.filter { $0.on == node }.compactMap(\.by)
        }
        radius.flows = Array(Set(radius.flows + level.flows.filter { flow in
            hot.contains(flow.from ?? "") || hot.contains(flow.by ?? "")
        }.map(\.id))).sorted()
        return radius
    }
}

private enum SimPressureFormatPreview {
    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }
}
