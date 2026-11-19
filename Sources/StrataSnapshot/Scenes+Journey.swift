import AppKit
import SwiftUI
import StrataCore
@_spi(Snapshots) import StrataUI

// Journeys: the checkout example's order followed from cart to paid, at the start, mid-way through the
// commit, on the deep-dive relay step and at the end; top to bottom; and at a narrow width.

@MainActor func journeyScenes() -> [Scene] {
    let size = CGSize(width: 1400, height: 880)
    return [
        journeyScene("journey-checkout-start", size: size, step: "0"),
        journeyScene("journey-checkout-commit", size: size, step: "commit"),
        journeyScene("journey-checkout-claim", size: size, step: "claim"),
        journeyScene("journey-checkout-capture", size: size, step: "capture"),
        journeyScene("journey-checkout-down", size: size, step: "publish", direction: .down),
        journeyScene("journey-checkout-narrow", size: CGSize(width: 980, height: 760), step: "commit"),
        journeyScene("journey-checkout-narrow-rows", size: CGSize(width: 820, height: 720), step: "capture", rows: true, inspector: false),
        journeyScene("journey-checkout-inspector", size: size, step: nil),
        journeyKeysScene(size: size),
    ]
}

/// The real window: the journey opened at its start, then → four times and ← once through the stage's
/// key handling, which lands on step 3 (the price read).
@MainActor private func journeyKeysScene(size: CGSize) -> Scene {
    Scene(name: "journey-checkout-keys", size: size, hosted: true) {
        let manifest = Library(builtIn: StrataResources.url("Examples")!, dirs: []).manifest("checkout")!
        let model = AppModel(library: Library(manifests: [manifest]),
                             vault: Vault(root: FileManager.default.temporaryDirectory.appendingPathComponent("strata-snap-vault")))
        model.open(.sim(manifest.id, path: []))
        model.sidebarVisible = false
        let sim = Simulation(manifest: manifest)
        sim.playing = false
        model.sessions[AppModel.sessionKey(manifest.id, [])] = sim
        SimJourneySnapshot.open(model, manifest: manifest, journey: "order-to-paid", step: "0")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { journeyPress([124, 124, 124, 124, 123]) }
        return AnyView(RootView(model: model, fixtureEntries: model.library.entries, fixtureNotes: [:]))
    }
}

@MainActor private func journeyPress(_ keys: [UInt16]) {
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

@MainActor private func journeyScene(_ name: String, size: CGSize, step: String?, direction: FlowDirection? = nil,
                                     rows: Bool = false, inspector: Bool = true) -> Scene {
    Scene(name: name, size: size) {
        let manifest = Library(builtIn: StrataResources.url("Examples")!, dirs: []).manifest("checkout")!
        let model = AppModel(library: Library(manifests: [manifest]),
                             vault: Vault(root: FileManager.default.temporaryDirectory.appendingPathComponent("strata-snap-vault")))
        model.inspectorVisible = inspector
        let sim = Simulation(manifest: manifest)
        var t = 0.0
        while t < 4 { sim.tick(1.0 / 60); t += 1.0 / 60 }
        sim.playing = false
        model.sessions[AppModel.sessionKey(manifest.id, [])] = sim
        if let direction {
            model.layoutDirections[manifest.id] = direction
            SimStageSnapshot.direct(sim, direction)
        }
        if let step { SimJourneySnapshot.open(model, manifest: manifest, journey: "order-to-paid", step: step) }
        if rows { SimJourneySnapshot.showRows(model) }
        return AnyView(SimScreen(model: model, id: manifest.id, path: [], snapshot: SimSnapshotOptions()))
    }
}
