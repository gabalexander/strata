import SwiftUI
import StrataCore
@_spi(Snapshots) import StrataUI

/// The Ask tab from canned Claude Code streams (StrataCore's AskFixtures), on the bundled checkout map:
/// empty with suggestions and the privacy notice, mid-answer, a finished answer with links and history,
/// a failure, the switch off, and where two links lead (an op's detail, a mechanism in a deep dive).
@MainActor func askScenes() -> [Scene] {
    let size = CGSize(width: 1400, height: 880)
    return [
        ask("ask-empty", size: size, noticeSeen: false) { _, _ in },
        ask("ask-empty-selected", size: size, selected: "db") { _, _ in },
        ask("ask-streaming", size: size) { model, manifest in
            SimAskSnapshot.replay(model, manifest: manifest.id, question: AskFixtures.question, lines: AskFixtures.streaming(),
                                  finished: false)
        },
        ask("ask-done", size: CGSize(width: 1400, height: 1120)) { model, manifest in
            SimAskSnapshot.history(model, manifest: manifest.id, [
                AskRecord(id: "h1", date: Date().addingTimeInterval(-3600 * 26), question: "Who writes orders.status?",
                          answer: "[orders-svc](strata:node/orders) inserts it as 10 in [INSERT order + outbox](strata:op/orders/insert-order)."),
                AskRecord(id: "h2", date: Date().addingTimeInterval(-600), question: "Why would an order stay in placed (10)?",
                          answer: "", status: .stopped),
            ])
            SimAskSnapshot.replay(model, manifest: manifest.id, question: AskFixtures.question, lines: AskFixtures.success(),
                                  finished: true)
            if let rendered = SimAskSnapshot.renderedAnswer(model, manifest: manifest) {
                let links = AskLinks.find(in: rendered)
                let resolved = links.filter { manifest.askTarget($0.url) != nil }.count
                print("ask-done: \(resolved) of \(links.count) links resolve; \(AskLinks.find(in: AskFixtures.answer).count - links.count) flattened to text")
            }
        },
        ask("ask-error", size: size) { model, manifest in
            SimAskSnapshot.fail(model, manifest: manifest.id, question: AskFixtures.question, failure: .notLoggedIn)
        },
        ask("ask-off", size: size, off: true) { _, _ in },
        live("ask-live-fake", size: size),
        follow("ask-follow-op", size: size, link: "strata:op/orders/insert-order"),
        follow("ask-follow-how", size: size, link: "strata:how/orders/relay/relay-cycle"),
    ]
}

@MainActor private func ask(_ name: String, size: CGSize, selected: String? = nil, noticeSeen: Bool = true, off: Bool = false,
                            prepare: @escaping @MainActor (AppModel, Manifest) -> Void) -> Scene {
    Scene(name: name, size: size, hosted: true) {
        guard let manifest = bundledCheckout() else { return AnyView(Text("missing checkout example")) }
        let model = askModel(manifest)
        SimAskSnapshot.reset(model, manifest: manifest.id, noticeSeen: noticeSeen)
        if off { SimAskSnapshot.turnOff(model, manifest: manifest.id) }
        prepare(model, manifest)
        let sim = Simulation(manifest: manifest)
        sim.playing = true
        for _ in 0..<180 { sim.tick(1.0 / 60) }
        sim.playing = false
        model.sessions[AppModel.sessionKey(manifest.id, [])] = sim
        let options = SimSnapshotOptions(selectedNode: selected, dockTab: .ask)
        return AnyView(SimScreen(model: model, id: manifest.id, path: [], snapshot: options))
    }
}

/// Asks through the app's real path with a stand-in `claude` that replays the canned stream: no network.
@MainActor private func live(_ name: String, size: CGSize) -> Scene {
    Scene(name: name, size: size, hosted: true) {
        guard let manifest = bundledCheckout() else { return AnyView(Text("missing checkout example")) }
        let model = askModel(manifest)
        SimAskSnapshot.reset(model, manifest: manifest.id)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("strata-ask-snap-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stream = dir.appendingPathComponent("stream.jsonl"), fake = dir.appendingPathComponent("claude")
        try? Data(AskFixtures.success().joined(separator: "\n").utf8).write(to: stream)
        try? Data("#!/bin/sh\ncat > /dev/null\nsleep 0.2\ncat '\(stream.path)'\n".utf8).write(to: fake)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        model.config.ask.claude = fake.path
        print("\(name): " + (SimAskSnapshot.ask(model, manifest: manifest, question: AskFixtures.question) ?? "no exchange"))
        try? FileManager.default.removeItem(at: dir)
        let sim = Simulation(manifest: manifest)
        model.sessions[AppModel.sessionKey(manifest.id, [])] = sim
        return AnyView(SimScreen(model: model, id: manifest.id, path: [], snapshot: SimSnapshotOptions(dockTab: .ask)))
    }
}

/// Clicks a link in a finished answer and renders where it leads.
@MainActor private func follow(_ name: String, size: CGSize, link: String) -> Scene {
    Scene(name: name, size: size, hosted: true) {
        guard let manifest = bundledCheckout() else { return AnyView(Text("missing checkout example")) }
        let model = askModel(manifest)
        SimAskSnapshot.reset(model, manifest: manifest.id)
        SimAskSnapshot.replay(model, manifest: manifest.id, question: AskFixtures.question, lines: AskFixtures.success(), finished: true)
        let root = Simulation(manifest: manifest)
        model.sessions[AppModel.sessionKey(manifest.id, [])] = root
        guard let landing = SimAskSnapshot.follow(model, from: root, link: link) else {
            print("\(name): \(link) didn't resolve")
            return AnyView(Text("unresolved"))
        }
        print("\(name): \(link) → level \(landing.path.isEmpty ? "root" : landing.path.joined(separator: "/"))"
              + (landing.node.map { ", node \($0) selected" } ?? ""))
        if let sim = model.sessions[AppModel.sessionKey(manifest.id, landing.path)] {
            sim.playing = false
        }
        let options = SimSnapshotOptions(selectedNode: landing.node, dockTab: .ask)
        return AnyView(SimScreen(model: model, id: manifest.id, path: landing.path, snapshot: options))
    }
}

@MainActor private func askModel(_ manifest: Manifest) -> AppModel {
    AppModel(library: Library(manifests: [manifest]),
             vault: Vault(root: FileManager.default.temporaryDirectory.appendingPathComponent("strata-snap-vault")))
}

private func bundledCheckout() -> Manifest? {
    guard let url = StrataResources.url("Examples/checkout.yaml"),
          let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    return ManifestParser.parse(text, source: .bundled(url)).0
}
