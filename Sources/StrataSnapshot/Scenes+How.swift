import AppKit
import SwiftUI
import StrataCore
@_spi(Snapshots) import StrataUI

// How it works and Formulas: the inspector card, the mechanism player at key moments, the state
// panel, the formula hover card and section, and the roster lesson's stage, on the bundled examples.

@MainActor func howScenes() -> [Scene] {
    let size = CGSize(width: 1400, height: 880)
    return [
        howScene("how-inspector-card", size: CGSize(width: 1400, height: 1040), selected: "scheduler"),
        howScene("how-player-step1", size: size, selected: "scheduler") { sim in
            SimHowSnapshot.open(sim, node: "scheduler", mechanism: "roster", step: 1)
        },
        howScene("how-player-heartbeat2", size: size, selected: "scheduler") { sim in
            SimHowSnapshot.open(sim, node: "scheduler", mechanism: "roster", step: 7)
        },
        howScene("how-player-flight", size: size, selected: "scheduler") { sim in
            SimHowSnapshot.open(sim, node: "scheduler", mechanism: "roster", step: 5, progress: 0.86)
        },
        howScene("how-player-crash-expired", size: size, selected: "scheduler") { sim in
            SimHowSnapshot.open(sim, node: "scheduler", mechanism: "roster", branch: "crash", step: 9)
        },
        howScene("how-player-partition-fenced", size: size, selected: "scheduler") { sim in
            SimHowSnapshot.open(sim, node: "scheduler", mechanism: "roster", branch: "partition", step: 13)
        },
        howScene("how-player-leave", size: size, selected: "scheduler") { sim in
            SimHowSnapshot.open(sim, node: "scheduler", mechanism: "roster", branch: "leave", step: 9)
        },
        howStateScene(),
        howKeysScene(size: size),
        howHoverScene(size: size),
        howScene("how-formula-section", size: CGSize(width: 1400, height: 1500), selected: "scheduler"),
        howScene("how-overview", size: size, manifest: "checkout", path: ["orders"], selected: nil),
        howScene("how-formula-op", size: size, selected: "scheduler") { sim in
            SimOpsSnapshot.open(sim, node: "scheduler", op: "heartbeat", from: "scheduler")
        },
        Scene(name: "how-formula-typeset", size: CGSize(width: 320, height: 1000)) {
            AnyView(SimHowSnapshot.formulas(formulaSamples()))
        },
        howScene("how-roster-stage", size: size, selected: nil, seconds: 6),
        howScene("how-op-mechanism", size: size, selected: "scheduler") { sim in
            SimOpsSnapshot.open(sim, node: "scheduler", op: "fenced-write", from: "scheduler")
        },
        howScene("how-player-untimed", size: size, selected: "scheduler") { sim in
            SimHowSnapshot.open(sim, node: "scheduler", op: "fenced-write", mechanism: "fence", branch: "stale", step: 4)
        },
        howScene("how-checkout-relay", size: size, manifest: "checkout", path: ["orders"], selected: "relay") { sim in
            SimHowSnapshot.open(sim, node: "relay", mechanism: "relay-cycle", branch: "crash", step: 5, progress: 0.8)
        },
    ]
}

@MainActor private func howScene(_ name: String, size: CGSize, manifest id: String = "valkey-roster", path: [String] = [],
                                 selected: String?, seconds: Double = 4, prepare: @escaping (Simulation) -> Void = { _ in }) -> Scene {
    Scene(name: name, size: size) {
        let manifest = howManifest(id)
        let model = howModel(manifest)
        let sim = Simulation(manifest: manifest, path: path)
        if !path.isEmpty { model.open(.sim(manifest.id, path: path)) }
        sim.playing = true
        var t = 0.0
        while t < seconds { sim.tick(1.0 / 60); t += 1.0 / 60 }
        sim.playing = false
        model.sessions[AppModel.sessionKey(manifest.id, path)] = sim
        prepare(sim)
        return AnyView(SimScreen(model: model, id: manifest.id, path: path, snapshot: SimSnapshotOptions(selectedNode: selected)))
    }
}

/// The state panel alone, in the crash branch while A's key drains toward its deadline.
@MainActor private func howStateScene() -> Scene {
    Scene(name: "how-state-ttl", size: CGSize(width: 330, height: 420)) {
        let manifest = howManifest("valkey-roster")
        let sim = Simulation(manifest: manifest)
        SimHowSnapshot.open(sim, node: "scheduler", mechanism: "roster", branch: "crash", step: 8, progress: 0.7)
        return SimHowSnapshot.statePanel(sim)
    }
}

/// The real window: the player opened from the start, then → three times through the stage's key
/// handling, which lands on step 3 (the shard ranking).
@MainActor private func howKeysScene(size: CGSize) -> Scene {
    Scene(name: "how-player-keys", size: size, hosted: true) {
        let manifest = howManifest("valkey-roster")
        let model = howModel(manifest)
        model.open(.sim(manifest.id, path: []))
        model.sidebarVisible = false
        let sim = Simulation(manifest: manifest)
        sim.playing = false
        model.sessions[AppModel.sessionKey(manifest.id, [])] = sim
        SimHowSnapshot.open(sim, node: "scheduler", mechanism: "roster", step: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { howPress([124, 124, 124]) }
        return AnyView(RootView(model: model, fixtureEntries: model.library.entries, fixtureNotes: [:]))
    }
}

@MainActor private func howPress(_ keys: [UInt16]) {
    guard let window = NSApp.windows.last else { return }
    for key in keys {
        let arrow = String(UnicodeScalar(key == 124 ? NSRightArrowFunctionKey : NSLeftArrowFunctionKey)!)
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, characters: arrow, charactersIgnoringModifiers: arrow,
                                           isARepeat: false, keyCode: key) else { continue }
        NSApp.sendEvent(event)
    }
}

/// Hovering the ƒ badge on scheduler shows the compact formula card, drawn by the real overlay host.
@MainActor private func howHoverScene(size: CGSize) -> Scene {
    Scene(name: "how-formula-hover", size: size, hosted: true) {
        let manifest = howManifest("valkey-roster")
        let model = howModel(manifest)
        model.open(.sim(manifest.id, path: []))
        model.sidebarVisible = false
        let sim = Simulation(manifest: manifest)
        sim.playing = true
        for _ in 0..<240 { sim.tick(1.0 / 60) }
        sim.playing = false
        model.sessions[AppModel.sessionKey(manifest.id, [])] = sim
        SimHowSnapshot.hoverFormula(sim, node: "scheduler")
        return AnyView(RootView(model: model, fixtureEntries: model.library.entries, fixtureNotes: [:]))
    }
}

private func formulaSamples() -> [(title: String, formula: Formula)] {
    func formula(_ expr: String, _ vars: [(String, String)] = [], example: String? = nil) -> Formula {
        var formula = Formula(expr: expr)
        formula.vars = vars.map { (name: $0.0, meaning: $0.1) }
        formula.example = example
        return formula
    }
    return [
        ("Spec example: ranker", formula("score = w_r · e^(−age / τ) + w_c · ctr − p · spam",
                                         [("w_r", "weight of recency (0.6)"), ("τ", "half-life of a post in hours (6)"), ("ctr", "click-through rate"), ("p", "spam penalty (0.9)")],
                                         example: "age 3 h, ctr 0.04, not spam → 0.6 · e^(−0.5) + 0.4 · 0.04 = 0.38")),
        ("Rendezvous hashing", formula("owner(s) = argmax_(m ∈ M) h(m, s)")),
        ("Stacked fraction", formula("interval = (ttl / (k + 1))", [("ttl", "key TTL"), ("k", "heartbeats per TTL")])),
        ("Sum with subscripts", formula("total = Σ_i qty_i · price_i · (1 − d) + ship")),
        ("ASCII spellings", formula("p99 <= 2 * p50 and lambda >= mu_max / (1 + rho^2)")),
        ("Unknown syntax falls back to mono", formula("x = (a + b")),
    ]
}

private func howManifest(_ id: String) -> Manifest {
    guard let url = StrataResources.url("Examples/\(id).yaml"), let text = try? String(contentsOf: url, encoding: .utf8),
          let manifest = ManifestParser.parse(text, source: .bundled(url)).0 else { fatalError("missing example \(id)") }
    return manifest
}

@MainActor private func howModel(_ manifest: Manifest) -> AppModel {
    AppModel(library: Library(manifests: [manifest]),
             vault: Vault(root: FileManager.default.temporaryDirectory.appendingPathComponent("strata-snap-vault")))
}
