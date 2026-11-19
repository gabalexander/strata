import AppKit
import SwiftUI
import StrataCore

/// What a click on an answer's link does: select a node, open an op's detail, play a mechanism, open
/// an enum or a table, dive into a level, select a flow or run a scenario. A target on another level
/// is prepared on that level's session first, then the level opens with its node selected.
@MainActor
enum SimAskNav {
    static func open(_ target: AskTarget, sim: Simulation, model: AppModel, select: @escaping (StageSelection?) -> Void) {
        let id = sim.manifest.id
        let here = target.path == nil || target.path == sim.path
        model.overlays.dismissMenu()
        switch target {
        case .node(let path, let node):
            model.inspectorVisible = true
            if here { select(.node(node)) } else { SimFocus.of(model).reveal(node, in: id, path: path, model: model) }

        case .op(let path, let node, let op):
            let session = session(path, sim: sim, model: model)
            if here { select(.node(node)) }
            SimOpsMenus.open(OpRef(node: node, op: op), sim: session, model: model, anchor: .node(node))
            if !here { SimFocus.of(model).reveal(node, in: id, path: path, model: model) }

        case .mechanism(let path, let node, let op, let mechanism):
            let session = session(path, sim: sim, model: model)
            guard let owner = session.level.node(node) else { return }
            let list = op.flatMap { opID in owner.ops.first { $0.id == opID }?.how } ?? owner.how
            guard let found = list.first(where: { $0.id == mechanism }) else { return }
            if here { select(.node(node)) }
            SimHowState.of(session).open(found, ref: SimHowRef(node: node, op: op, mechanism: mechanism), owner: owner.label)
            if !here { SimFocus.of(model).reveal(node, in: id, path: path, model: model) }

        case .enumeration(let enumID, let value):
            SimEnumState.of(model).open(SimEnumIndex.of(sim), enumID: enumID, value: value, model: model)

        case .table(let path, let node, let table):
            let ref = SimTableRef(node: node, table: table)
            if here { SimDataNav.open(ref, sim: sim, model: model, select: select) }
            else { SimDataNav.open(ref, sim: session(path, sim: sim, model: model), model: model, select: nil) }

        case .level(let path):
            guard !here else { return }
            open(level: path, sim: sim, model: model)

        case .flow(let path, let flow):
            if here { select(.flow(flow)) } else { open(level: path, sim: sim, model: model) }

        case .scenario(let path, let scenario):
            let session = session(path, sim: sim, model: model)
            let label = session.level.scenarios.first { $0.id == scenario }?.label ?? scenario
            session.start(scenario: scenario)
            session.playing = true
            if !here { open(level: path, sim: sim, model: model) }
            model.overlays.toast("Running \(label)")
        }
    }

    /// The session for a level of this map, made and remembered when that level hasn't been opened yet,
    /// so what the link opens on it is there when the level appears.
    private static func session(_ path: [String], sim: Simulation, model: AppModel) -> Simulation {
        if path == sim.path { return sim }
        let key = AppModel.sessionKey(sim.manifest.id, path)
        if let existing = model.sessions[key] { return existing }
        let made = Simulation(manifest: sim.manifest, path: path, parentRate: nil)
        SimSessions.remember(made, model: model, id: sim.manifest.id)
        return made
    }

    private static func open(level path: [String], sim: Simulation, model: AppModel) {
        let key = AppModel.sessionKey(sim.manifest.id, path)
        model.open(.sim(sim.manifest.id, path: path), parentRate: model.sessions[key]?.parentRate)
    }
}

/// ⌘L and ⌘K's "Ask the map…" open the Ask tab with the cursor in its field; the tab stays the open
/// one across the levels of a map.
@MainActor
struct SimAskHooks: View {
    let model: AppModel
    let sim: Simulation
    @SwiftUI.Binding var tab: SimDockTab

    static let shortcut = Shortcuts.ask.display

    var body: some View {
        let state = SimAskState.of(model, manifest: sim.manifest.id)
        WindowEvents(matching: .keyDown) { event, _ in
            guard Shortcuts.ask.matches(event), !model.paletteOpen, !model.switcherOpen, !model.shortcutSheetOpen,
                  !SimAskState.offInConfig(model) else { return event }
            open(state)
            return nil
        }
        .frame(width: 0, height: 0)
        .onChange(of: state.openRequest) { _, _ in open(state) }
        .onChange(of: tab, initial: true) { _, now in state.tabOpen = now == .ask }
    }

    /// Ask lives in the dock: a journey playing in the dock's place, or the How it works player over
    /// it, closes so the answer is in view.
    private func open(_ state: SimAskState) {
        model.overlays.dismissMenu()
        SimJourneyState.of(model).close()
        SimHowState.of(sim).close()
        tab = .ask
        model.dockVisible = true
        state.focusRequest += 1
    }
}

@MainActor
enum SimAskMenus {
    /// ⌘K: "Ask the map…" (⌘L).
    static func palette(sim: Simulation, model: AppModel) -> [MenuItem] {
        guard !SimAskState.offInConfig(model) else { return [] }
        return [MenuItem("Ask the map…", icon: "sparkle.magnifyingglass", shortcut: SimAskHooks.shortcut) {
            SimAskState.of(model, manifest: sim.manifest.id).openRequest += 1
        }]
    }
}
