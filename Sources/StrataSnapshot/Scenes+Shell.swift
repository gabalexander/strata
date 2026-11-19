import SwiftUI
import StrataCore
@_spi(Snapshots) import StrataUI

@MainActor func shellScenes() -> [Scene] {
    [
        shellScene("shell-home"),
        shellScene("shell-sim", route: .sim("checkout", path: [])),
        shellScene("shell-note", route: .note("Checkout notes.md")),
        shellScene("shell-palette", route: .sim("checkout", path: []), query: "ch") { model in
            model.paletteOpen = true
        },
        shellScene("shell-switcher", query: "cache") { model in
            model.switcherOpen = true
        },
        shellScene("shell-context-menu") { model in
            model.overlays.showMenu([
                .header("Checkout platform"),
                MenuItem("Open", icon: "arrow.up.right", shortcut: "↩", checked: true) { model.open(.sim("checkout", path: [])) },
                MenuItem("Duplicate to edit", icon: "plus.square.on.square"),
                MenuItem("Reveal file", icon: "folder"),
                .separator,
                .submenu("Copy", icon: "document.on.document", [
                    MenuItem("ID", icon: "number"),
                    MenuItem("Open command", icon: "terminal"),
                ]),
                MenuItem("Move to Trash", icon: "trash", role: .destructive),
            ], at: CGPoint(x: 163, y: 239))
        },
        shellScene("shell-term-card", route: .sim("checkout", path: [])) { model in
            let terms = shellManifests()[0].terms
            model.overlays.showTerm(terms[0], anchor: CGRect(x: 753, y: 257, width: 42, height: 18),
                                    pinned: true, index: TermIndex(terms: terms))
        },
        shellScene("shell-graph", route: .graph),
        // The keyboard shortcut sheet, a hover hint on a toolbar button, and the first-open line on a map.
        shellScene("shell-shortcuts", route: .sim("checkout", path: [])) { model in
            model.shortcutSheetOpen = true
        },
        shellScene("shell-hint", route: .sim("checkout", path: [])) { model in
            model.overlays.hints.pinned = "Reset the simulation"
        },
        shellScene("shell-intro", route: .sim("checkout", path: [])) { model in
            model.onboarding = true
        },
        shellScene("shell-library-error", route: .sim("checkout", path: []), includingError: true) { model in
            var diagnostic = Term(id: "manifest-error/billing", term: "Manifest error",
                                  short: "Edge refers to an undeclared node: ledger.")
            diagnostic.detail = "billing.yaml · line 12 · edges[2].to"
            model.overlays.showTerm(diagnostic, anchor: CGRect(x: 220, y: 227, width: 8, height: 28))
        },
    ]
}

@MainActor
private func shellScene(_ name: String, route: Route = .home, query: String = "", includingError: Bool = false,
                        prepare: @escaping (AppModel) -> Void = { _ in }) -> Scene {
    let graphFixture = route == .graph ? ShellGraphFixture() : nil
    return Scene(name: name, size: CGSize(width: 1280, height: 820), hosted: true) {
        let library = Library(manifests: shellManifests())
        let vault = graphFixture?.vault ?? Vault(root: URL(fileURLWithPath: "/tmp/strata-snapshot-vault", isDirectory: true))
        let model = AppModel(library: library, vault: vault)
        model.open(route)
        prepare(model)
        let error = Library.Entry(id: "billing", title: "Billing service", kind: .architecture, category: "Platform",
                                  summary: nil, tags: [], url: URL(fileURLWithPath: "/fixtures/billing.yaml"), builtIn: false,
                                  diagnostics: [Diagnostic(.error, "Edge refers to an undeclared node: ledger.",
                                                           line: 12, path: "edges[2].to")], manifest: nil)
        let entries = includingError ? library.entries + [error] : library.entries
        return AnyView(RootView(model: model, fixtureEntries: entries, fixtureNotes: shellNotes, fixturePaletteQuery: query))
    }
}

@MainActor
private final class ShellGraphFixture {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("strata-graph-\(UUID().uuidString)")
    let vault: Vault

    init() {
        vault = Vault(root: root)
        for (path, text) in shellNotes { vault.write(path, text) }
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

private let shellNotes = [
    "Welcome.md": "Start with [[Checkout notes]] and [[How to map a project]].",
    "Checkout notes.md": "Trace a request through [[checkout]] and see [[Messaging/Delivery guarantees]].",
    "How to map a project.md": "Use [[checkout]] as a starting point. See also [[Welcome]].",
    "Messaging/Delivery guarantees.md": "Compare [[rabbitmq-prefetch]] and [[kafka-lag]].\n\n```strata\nsim: rabbitmq-prefetch\n```",
    "Patterns/Cache behavior.md": "See [[cache-stampede]] and [[Checkout notes#Caching]].",
]

private func shellManifests() -> [Manifest] {
    var checkout = Fixtures.checkout
    checkout.tags = ["postgres", "events"]
    checkout.terms[0].design = "Set a deadline on each call, and reuse a channel across requests to share connections."
    checkout.terms[0].related = ["channel", "deadline"]
    checkout.terms += [
        Term(id: "channel", term: "Channel", short: "A reusable connection manager for gRPC calls."),
        Term(id: "deadline", term: "Deadline", short: "The time by which an RPC must finish."),
    ]

    func lesson(_ id: String, _ title: String, _ category: String, _ summary: String, tags: [String]) -> Manifest {
        var manifest = Manifest(id: id, title: title, root: Level(),
                                source: .bundled(URL(fileURLWithPath: "/fixtures/\(id).yaml")))
        manifest.category = category
        manifest.summary = summary
        manifest.tags = tags
        return manifest
    }

    return [
        checkout,
        lesson("rabbitmq-prefetch", "RabbitMQ prefetch", "Messaging",
               "See how delivery windows trade throughput for fair dispatch.", tags: ["rabbitmq", "queues"]),
        lesson("kafka-lag", "Kafka consumer lag", "Messaging",
               "Follow consumer offsets as producers outrun a consumer group.", tags: ["kafka", "lag"]),
        lesson("http-pooling", "HTTP connection pooling", "Network",
               "Watch requests reuse sockets and queue when the pool fills.", tags: ["http", "connections"]),
        lesson("cache-stampede", "Cache stampede", "Patterns",
               "Expire a hot key and watch concurrent misses reach the database.", tags: ["redis", "caching"]),
        lesson("circuit-breaker", "Circuit breaker", "Patterns",
               "Trip the breaker under load and see a half-open probe recover it.", tags: ["resilience"]),
    ]
}
