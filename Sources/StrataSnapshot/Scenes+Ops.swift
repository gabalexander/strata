import AppKit
import SwiftUI
import StrataCore
@_spi(Snapshots) import StrataUI

// Operations: the inspector section, op details, reverse views, the stage path and the menus, on
// `Fixtures.checkoutWithOps`, with the engine's live op numbers.

@MainActor func opsScenes() -> [Scene] {
    let size = CGSize(width: 1400, height: 880)
    return [
        opsScene("ops-service-section", size: size, selected: "orders"),
        opsScene("ops-sql-detail", size: size, selected: "orders") { sim in
            SimOpsSnapshot.open(sim, node: "orders", op: "insert-order", from: "orders")
        },
        opsScene("ops-kafka-publish", size: size, selected: "orders") { sim in
            SimOpsSnapshot.open(sim, node: "orders", op: "order-placed", from: "orders")
        },
        opsScene("ops-http-endpoint", size: CGSize(width: 1400, height: 1480), selected: "orders") { sim in
            SimOpsSnapshot.open(sim, node: "orders", op: "create-order", from: "orders")
        },
        opsScene("ops-db-reverse", size: size, selected: "db"),
        opsScene("ops-topic-view", size: size, selected: "events"),
        opsScene("ops-cache-keys", size: size, selected: "cache"),
        opsScene("ops-path-highlight", size: size, selected: "orders") { sim in
            SimOpsSnapshot.hover(sim, node: "orders", op: "insert-order")
        },
        opsScene("ops-path-paused", size: size, selected: "db", paused: true) { sim in
            SimOpsSnapshot.pin(sim, node: "reporting", op: "backfill-status", at: "db")
        },
        opsScene("ops-inside", size: size, path: ["orders#insert-order"]),
        opsMenuScene(size: size),
        opsPaletteScene(size: size),
    ]
}

@MainActor private func opsScene(_ name: String, size: CGSize, path: [String] = [], selected: String? = nil,
                                 paused: Bool = false, prepare: @escaping (Simulation) -> Void = { _ in }) -> Scene {
    Scene(name: name, size: size) {
        let manifest = opsManifest()
        let model = opsModel(manifest)
        let sim = Simulation(manifest: manifest, path: path)
        if !path.isEmpty { model.open(.sim(manifest.id, path: path)) }
        advance(sim)
        if paused { sim.playing = false }
        model.sessions[AppModel.sessionKey(manifest.id, path)] = sim
        prepare(sim)
        return AnyView(SimScreen(model: model, id: manifest.id, path: path,
                                 snapshot: SimSnapshotOptions(selectedNode: selected)))
    }
}

/// A right-click on orders-svc with its "Operations ›" submenu open, as the real overlay draws it. The
/// menu is opened with the keyboard: arrow down to "Operations", then right.
@MainActor private func opsMenuScene(size: CGSize) -> Scene {
    Scene(name: "ops-node-menu", size: size, hosted: true) {
        let manifest = opsManifest()
        let model = opsModel(manifest)
        model.open(.sim(manifest.id, path: []))
        let sim = Simulation(manifest: manifest)
        advance(sim)
        sim.playing = false
        model.sessions[AppModel.sessionKey(manifest.id, [])] = sim
        model.sidebarVisible = false
        SimOpsSnapshot.select("orders", in: manifest.id, model: model)
        let items = SimOpsSnapshot.nodeMenu(sim, model: model, node: "orders")
        let actionable = items.filter { $0.enabled && !$0.isHeader && !$0.isSeparator }
        let steps = (actionable.firstIndex { $0.title == "Operations" } ?? 0) + 1
        // The sim screen selects orders-svc as it appears, which closes any menu: open it after that.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            model.overlays.showMenu(items, at: CGPoint(x: 500, y: 372))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                press(Array(repeating: UInt16(125), count: steps) + [124])
            }
        }
        return AnyView(RootView(model: model, fixtureEntries: model.library.entries, fixtureNotes: [:]))
    }
}

/// ⌘K with the current sim's Operations group.
@MainActor private func opsPaletteScene(size: CGSize) -> Scene {
    Scene(name: "ops-palette", size: size, hosted: true) {
        let manifest = opsManifest()
        let model = opsModel(manifest)
        model.open(.sim(manifest.id, path: []))
        let sim = Simulation(manifest: manifest)
        advance(sim)
        model.sessions[AppModel.sessionKey(manifest.id, [])] = sim
        model.paletteOpen = true
        return AnyView(RootView(model: model, fixtureEntries: model.library.entries, fixtureNotes: [:],
                                fixturePaletteQuery: "orders insert"))
    }
}

/// Sends key presses straight to the snapshot window; the overlay's local monitor handles them as it
/// would a real arrow key.
@MainActor private func press(_ keys: [UInt16]) {
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

@MainActor private func opsModel(_ manifest: Manifest) -> AppModel {
    AppModel(library: Library(manifests: [manifest]),
             vault: Vault(root: FileManager.default.temporaryDirectory.appendingPathComponent("strata-snap-vault")))
}

private func opsManifest() -> Manifest {
    var manifest = Fixtures.checkoutWithOps
    // At the fixture's usual one-millisecond latency, a still can land between every hop.
    for index in manifest.root.edges.indices { manifest.root.edges[index].latency = .fixed(0.12) }
    return manifest
}

@MainActor private func advance(_ sim: Simulation) {
    sim.playing = true
    for _ in 0..<180 { sim.tick(1.0 / 60) }
}
