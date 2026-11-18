import SwiftUI
import StrataCore
@_spi(Snapshots) import StrataUI

/// Renders any manifest file: `STRATA_SNAP_MANIFEST=path.yaml [STRATA_SNAP_SCENARIO=id] [STRATA_SNAP_T=8]
/// [STRATA_SNAP_SELECT=node] [STRATA_SNAP_OP=node/op] swift run StrataSnapshot build/snapshots manifest-`.
/// For authors and agents checking how a manifest looks on the stage without launching the app.
/// `STRATA_SNAP_OP` opens that operation's detail in the inspector (and selects its node).
/// `STRATA_SNAP_DOCK=pressure` opens that dock tab (controls, try, pressure, log, glossary, about);
/// `STRATA_SNAP_PRESSURE=bottlenecks` picks the Pressure section (now, bottlenecks, scale, stores,
/// volumes, capacity) and `STRATA_SNAP_HEAT=1` turns on heat mode.
@MainActor func manifestScenes() -> [Scene] {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["STRATA_SNAP_MANIFEST"], let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    let (parsed, diagnostics) = ManifestParser.parse(text, source: .file(URL(fileURLWithPath: path)))
    guard let manifest = parsed else {
        diagnostics.forEach { print($0) }
        return []
    }
    let seconds = Double(env["STRATA_SNAP_T"] ?? "") ?? 8
    return [Scene(name: "manifest-\(manifest.id)", size: CGSize(width: 1400, height: 880)) {
        let model = AppModel(library: Library(manifests: [manifest]),
                             vault: Vault(root: FileManager.default.temporaryDirectory.appendingPathComponent("strata-snap-vault")))
        let sim = Simulation(manifest: manifest)
        if let scenario = env["STRATA_SNAP_SCENARIO"] { sim.start(scenario: scenario) }
        var t = 0.0
        while t < seconds { sim.tick(1.0 / 60); t += 1.0 / 60 }
        sim.playing = false
        model.sessions[AppModel.sessionKey(manifest.id, [])] = sim
        let op = env["STRATA_SNAP_OP"]?.split(separator: "/").map(String.init)
        let selected = env["STRATA_SNAP_SELECT"] ?? op?.first
        if let op, op.count == 2 { SimOpsSnapshot.open(sim, node: op[0], op: op[1], from: selected) }
        let tabs: [String: SimDockTab] = ["controls": .controls, "try": .scenarios, "scenarios": .scenarios, "pressure": .pressure,
                                          "log": .log, "glossary": .glossary, "about": .about]
        let sections: [String: SimPressureSection] = ["now": .now, "bottlenecks": .bottlenecks, "scale": .scale, "stores": .stores,
                                                      "volumes": .volumes, "capacity": .capacity]
        if let section = env["STRATA_SNAP_PRESSURE"].flatMap({ sections[$0] }) { SimPressureSnapshot.section(sim, section) }
        if env["STRATA_SNAP_HEAT"] == "1" { SimPressureSnapshot.heat(sim) }
        let tab = env["STRATA_SNAP_DOCK"].flatMap { tabs[$0] } ?? (env["STRATA_SNAP_SCENARIO"] == nil ? .controls : .scenarios)
        let options = SimSnapshotOptions(selectedNode: selected, dockTab: tab, previewMenu: false)
        return AnyView(SimScreen(model: model, id: manifest.id, path: [], snapshot: options))
    }]
}
