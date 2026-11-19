import AppKit
import SwiftUI
import StrataCore
@_spi(Snapshots) import StrataUI

// Enums: sample cells with their names, the value hover card on a cell and in a query, the enum detail
// with its state machine, and ⌘K by value, on the bundled checkout (an integer-coded order status and a
// string payment status) and on the reference's campaign status (a cycle: pause and resume).

@MainActor func enumScenes() -> [Scene] {
    [
        enumScene("enums-data-grid", height: 1500, selected: "db") { sim, _ in
            SimDataSnapshot.openTable(sim, node: "db", table: "orders")
        },
        enumScene("enums-entity-tree", height: 1300, selected: "orders") { sim, _ in
            SimDataSnapshot.expandEntity(sim, node: "orders", entity: "Order")
            SimDataSnapshot.hoverField(sim, node: "orders", entity: "Order", path: "root.status")
        },
        enumScene("enums-sql-detail", height: 880, selected: "orders") { sim, _ in
            SimOpsSnapshot.open(sim, node: "orders", op: "capture-payment", from: "orders")
        },
        enumScene("enums-payload", height: 880, selected: "orders") { sim, _ in
            SimOpsSnapshot.open(sim, node: "orders", op: "get-order", from: "orders")
        },
        enumScene("enums-detail", height: 880, selected: "db") { sim, model in
            SimEnumSnapshot.open(sim, model: model, enumID: "order-status", value: "20")
        },
        enumScene("enums-detail-payment", height: 880, selected: "db") { sim, model in
            SimEnumSnapshot.open(sim, model: model, enumID: "payment-status", value: nil)
        },
        enumScene("enums-detail-cycle", height: 880, manifest: campaignManifest(), selected: "db") { sim, model in
            SimEnumSnapshot.open(sim, model: model, enumID: "campaign-status", value: "3300")
        },
        enumHoverScene("enums-cell-card", select: "db", literal: "20") { sim, model in
            SimDataSnapshot.landOnTable(sim, model: model, node: "db", table: "orders")
        },
        enumHoverScene("enums-sql-card", select: "orders", literal: "20") { sim, _ in
            SimOpsSnapshot.open(sim, node: "orders", op: "capture-payment", from: "orders")
        },
        enumPaletteScene("enums-palette-value", query: "20"),
        enumPaletteScene("enums-palette-label", query: "campaign status", manifest: campaignManifest()),
    ]
}

@MainActor private func enumScene(_ name: String, height: CGFloat, manifest: Manifest? = nil, selected: String? = nil,
                                  prepare: @escaping (Simulation, AppModel) -> Void = { _, _ in }) -> Scene {
    Scene(name: name, size: CGSize(width: 1400, height: height)) {
        let manifest = manifest ?? enumCheckout()
        let model = enumModel(manifest)
        let sim = Simulation(manifest: manifest)
        enumSettle(sim)
        model.sessions[AppModel.sessionKey(manifest.id, [])] = sim
        prepare(sim, model)
        return AnyView(SimScreen(model: model, id: manifest.id, path: [], snapshot: SimSnapshotOptions(selectedNode: selected)))
    }
}

/// The real window (hosted), with a value's card shown on the first anchor that holds `literal`.
@MainActor private func enumHoverScene(_ name: String, select node: String, literal: String,
                                       prepare: @escaping (Simulation, AppModel) -> Void) -> Scene {
    Scene(name: name, size: CGSize(width: 1400, height: 880), hosted: true) {
        let manifest = enumCheckout()
        let model = enumModel(manifest)
        model.open(.sim(manifest.id, path: []))
        model.sidebarVisible = false
        let sim = Simulation(manifest: manifest)
        enumSettle(sim)
        model.sessions[AppModel.sessionKey(manifest.id, [])] = sim
        SimOpsSnapshot.select(node, in: manifest.id, model: model)
        SimEnumSnapshot.previewCard(model, literal: literal)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            prepare(sim, model)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { SimEnumSnapshot.showPreview(model) }
        }
        return AnyView(RootView(model: model, fixtureEntries: model.library.entries, fixtureNotes: [:]))
    }
}

/// ⌘K on the sim, with a query typed.
@MainActor private func enumPaletteScene(_ name: String, query: String, manifest: Manifest? = nil) -> Scene {
    Scene(name: name, size: CGSize(width: 1400, height: 880), hosted: true) {
        let manifest = manifest ?? enumCheckout()
        let model = enumModel(manifest)
        model.open(.sim(manifest.id, path: []))
        let sim = Simulation(manifest: manifest)
        enumSettle(sim)
        model.sessions[AppModel.sessionKey(manifest.id, [])] = sim
        model.paletteOpen = true
        return AnyView(RootView(model: model, fixtureEntries: model.library.entries, fixtureNotes: [:], fixturePaletteQuery: query))
    }
}

@MainActor private func enumModel(_ manifest: Manifest) -> AppModel {
    AppModel(library: Library(manifests: [manifest]),
             vault: Vault(root: FileManager.default.temporaryDirectory.appendingPathComponent("strata-snap-vault")))
}

private var resourcesURL: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources")
}

/// `Resources/Examples/checkout.yaml`, parsed.
private func enumCheckout() -> Manifest {
    let url = resourcesURL.appendingPathComponent("Examples/checkout.yaml")
    guard let text = try? String(contentsOf: url, encoding: .utf8), let manifest = ManifestParser.parse(text, source: .file(url)).0 else {
        fatalError("checkout.yaml does not parse")
    }
    return manifest
}

/// The reference's campaign status (docs/manifest.md, Enums) on a small campaigns service.
private func campaignManifest() -> Manifest {
    let docs = (try? String(contentsOf: resourcesURL.appendingPathComponent("Docs/manifest.md"), encoding: .utf8)) ?? ""
    var fence: [String] = []
    var capturing = false
    for line in docs.components(separatedBy: "\n") {
        if line == "```yaml" { capturing = true; fence = []; continue }
        if line == "```", capturing {
            capturing = false
            if fence.first?.hasPrefix("enums:") == true { break }
            continue
        }
        if capturing { fence.append(line) }
    }
    let text = """
        strata: 1
        id: campaigns
        title: Campaigns
        kind: architecture
        nodes:
          - {id: web, kind: client, label: Console}
          - id: campaigns
            kind: service
            label: campaigns-svc
            ops:
              - {id: schedule, kind: sql, label: Schedule campaign, target: db, access: write, tables: [campaigns],
                 query: "UPDATE campaigns SET status = 3200, start_at = $2 WHERE id = $1 AND status = 3100"}
          - {id: scheduler, kind: worker, label: scheduler}
          - id: db
            kind: database
            label: Campaigns DB
            tech: Postgres
            schema:
              - table: campaigns
                columns: [{name: id, type: text, pk: true}, {name: name, type: text}, {name: status, type: int, enum: campaign-status}]
                rows: [[c_1, Winter sale, 3300], [c_2, Spring launch, 3200], [c_3, Old promo, 3900]]
        edges: [{from: web, to: campaigns}, {from: campaigns, to: db}, {from: scheduler, to: db}]
        flows: [{id: edits, from: web, rate: 2/s, steps: [{call: campaigns, steps: [{call: db}]}]}]

        """ + fence.joined(separator: "\n")
    guard let manifest = ManifestParser.parse(text, source: .file(URL(fileURLWithPath: "/snapshots/campaigns.yaml"))).0 else {
        fatalError("campaign manifest does not parse: \(ManifestParser.parse(text, source: .file(URL(fileURLWithPath: "/x"))).1)")
    }
    return manifest
}

@MainActor private func enumSettle(_ sim: Simulation) {
    sim.playing = true
    for _ in 0..<180 { sim.tick(1.0 / 60) }
    sim.playing = false
}
