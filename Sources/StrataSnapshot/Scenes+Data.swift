import AppKit
import SwiftUI
import StrataCore
@_spi(Snapshots) import StrataUI

// Data: a database's tables (diagram, table view, joins), a service's entities, and the ways in (an op's
// table chip, the node menu, ⌘K), on `Fixtures.checkoutWithData`.

@MainActor func dataScenes() -> [Scene] {
    [
        dataScene("data-db-diagram", height: 880, selected: "db"),
        dataScene("data-table-view", height: 1640, selected: "db") { sim in
            SimDataSnapshot.openTable(sim, node: "db", table: "orders")
        },
        dataScene("data-join-highlight", height: 1960, selected: "db") { sim in
            SimDataSnapshot.focus(sim, node: "db", table: "orders", column: "id", value: "o-9f1c")
        },
        dataScene("data-join-child", height: 1960, selected: "db") { sim in
            SimDataSnapshot.focus(sim, node: "db", table: "order_items", column: "sku", value: "D-9")
        },
        dataScene("data-entity-tree", height: 1500, selected: "orders") { sim in
            SimDataSnapshot.expandEntity(sim, node: "orders", entity: "Order")
        },
        dataScene("data-entity-price", height: 1100, selected: "orders") { sim in
            SimDataSnapshot.expandEntity(sim, node: "orders", entity: "Price", rootRow: 1)
        },
        dataLandingScene(),
        dataMenuScene(),
        dataPaletteScene(),
    ]
}

@MainActor private func dataScene(_ name: String, height: CGFloat, selected: String? = nil,
                                  prepare: @escaping (Simulation) -> Void = { _ in }) -> Scene {
    Scene(name: name, size: CGSize(width: 1400, height: height)) {
        let manifest = dataManifest()
        let model = dataModel(manifest)
        let sim = Simulation(manifest: manifest)
        settle(sim)
        model.sessions[AppModel.sessionKey(manifest.id, [])] = sim
        prepare(sim)
        return AnyView(SimScreen(model: model, id: manifest.id, path: [], snapshot: SimSnapshotOptions(selectedNode: selected)))
    }
}

/// The op detail's table chip: orders-svc's `INSERT order + outbox` is open, then its `orders` chip is
/// clicked, which selects the database and scrolls its inspector to the table. Hosted, so the
/// inspector really scrolls.
@MainActor private func dataLandingScene() -> Scene {
    Scene(name: "data-op-chip-landing", size: CGSize(width: 1400, height: 880), hosted: true) {
        let manifest = dataManifest()
        let model = dataModel(manifest)
        model.open(.sim(manifest.id, path: []))
        model.sidebarVisible = false
        let sim = Simulation(manifest: manifest)
        settle(sim)
        model.sessions[AppModel.sessionKey(manifest.id, [])] = sim
        SimOpsSnapshot.select("orders", in: manifest.id, model: model)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            SimOpsSnapshot.open(sim, node: "orders", op: "insert-order", from: "orders")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                SimDataSnapshot.landOnTable(sim, model: model, node: "db", table: "orders")
            }
        }
        return AnyView(RootView(model: model, fixtureEntries: model.library.entries, fixtureNotes: [:]))
    }
}

/// A right-click on the database with its "Tables ›" submenu open.
@MainActor private func dataMenuScene() -> Scene {
    Scene(name: "data-node-menu", size: CGSize(width: 1400, height: 880), hosted: true) {
        let manifest = dataManifest()
        let model = dataModel(manifest)
        model.open(.sim(manifest.id, path: []))
        model.sidebarVisible = false
        let sim = Simulation(manifest: manifest)
        settle(sim)
        model.sessions[AppModel.sessionKey(manifest.id, [])] = sim
        SimOpsSnapshot.select("db", in: manifest.id, model: model)
        let items = SimDataSnapshot.nodeMenu(sim, model: model, node: "db")
        let actionable = items.filter { $0.enabled && !$0.isHeader && !$0.isSeparator }
        let steps = (actionable.firstIndex { $0.title == "Tables" } ?? 0) + 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            model.overlays.showMenu(items, at: CGPoint(x: 560, y: 300))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                dataPress(Array(repeating: UInt16(125), count: steps) + [124])
            }
        }
        return AnyView(RootView(model: model, fixtureEntries: model.library.entries, fixtureNotes: [:]))
    }
}

/// ⌘K with the current sim's Data group.
@MainActor private func dataPaletteScene() -> Scene {
    Scene(name: "data-palette", size: CGSize(width: 1400, height: 880), hosted: true) {
        let manifest = dataManifest()
        let model = dataModel(manifest)
        model.open(.sim(manifest.id, path: []))
        let sim = Simulation(manifest: manifest)
        settle(sim)
        model.sessions[AppModel.sessionKey(manifest.id, [])] = sim
        model.paletteOpen = true
        return AnyView(RootView(model: model, fixtureEntries: model.library.entries, fixtureNotes: [:],
                                fixturePaletteQuery: "order"))
    }
}

/// Arrow keys straight to the snapshot window, as the overlay's key monitor sees them.
@MainActor private func dataPress(_ keys: [UInt16]) {
    guard let window = NSApp.windows.last else { return }
    for key in keys {
        let arrow = String(UnicodeScalar(key == 124 ? NSRightArrowFunctionKey : NSDownArrowFunctionKey)!)
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: arrow,
                                           charactersIgnoringModifiers: arrow, isARepeat: false, keyCode: key) else { continue }
        NSApp.sendEvent(event)
    }
}

@MainActor private func dataModel(_ manifest: Manifest) -> AppModel {
    AppModel(library: Library(manifests: [manifest]),
             vault: Vault(root: FileManager.default.temporaryDirectory.appendingPathComponent("strata-snap-vault")))
}

private func dataManifest() -> Manifest {
    var manifest = Fixtures.checkoutWithData
    for index in manifest.root.edges.indices { manifest.root.edges[index].latency = .fixed(0.12) }
    return manifest
}

@MainActor private func settle(_ sim: Simulation) {
    sim.playing = true
    for _ in 0..<180 { sim.tick(1.0 / 60) }
    sim.playing = false
}
