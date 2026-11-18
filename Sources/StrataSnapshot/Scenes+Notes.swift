import SwiftUI
import StrataCore
import StrataUI

@MainActor func notesScenes() -> [Scene] {
    let fixture = NoteScenesFixture()
    return [
        Scene(name: "notes-editor", size: CGSize(width: 1060, height: 1120), hosted: true) {
            let model = fixture.model(.note(fixture.richNote))
            model.inspectorVisible = false
            return AnyView(NoteScreen(model: model, path: fixture.richNote))
        },
        Scene(name: "notes-reading", size: CGSize(width: 1060, height: 1170), hosted: true) {
            let model = fixture.model(.note(fixture.richNote))
            model.inspectorVisible = false
            return AnyView(NoteScreen(model: model, path: fixture.richNote, initiallyReading: true))
        },
        Scene(name: "notes-tree", size: CGSize(width: 248, height: 445), hosted: true) {
            let model = fixture.model(.note(fixture.nodeNote))
            return AnyView(VStack(spacing: 0) {
                NotesTree(model: model)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 13)
            .background(Theme.surface))
        },
        Scene(name: "notes-search", size: CGSize(width: 990, height: 815), hosted: true) {
            let model = fixture.model(.search("retry"))
            return AnyView(SearchScreen(model: model, query: "retry"))
        },
        Scene(name: "notes-inspector", size: CGSize(width: 1100, height: 780), hosted: true) {
            let model = fixture.model(.note(fixture.nodeNote))
            return AnyView(NoteScreen(model: model, path: fixture.nodeNote, initiallyReading: true))
        },
        Scene(name: "notes-unreadable", size: CGSize(width: 920, height: 590), hosted: true) {
            let path = fixture.blockedNote
            return AnyView(NoteScreen(model: fixture.model(.note(path)), path: path))
        },
        Scene(name: "notes-empty", size: CGSize(width: 920, height: 590), hosted: true) {
            let path = "System design/Failover notes.md"
            return AnyView(NoteScreen(model: fixture.model(.note(path)), path: path))
        }
    ]
}

@MainActor
private final class NoteScenesFixture {
    let richNote = "System design/Checkout failure notes.md"
    let nodeNote = "Sims/checkout/orders/tx.md"
    let blockedNote = "Unavailable.md"
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("strata-notes-scene-\(UUID().uuidString)")
    private let vault: Vault

    init() {
        vault = Vault(root: root)
        vault.seedIfEmpty()
        vault.write(richNote, Self.rich)
        vault.write(nodeNote, """
        # Orders transaction

        The checkout handler writes the order and its outbox row in one transaction. That gives the relay a durable event to publish once the commit succeeds.

        ## What to watch

        - Watch the pool when transaction latency increases.
        - Check whether a retry sends a duplicate order.
        - Compare the model in [[checkout|Checkout platform]].

        > Keep a note of the first metric that changes.

        ## Recovery

        Follow [[System design/Retry budget#Deadlines|the retry budget]] and replay one request.
        """)
        vault.write("System design/Retry budget.md", """
        # Retry budget

        ## Deadlines

        Reserve time for one retry inside the caller’s deadline.
        Use jitter so callers retry at different times.
        Record when the [[Sims/checkout/orders/tx|orders transaction]] commits.
        """)
        vault.write("System design/Experiments/Database slowdown.md", """
        # Database slowdown

        Measure the retry rate and pool utilization before restoring the database.
        The [[Sims/checkout/orders/tx|transaction note]] has the expected recovery steps.
        """)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func model(_ route: Route) -> AppModel {
        if route == .note(blockedNote) {
            try? FileManager.default.createDirectory(at: root.appendingPathComponent(blockedNote), withIntermediateDirectories: false)
        }
        let model = AppModel(library: Library(manifests: [Fixtures.checkout]), vault: vault)
        model.open(route)
        return model
    }

    private static let rich = """
    ---
    glossaries: [kafka, redis]
    ---
    # Checkout failure notes

    A **database slowdown** keeps order handlers busy. Use the [[System design/Checklist|design checklist]] and watch *where* requests start to wait.

    ## Before the experiment

    - [x] Record the idle connection count.
      - Sample the orders pool every second.
    - [ ] Compare the retry rate with the end-to-end deadline.

    > [!warning] Watch the write path
    > A retry can reach Postgres after the first transaction commits. Watch consumer lag as the relay catches up.

    ```sql
    SELECT state, count(*) FROM pg_stat_activity GROUP BY state;
    ```

    ## Replay in the simulator

    Open [[checkout|Checkout platform]] and watch the gRPC calls, or set `scenario: db-outage` here.

    ```strata
    sim: checkout
    height: 320
    ```

    ---

    | Signal | Look for |
    | --- | --- |
    | Pool usage | Slots stay busy after traffic drops |
    | Retry rate | More attempts per completed request |
    """
}
