import AppKit
import SwiftUI
import StrataCore
@_spi(Snapshots) import StrataUI

// Pressure: the dock tab in each section, heat mode and a blast radius on the stage, the node menu
// and ⌘K, on the checkout fixture sized so the database saturates first, with the real analysis
// (`Simulation.capacityReport()`, `culprits()`, `blastRadius(_:)`).

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
        // Heat on, then an op row hovered: the op's path is the later request, so it wins.
        pressureScene("pressure-ops-wins", size: size, rate: 55, section: .capacity, selected: "orders") { sim in
            SimPressureSnapshot.heat(sim)
            SimOpsSnapshot.hover(sim, node: "orders", op: "insert-order")
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
