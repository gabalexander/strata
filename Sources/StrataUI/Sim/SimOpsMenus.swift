import AppKit
import SwiftUI
import StrataCore

/// Right-click menus and ⌘K entries for operations.
@MainActor
enum SimOpsMenus {
    static let submenuTitle = "Operations"

    /// Opens an op's detail in the inspector, replacing what `anchor` shows.
    static func open(_ ref: OpRef, sim: Simulation, model: AppModel, anchor: StageSelection?) {
        SimOpsState.of(sim).open(ref, from: anchor)
        model.inspectorVisible = true
    }

    /// A node's "Operations ›" submenu: its own ops, or for a database, cache or buffer with none,
    /// the ops on other nodes that talk to it.
    static func node(_ node: Node, sim: Simulation, model: AppModel) -> MenuItem? {
        let index = SimOpsState.of(sim).index
        let own = index.ops(of: node.id)
        let entries = own.isEmpty ? index.targeting(node.id) : own
        guard !entries.isEmpty else { return nil }
        let anchor = StageSelection.node(node.id)
        let groups = OpGroup.allCases.map { group in (group, entries.filter { OpGroup.of($0.op) == group }) }
            .filter { !$0.1.isEmpty }
        let headed = groups.count > 1 && entries.count > 4
        var items: [MenuItem] = []
        for (offset, (group, rows)) in groups.enumerated() {
            if headed {
                if offset > 0 { items.append(.separator) }
                items.append(.header(group.title))
            }
            items += rows.map { entry in
                MenuItem(own.isEmpty ? SimOpsText.title(entry) : entry.op.label, icon: entry.op.kind.symbol) {
                    open(entry.ref, sim: sim, model: model, anchor: anchor)
                }
            }
        }
        return .submenu(submenuTitle, icon: "list.bullet.rectangle", items)
    }

    /// An op row's menu: Open, Open code, Copy query or payload, Highlight path.
    static func row(_ entry: SimOpsIndex.Entry, sim: Simulation, model: AppModel, anchor: StageSelection?,
                    includeOpen: Bool = true) -> [MenuItem] {
        let state = SimOpsState.of(sim)
        let ref = entry.ref
        var items: [MenuItem] = [.header(SimOpsText.title(entry))]
        if includeOpen {
            items.append(MenuItem("Open", icon: "arrow.up.right.square") {
                open(ref, sim: sim, model: model, anchor: anchor)
            })
        }
        let code = entry.op.code
        if let single = code.first, code.count == 1 {
            items.append(MenuItem("Open code", icon: "chevron.left.forwardslash.chevron.right") {
                model.openCode(single, repo: sim.manifest.repo)
            })
        } else if !code.isEmpty {
            items.append(.submenu("Open code", icon: "chevron.left.forwardslash.chevron.right", code.map { path in
                MenuItem(path, icon: "doc.text") { model.openCode(path, repo: sim.manifest.repo) }
            }))
        }
        if let copy = SimOpsText.copyable(entry.op) {
            items.append(MenuItem(copy.title, icon: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copy.text, forType: .string)
                model.overlays.toast(copy.title.replacingOccurrences(of: "Copy", with: "Copied"))
            })
        }
        let pinned = state.isPinned(ref, at: anchor)
        items.append(MenuItem(pinned ? "Clear highlight" : "Highlight path", icon: "point.topleft.down.to.point.bottomright.curvepath",
                              checked: pinned) {
            state.togglePin(ref, at: anchor)
        })
        return items
    }
}

/// The ⌘K palette's "Operations" group: every op on the current level, titled `orders-svc · INSERT
/// order + outbox`. Choosing one selects its node and opens the op detail.
@MainActor
enum SimOpsPalette {
    static func entries(model: AppModel, manifest: Manifest?) -> [PaletteEntry] {
        guard case .sim(let id, let path) = model.route, let level = manifest?.level(at: path) else { return [] }
        let key = AppModel.sessionKey(id, path)
        let index = model.sessions[key].map { SimOpsState.of($0).index } ?? SimOpsIndex(level: level)
        return index.all.map { entry in
            let op = entry.op
            let keywords = [entry.node.id, op.id, op.kind.rawValue, op.target, op.topic, op.method, op.path, op.key,
                            op.command].compactMap { $0 } + op.tables + op.tags
            return PaletteEntry(id: "op/\(key)/\(entry.node.id)/\(op.id)", group: .operations,
                                title: SimOpsText.title(entry), symbol: op.kind.symbol,
                                subtitle: SimOpsText.summary(entry, in: level), keywords: keywords.joined(separator: " ")) {
                if let sim = model.sessions[key] {
                    SimOpsMenus.open(entry.ref, sim: sim, model: model, anchor: .node(entry.node.id))
                }
                SimFocus.of(model).reveal(entry.node.id, in: id, path: path, model: model)
            }
        }
    }
}
