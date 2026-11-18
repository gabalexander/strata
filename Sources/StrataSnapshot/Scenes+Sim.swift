import SwiftUI
import StrataCore
@_spi(Snapshots) import StrataUI

@MainActor func simScenes() -> [Scene] {
    let size = CGSize(width: 1400, height: 880)
    let scenes = [
        checkout("sim-checkout", size: size),
        checkout("sim-orders-inspector", size: size, selected: "orders"),
        checkout("sim-database-down", size: size, selected: "db", down: "db"),
        checkout("sim-orders-deep-dive", size: size, path: ["orders"]),
        checkout("sim-dock-controls", size: size),
        checkout("sim-dock-try-this", size: size, tab: .scenarios, scenario: "db-outage"),
        checkout("sim-dock-log", size: size, tab: .log, scenario: "db-outage"),
        checkout("sim-dock-glossary", size: size, tab: .glossary),
        checkout("sim-dock-about", size: size, tab: .about),
        checkout("sim-node-menu", size: size, selected: "orders", menu: true),
    ]
    return scenes + [Scene(name: "sim-embed-420", size: CGSize(width: 832, height: 420)) {
        let manifest = fixtureManifest()
        let model = fixtureModel(manifest)
        var embed = Embed(target: .library("checkout"))
        embed.scenario = "db-outage"
        let sim = Simulation(manifest: manifest)
        advance(sim)
        return AnyView(SimEmbedView(model: model, embed: embed, note: "Checkout.md", snapshotSession: sim))
    }]
}

@MainActor private func checkout(_ name: String, size: CGSize, path: [String] = [], selected: String? = nil,
                                 tab: SimDockTab = .controls, scenario: String? = nil, down: String? = nil,
                                 menu: Bool = false) -> Scene {
    Scene(name: name, size: size) {
        let manifest = fixtureManifest()
        let model = fixtureModel(manifest)
        let sim: Simulation
        if let parentNode = path.last {
            let parentPath = Array(path.dropLast())
            let parent = Simulation(manifest: manifest, path: parentPath)
            advance(parent)
            model.sessions[AppModel.sessionKey(manifest.id, parentPath)] = parent
            let measuredRate = parent.frame().nodes[parentNode]?.throughput
            sim = Simulation(manifest: manifest, path: path, parentRate: measuredRate)
        } else {
            sim = Simulation(manifest: manifest)
        }
        if let scenario { sim.start(scenario: scenario) }
        advance(sim)
        if let down {
            sim.perform([.kill(down)])
            sim.playing = false
        }
        model.sessions[AppModel.sessionKey(manifest.id, path)] = sim
        let options = SimSnapshotOptions(selectedNode: selected, dockTab: tab, previewMenu: menu)
        return AnyView(SimScreen(model: model, id: manifest.id, path: path, snapshot: options))
    }
}

@MainActor private func fixtureModel(_ manifest: Manifest) -> AppModel {
    AppModel(library: Library(manifests: [manifest]),
             vault: Vault(root: FileManager.default.temporaryDirectory.appendingPathComponent("strata-snap-vault")))
}

private func fixtureManifest() -> Manifest {
    var manifest = Fixtures.checkout
    func slowLinks(_ level: inout Level) {
        // At the fixture's usual one-millisecond latency, a still can land between every hop.
        for index in level.edges.indices { level.edges[index].latency = .fixed(0.12) }
        for index in level.nodes.indices {
            if var inside = level.nodes[index].inside {
                slowLinks(&inside)
                level.nodes[index].inside = inside
            }
        }
    }
    slowLinks(&manifest.root)
    return manifest
}

@MainActor private func advance(_ sim: Simulation) {
    sim.playing = true
    for _ in 0..<180 { sim.tick(1.0 / 60) }
}
