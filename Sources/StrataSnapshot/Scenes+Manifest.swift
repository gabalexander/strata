import SwiftUI
import StrataCore
@_spi(Snapshots) import StrataUI

/// Renders any manifest file: `STRATA_SNAP_MANIFEST=path.yaml [STRATA_SNAP_SCENARIO=id] [STRATA_SNAP_T=8]
/// [STRATA_SNAP_SELECT=node] [STRATA_SNAP_OP=node/op] swift run StrataSnapshot build/snapshots manifest-`.
/// For authors and agents checking how a manifest looks on the stage without launching the app.
/// `STRATA_SNAP_OP` opens that operation's detail in the inspector (and selects its node). In a deep
/// dive, `STRATA_SNAP_OP=../op` opens an op of the node it is inside, from the overview unless
/// `STRATA_SNAP_SELECT` names a node. `STRATA_SNAP_H=1400` renders a taller frame (default 880).
/// `STRATA_SNAP_DOCK=pressure` opens that dock tab (controls, try, pressure, log, glossary, about);
/// `STRATA_SNAP_PRESSURE=bottlenecks` picks the Pressure section (now, bottlenecks, scale, stores,
/// volumes, capacity) and `STRATA_SNAP_HEAT=1` turns on heat mode.
/// `STRATA_SNAP_PATH=orders/orders#insert-order` opens a deep-dive level (node ids, `node#op` for an op's
/// `inside:`), `STRATA_SNAP_STAGE=1` hides the dock and inspector so the stage fills the frame, and
/// `STRATA_SNAP_TIDY=1` runs "Tidy layout" first. `STRATA_SNAP_DIRECTION=down` (or `right`) flips the level
/// with the stage's vertical/horizontal switch, and `STRATA_SNAP_SIZE=2400x1600` renders a larger frame.
/// `STRATA_SNAP_HOW=node/mechanism` (or `node/op/mechanism`) opens that How it works player, paused at
/// `STRATA_SNAP_HOW_STEP` (a step id, or its 1-based number in the path; the start by default) on the
/// path of `STRATA_SNAP_HOW_BRANCH`, with that step's detail open (`STRATA_SNAP_HOW_DETAIL=0` keeps the
/// state panel instead). `STRATA_SNAP_JOURNEY=id` opens that journey's player at `STRATA_SNAP_JOURNEY_STEP`
/// (a step id, or its 1-based number; the start by default); `STRATA_SNAP_JOURNEY_ROWS=1` shows the
/// rows pane in the narrow layout and `STRATA_SNAP_JOURNEY_EXPAND=1` lists every column of each row.
@MainActor func manifestScenes() -> [Scene] {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["STRATA_SNAP_MANIFEST"], let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    let (parsed, diagnostics) = ManifestParser.parse(text, source: .file(URL(fileURLWithPath: path)))
    guard let manifest = parsed else {
        diagnostics.forEach { print($0) }
        return []
    }
    let seconds = Double(env["STRATA_SNAP_T"] ?? "") ?? 8
    let levelPath = (env["STRATA_SNAP_PATH"] ?? "").split(separator: "/").map(String.init)
    guard manifest.level(at: levelPath) != nil else {
        print("no level at \(levelPath.joined(separator: "/")) in \(manifest.id)")
        return []
    }
    let direction = env["STRATA_SNAP_DIRECTION"].flatMap(FlowDirection.init(rawValue:))
    let name = (["manifest-\(manifest.id)"] + levelPath + (env["STRATA_SNAP_TIDY"] == "1" ? ["tidy"] : [])
                + (direction.map { [$0.rawValue] } ?? [])
                + (env["STRATA_SNAP_HOW"].map { ["how", $0, env["STRATA_SNAP_HOW_BRANCH"] ?? "", env["STRATA_SNAP_HOW_STEP"] ?? "",
                                                 env["STRATA_SNAP_HOW_DETAIL"] == "0" ? "state" : ""] } ?? [])
                + (env["STRATA_SNAP_JOURNEY"].map { ["journey", $0, env["STRATA_SNAP_JOURNEY_STEP"] ?? "start"] } ?? [])
                + (dimensionsTag(env).map { [$0] } ?? [])
                    .filter { !$0.isEmpty })
        .joined(separator: "-").replacingOccurrences(of: "#", with: "_").replacingOccurrences(of: "/", with: "_")
    // STRATA_SNAP_SIZE=WxH sets both; STRATA_SNAP_H only the height.
    let height = Double(env["STRATA_SNAP_H"] ?? "").map { max(400, min(4000, $0)) } ?? 880
    let dimensions = (env["STRATA_SNAP_SIZE"] ?? "").split(separator: "x").compactMap { Double($0) }
    let size = dimensions.count == 2 ? CGSize(width: dimensions[0], height: dimensions[1]) : CGSize(width: 1400, height: height)
    return [Scene(name: name, size: size) {
        let model = AppModel(library: Library(manifests: [manifest]),
                             vault: Vault(root: FileManager.default.temporaryDirectory.appendingPathComponent("strata-snap-vault")))
        if env["STRATA_SNAP_STAGE"] == "1" {
            model.inspectorVisible = false
            model.dockVisible = false
        }
        let sim = Simulation(manifest: manifest, path: levelPath)
        if let scenario = env["STRATA_SNAP_SCENARIO"] { sim.start(scenario: scenario) }
        var t = 0.0
        while t < seconds { sim.tick(1.0 / 60); t += 1.0 / 60 }
        sim.playing = false
        model.sessions[AppModel.sessionKey(manifest.id, levelPath)] = sim
        let op = env["STRATA_SNAP_OP"]?.split(separator: "/").map(String.init)
        let selected = env["STRATA_SNAP_SELECT"] ?? op?.first.flatMap { $0 == InheritedOps.ownerKey ? nil : $0 }
        if let op, op.count == 2 { SimOpsSnapshot.open(sim, node: op[0], op: op[1], from: selected) }
        let tabs: [String: SimDockTab] = ["controls": .controls, "try": .scenarios, "scenarios": .scenarios, "pressure": .pressure,
                                          "log": .log, "glossary": .glossary, "about": .about]
        let sections: [String: SimPressureSection] = ["now": .now, "bottlenecks": .bottlenecks, "scale": .scale, "stores": .stores,
                                                      "volumes": .volumes, "capacity": .capacity]
        if let section = env["STRATA_SNAP_PRESSURE"].flatMap({ sections[$0] }) { SimPressureSnapshot.section(sim, section) }
        if env["STRATA_SNAP_HEAT"] == "1" { SimPressureSnapshot.heat(sim) }
        if let direction {
            model.layoutDirections[manifest.id] = direction
            SimStageSnapshot.direct(sim, direction)
        }
        if env["STRATA_SNAP_TIDY"] == "1" { SimStageSnapshot.tidy(sim) }
        if let how = env["STRATA_SNAP_HOW"]?.split(separator: "/").map(String.init), how.count >= 2 {
            SimHowSnapshot.open(sim, node: how[0], op: how.count > 2 ? how[1] : nil, mechanism: how[how.count - 1],
                                branch: env["STRATA_SNAP_HOW_BRANCH"], step: env["STRATA_SNAP_HOW_STEP"] ?? "0")
            if env["STRATA_SNAP_HOW_STEP"] != nil, env["STRATA_SNAP_HOW_DETAIL"] != "0" { SimHowSnapshot.inspect(sim) }
        }
        if let journey = env["STRATA_SNAP_JOURNEY"] {
            SimJourneySnapshot.open(model, manifest: manifest, journey: journey, step: env["STRATA_SNAP_JOURNEY_STEP"] ?? "0")
            if env["STRATA_SNAP_JOURNEY_ROWS"] == "1" { SimJourneySnapshot.showRows(model) }
            if env["STRATA_SNAP_JOURNEY_EXPAND"] == "1" { SimJourneySnapshot.expandRows(model) }
        }
        let tab = env["STRATA_SNAP_DOCK"].flatMap { tabs[$0] } ?? (env["STRATA_SNAP_SCENARIO"] == nil ? .controls : .scenarios)
        let options = SimSnapshotOptions(selectedNode: selected, dockTab: tab, previewMenu: false)
        return AnyView(SimScreen(model: model, id: manifest.id, path: levelPath, snapshot: options))
    }]
}

/// `1100x800` in a scene name when STRATA_SNAP_SIZE sets one, so renders at several sizes don't overwrite each other.
private func dimensionsTag(_ env: [String: String]) -> String? {
    guard env["STRATA_SNAP_JOURNEY"] != nil, let size = env["STRATA_SNAP_SIZE"], !size.isEmpty else { return nil }
    return size
}
