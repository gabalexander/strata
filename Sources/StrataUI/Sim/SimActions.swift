import AppKit
import SwiftUI
import StrataCore

@MainActor
struct SimActions {
    let model: AppModel
    let sim: Simulation
    let fit: () -> Void
    let dive: (Node) -> Void
    /// Re-runs auto layout for this level and fits the view ("Tidy layout"); nil where it isn't offered.
    var tidy: (() -> Void)?
    /// The vertical/horizontal switch for the whole map; nil where it isn't offered.
    var flip: (() -> Void)?

    func palette(selection: StageSelection? = nil) -> [MenuItem] {
        var items = [
            play, command("Reset simulation", icon: "arrow.counterclockwise", shortcut: "⌘R") { sim.reset() },
            command("Step simulation", icon: "forward.frame", shortcut: ".") { sim.pauseAndStep() },
            fitItem,
        ] + (tidyItem.map { [$0] } ?? []) + (flipItem.map { [$0] } ?? []) + sim.level.scenarios.map(scenarioItem)
            + sim.level.flows.filter { !$0.isConsumer }.map(sendItem)
            + sim.level.nodes.filter(\.canDeepDive).map { node in
                command("Deep dive into \(node.label)", icon: "square.3.layers.3d") { dive(node) }
            }
            + SimPressureMenus.palette(sim: sim, model: model)
            + SimHowMenus.palette(sim: sim)
        if let selection {
            let menu = menu(for: selection)
            if let heading = menu.first, heading.isHeader {
                // Operations and data have their own ⌘K groups (SimOpsPalette, SimDataPalette).
                let own = [SimOpsMenus.submenuTitle, SimDataMenus.tablesTitle, SimDataMenus.entitiesTitle]
                let commands = menu.dropFirst().filter { !own.contains($0.title) }.compactMap(Self.paletteCommand)
                if !commands.isEmpty { items += [.submenu(heading.title, icon: nil, commands)] }
            }
        }
        return items
    }

    private static func paletteCommand(_ item: MenuItem) -> MenuItem? {
        guard item.enabled, !item.isSeparator, !item.isHeader else { return nil }
        var command = item
        command.submenu = item.submenu.compactMap(paletteCommand)
        return command.action != nil || !command.submenu.isEmpty ? command : nil
    }

    func menu(for hit: StageSelection?) -> [MenuItem] {
        switch hit {
        case .node(let id):
            guard let node = sim.level.node(id) else { return [] }
            let state = sim.nodeState(id) ?? NodeState()
            var items = [MenuItem.header(node.label)]
            items += nodeActions(node, state: state, full: true)
            if let ops = SimOpsMenus.node(node, sim: sim, model: model) { items += [.separator, ops] }
            let data = SimDataMenus.node(node, sim: sim, model: model)
            if !data.isEmpty { items += (items.last?.submenu.isEmpty ?? true ? [.separator] : []) + data }
            items += SimPressureMenus.node(node, sim: sim, model: model)
            items += SimHowMenus.node(node, sim: sim)
            let sourceFlows = sim.level.flows.filter { $0.from == node.id }
            if !sourceFlows.isEmpty { items += [.separator] + sourceFlows.map(sendItem) }
            if supportsNotes {
                items.append(.separator)
                if model.vault.hasNote(notePath(node)) {
                    items.append(command("Open note", icon: "note.text") { model.open(.note(notePath(node))) })
                } else {
                    items.append(command("Add a note", icon: "note.text.badge.plus") { addNote(node) })
                }
            }
            if let single = node.code.first, node.code.count == 1 {
                items.append(command("Open code", icon: "chevron.left.forwardslash.chevron.right") { openCode(single) })
            } else if !node.code.isEmpty {
                items.append(.submenu("Open code", icon: "chevron.left.forwardslash.chevron.right",
                                      node.code.map { path in command(path, icon: "doc.text") { openCode(path) } }))
            }
            items += [.separator, command("Copy id", icon: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.id, forType: .string)
                model.overlays.toast("Copied \(node.id)")
            }]
            return items
        case .edge(let id):
            guard let edge = sim.diagramEdge(id) else { return [] }
            let state = sim.edgeState(id) ?? EdgeState()
            return [.header(edgeTitle(edge))] + edgeActions(edge, state: state)
        case .flow(let id):
            guard let flow = sim.level.flow(id) else { return [] }
            return [.header(flow.label)] + (flow.isConsumer ? [play] : [sendItem(flow), play])
        case nil:
            var items = [fitItem] + (tidyItem.map { [$0] } ?? []) + (flipItem.map { [$0] } ?? [])
                + [play, command("Reset", icon: "arrow.counterclockwise", shortcut: "⌘R") { sim.reset() }]
            let sources = sim.level.flows.filter { !$0.isConsumer }
            if !sources.isEmpty { items.append(.submenu("Send", icon: "paperplane", sources.map(sendItem))) }
            if !sim.level.scenarios.isEmpty {
                items.append(.submenu("Scenarios", icon: "flag", sim.level.scenarios.map(scenarioItem)))
            }
            return items
        }
    }

    func nodeActions(_ node: Node, state: NodeState, full: Bool = false) -> [MenuItem] {
        let custom = node.actions.map { action in
            command(action.label, icon: action.icon) { sim.perform(action.commands) }
        }
        if node.kind == .note { return custom }
        let id = node.id
        let effective = sim.effective(id)
        let down = state.health == .down
        let slow = (sim.value(StrataCore.Binding(.node(id), "slow"))?.number ?? (state.health == .slow ? 10 : 1)) > 1
        let errors = (effective.errors ?? 0) > 0 || state.health == .failing
        var items: [MenuItem] = []
        if node.canDeepDive {
            items.append(command("Deep dive", icon: "square.3.layers.3d") { dive(node) })
        }
        items.append(command(down ? "Restore" : "Kill", icon: down ? "arrow.clockwise" : "power",
                             role: down ? .normal : .destructive) { sim.perform([down ? .restore(id) : .kill(id)]) })
        if node.kind.role == .server || node.kind.role == .buffer {
            items.append(command(slow ? "Normal speed" : "Slow ×10", icon: "tortoise") {
                sim.perform([.slow(id, slow ? 1 : 10)])
            })
            items.append(command(errors ? "Clear errors" : full ? "Inject errors 50%" : "Errors 50%", icon: "exclamationmark.triangle") {
                sim.perform([.fail(id, errors ? 0 : 0.5)])
            })
        }
        if node.kind.role == .server {
            items.append(command("Scale +1", icon: "plus.square") { sim.perform([.scale(id, 1, relative: true)]) })
            items.append(command("Scale −1", icon: "minus.square", enabled: (effective.replicas ?? state.replicas) > 1) {
                sim.perform([.scale(id, -1, relative: true)])
            })
        }
        return items + custom
    }

    func edgeActions(_ edge: StrataCore.Edge, state: EdgeState) -> [MenuItem] {
        let binding = StrataCore.Binding(.edge(from: edge.from, to: edge.to), "loss")
        let loss = sim.value(binding)?.number ?? edge.loss ?? 0
        return [
            command(state.cut ? "Heal" : "Cut", icon: state.cut ? "link" : "scissors",
                    role: state.cut ? .normal : .destructive) {
                sim.perform([state.cut ? .heal(edge.from, edge.to) : .cut(edge.from, edge.to)])
            },
            command(state.extraLatency > 0 ? "Clear delay" : "Add 200 ms", icon: "timer") {
                sim.perform([.delay(edge.from, edge.to, state.extraLatency > 0 ? 0 : 0.2)])
            },
            command(loss > 0 ? "Loss 0%" : "Loss 10%", icon: "waveform.path") {
                sim.setValue(.number(loss > 0 ? 0 : 0.1), for: binding)
            },
        ]
    }

    /// Node notes live under the manifest's library id; a diagram written inline in a note has none.
    var supportsNotes: Bool {
        if case .inline = sim.manifest.source { return false }
        return true
    }

    func notePath(_ node: Node) -> String {
        model.vault.nodeNotePath(sim: sim.manifest.id, levelPath: sim.path, node: node.id)
    }

    func addNote(_ node: Node) {
        guard supportsNotes else { return }
        let path = notePath(node)
        if !model.vault.hasNote(path) {
            let text = "# \(node.label)\n\n[[\(sim.manifest.id)]]\n\n## What it does\n\n## Gotchas\n"
            model.vault.createNote(at: path, text: text)
        }
        model.open(.note(path))
    }

    func openCode(_ code: String) { model.openCode(code, repo: sim.manifest.repo) }

    func open(_ link: StrataCore.Link) {
        switch link.target {
        case .note(let path): model.open(.note(path))
        case .sim(let id): model.open(.sim(id, path: []))
        case .url(let string):
            if let url = URL(string: string) { NSWorkspace.shared.open(url) }
        }
    }

    func edgeTitle(_ edge: StrataCore.Edge) -> String {
        "\(sim.level.node(edge.from)?.label ?? edge.from) → \(sim.level.node(edge.to)?.label ?? edge.to)"
    }

    private var play: MenuItem {
        command(sim.playing ? "Pause" : "Play", icon: sim.playing ? "pause.fill" : "play.fill", shortcut: "Space") {
            sim.playing.toggle()
        }
    }

    private var fitItem: MenuItem { command("Fit view", icon: "arrow.up.left.and.arrow.down.right", shortcut: "⌘0", action: fit) }

    private var tidyItem: MenuItem? {
        tidy.map { command("Tidy layout", icon: SimActions.tidyIcon, shortcut: "⌥⌘L", action: $0) }
    }

    static let tidyIcon = "wand.and.rays"

    private var flipItem: MenuItem? {
        let down = (model.layoutDirections[sim.manifest.id] ?? sim.level.direction ?? .right) == .down
        return flip.map { command(down ? "Lay out left to right" : "Lay out top to bottom", icon: SimActions.flipIcon,
                                  shortcut: "⌥⌘V", action: $0) }
    }

    static let flipIcon = "arrow.down.square"

    private func sendItem(_ flow: Flow) -> MenuItem {
        command("Send \(flow.label)", icon: "paperplane") { sim.send(flow.id) }
    }

    private func scenarioItem(_ scenario: Scenario) -> MenuItem {
        let running = sim.scenario == scenario.id
        return command("\(running ? "Stop" : "Run") \(scenario.label)", icon: "flag", checked: running) {
            if running { sim.stopScenario() }
            else { sim.start(scenario: scenario.id) }
        }
    }

    private func command(_ title: String, icon: String?, shortcut: String? = nil,
                         role: MenuItem.Role = .normal, enabled: Bool = true, checked: Bool = false,
                         action: @escaping @MainActor () -> Void) -> MenuItem {
        MenuItem(title, icon: icon, shortcut: shortcut, role: role, enabled: enabled, checked: checked, action: action)
    }
}

@MainActor
struct SimPaletteCommands: View {
    let actions: SimActions
    let selection: StageSelection?
    @State private var commandID: UUID?

    private struct Presentation: Equatable {
        let title: String
        let checked: Bool
        let children: [Presentation]

        init(_ item: MenuItem) {
            title = item.title
            checked = item.checked
            children = item.submenu.map(Self.init)
        }
    }

    private struct Commands: Equatable {
        let selection: StageSelection?
        let items: [Presentation]
    }

    var body: some View {
        let _ = selection == nil ? 0 : actions.sim.revision
        let items = actions.palette(selection: selection)
        let commands = Commands(selection: selection, items: items.map(Presentation.init))
        Color.clear
            .onChange(of: commands, initial: true) {
                commandID = items.first?.id
                actions.model.screenCommands = items
            }
            .onDisappear {
                if actions.model.screenCommands.first?.id == commandID { actions.model.screenCommands = [] }
            }
    }
}

@MainActor
struct SimActionButtons: View {
    let items: [MenuItem]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 106), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                SimButton(title: item.title, icon: item.icon, tint: item.role == .destructive ? Theme.bad : Theme.muted) {
                    item.action?()
                }
                .disabled(!item.enabled)
                .opacity(item.enabled ? 1 : 0.45)
            }
        }
    }
}

extension Simulation {
    func pauseAndStep() {
        playing = false
        step()
    }
}
