import Foundation
import StrataCore

// The ops of the node a deep dive is inside (`InheritedOps`): which inner node each one maps to, and
// how a step inside names them with `op:` (docs/manifest.md, Operations, In a deep dive).

/// A synthetic map: `svc` keeps its ops on the overview, and its deep dive draws the stores, ports and
/// processes they touch. Each op exercises one mapping rule (see `deepDiveOpsChecks`).
private let fixture = """
    strata: 1
    id: dive
    title: Deep dive ops
    nodes:
      - { id: web, kind: client }
      - { id: pg, kind: database, label: Orders DB, tech: Postgres }
      - { id: wh, kind: database, label: Warehouse }
      - { id: kv, kind: store, label: Valkey, tech: ElastiCache }
      - { id: cache, kind: cache, label: Price cache }
      - { id: events, kind: topic, label: Order events }
      - { id: billing, kind: service, label: billing }
      - id: svc
        kind: service
        label: orders-svc
        ops:
          - { id: serve, kind: http, label: GET /orders, method: GET, path: /orders, code: cmd/api/server.go:40 }
          - { id: list, kind: sql, label: List orders, target: pg, query: "SELECT id FROM orders" }
          - { id: report, kind: sql, label: Sales report, target: wh, query: "SELECT count(*) FROM sales" }
          - { id: beat, kind: storage, label: Beat, target: kv, code: kv/roster.go:79 }
          - { id: take, kind: storage, label: Take lock, target: kv, code: [kv/lock.go:3, kv/client.go:9] }
          - { id: ping, kind: storage, label: Ping, target: kv }
          - { id: price, kind: cache, label: GET price, target: cache, command: GET, key: "price:{sku}" }
          - { id: charge, kind: rpc, label: Charge, target: billing, code: clients/billing.go:5 }
          - { id: emit, kind: publish, label: OrderPlaced, target: events, topic: order-events }
          - { id: score, kind: call, label: Score, code: domain/score.go:7 }
        inside:
          nodes:
            - { id: in, kind: port, label: from web }
            - { id: api, kind: service, label: API, code: cmd/api/server.go:12 }
            - { id: charger, kind: worker, label: charger, code: clients/billing.go:1 }
            - { id: db, kind: database, label: orders tables }
            - { id: whp, kind: port, label: Warehouse }
            - { id: roster, kind: store, label: roster, tech: Valkey, code: kv/roster.go:20 }
            - id: lock
              kind: cache
              label: lock
              tech: Valkey
              code: kv/lock.go:3
              ops: [{ id: take, kind: cache, label: SET NX, command: SET NX }]
            - { id: cache, kind: cache, label: prices }
            - { id: pay, kind: port, label: billing API }
            - { id: bus, kind: topic, label: order-events }
            - { id: memo, kind: note, label: Orders DB }
          edges:
            - { from: in, to: api }
            - { from: api, to: db }
            - { from: api, to: cache }
            - { from: api, to: roster }
            - { from: api, to: charger }
            - { from: charger, to: pay }
          flows:
            - id: requests
              from: in
              rate: 20/s
              steps:
                - call: api
                  op: serve
                  steps:
                    - { call: db, op: list }
                    - { call: cache, op: svc/price }
                    - { call: roster, op: ../beat }
    edges:
      - { from: web, to: svc }
      - { from: svc, to: pg }
      - { from: svc, to: wh }
      - { from: svc, to: kv }
      - { from: svc, to: cache }
      - { from: svc, to: billing }
      - { from: svc, to: events }
    """

private func parse(_ text: String) -> (Manifest?, [Diagnostic]) {
    ManifestParser.parse(text, source: .file(URL(fileURLWithPath: "/checks/dive.yaml")))
}

@MainActor func deepDiveOpsChecks() -> [CheckCase] {
    [
        CheckCase(name: "deep dive ops map each owner op to the inner node it talks to") {
            let (manifest, diagnostics) = parse(fixture)
            check(manifest != nil && diagnostics.isEmpty, "fixture should be clean: \(diagnostics)")
            guard let inherited = manifest?.inheritedOps(at: ["svc"]) else { check(false, "no inherited ops at svc"); return }
            check(inherited.owner.id == "svc" && inherited.ownerLevel.node("pg") != nil, "owner or its level")
            check(inherited.entries.map(\.op.id) == ["serve", "list", "report", "beat", "take", "ping", "price", "charge", "emit", "score"],
                  "one entry per owner op, in order: \(inherited.entries.map(\.op.id))")
            let expected: [(String, String?, InheritedOps.Rule?)] = [
                ("serve", "api", .code),       // served: an inner process whose code file is the op's
                ("list", "db", .kind),         // the only database named like the target (Orders DB); two targets, so a name is needed
                ("report", "whp", .label),     // the port labelled like the target wins over the only database
                ("beat", "roster", .code),     // same file, another line
                ("take", "lock", .code),       // first code entry, exact
                ("ping", nil, nil),            // two Valkey nodes and no code: ambiguous
                ("price", "cache", .target),   // the target is an inner id
                ("charge", "pay", .kind),      // the port named like the target
                ("emit", "bus", .kind),        // the buffer its topic names
                ("score", nil, nil),           // pure compute: no target, no code here
            ]
            for (op, peer, rule) in expected {
                let entry = inherited.entry(op)
                check(entry?.peer == peer && entry?.rule == rule,
                      "\(op) → \(entry?.peer ?? "nil") by \(entry?.rule?.rawValue ?? "nil"), expected \(peer ?? "nil") by \(rule?.rawValue ?? "nil")")
            }
            check(inherited.entry("charge")?.performer == "charger", "charge is performed by charger (its code file)")
            check(inherited.entry("serve")?.performer == nil, "an inbound op has no performer")
            check(inherited.ops(mappedTo: "roster").map(\.op.id) == ["beat"] && inherited.peer(of: "list") == "db", "lookups")
            check(inherited.counts == ["api": 1, "db": 1, "whp": 1, "roster": 1, "lock": 1, "cache": 1, "pay": 1, "bus": 1],
                  "counts: \(inherited.counts)")
        },
        CheckCase(name: "deep dive ops only below a node's inside") {
            guard let manifest = parse(fixture).0 else { check(false, "fixture"); return }
            check(manifest.deepDiveOwner(at: []) == nil && manifest.inheritedOps(at: []) == nil, "the root has no owner")
            check(manifest.deepDiveOwner(at: ["svc"])?.node.id == "svc", "svc owns its deep dive")
            check(manifest.deepDiveOwner(at: ["nowhere"]) == nil && manifest.deepDiveOwner(at: ["svc#list"]) == nil,
                  "unknown nodes and op levels have no owner")
            let checkout = Fixtures.checkoutWithOps
            check(checkout.inheritedOps(at: ["orders#insert-order"]) == nil, "an op's own level inherits nothing")
            check(InheritedOps.codeFile("a/b.go:12") == "a/b.go" && InheritedOps.codeFile("./a/b.go:3-9") == "a/b.go" &&
                  InheritedOps.codeFile("a/b.go#L4") == "a/b.go" && InheritedOps.codeFile("domain/orders") == "domain/orders",
                  "code files drop lines")
        },
        CheckCase(name: "deep dive ops map the bundled checkout's orders-svc") {
            let library = Library(builtIn: try requiredResource("Examples"), dirs: [])
            guard let inherited = library.manifest("checkout")?.inheritedOps(at: ["orders"]) else { check(false, "no checkout"); return }
            let peers = Dictionary(uniqueKeysWithValues: inherited.entries.map { ($0.op.id, $0.peer ?? "-") })
            check(peers["place-order"] == "handler" && peers["get-order"] == "handler", "endpoints are served by the handler: \(peers)")
            check(["load-order", "read-price", "insert-order", "capture-payment"].allSatisfy { peers[$0] == "tx" },
                  "queries go to the one database: \(peers)")
            check(peers["get-price"] == "-" && peers["order-placed"] == "-" && peers["payment-webhook"] == "-",
                  "nothing inside stands for the cache, topic or webhook: \(peers)")
        },
        CheckCase(name: "deep dive op references resolve on the owner") {
            guard let manifest = parse(fixture).0, let level = manifest.level(at: ["svc"]),
                  let owner = manifest.root.node("svc") else { check(false, "fixture"); return }
            let key = InheritedOps.ownerKey
            check(level.resolveOp("list", caller: "api", target: "db", owner: owner).map { "\($0.node)/\($0.op.id)" } == "\(key)/list",
                  "a plain id falls back to the owner")
            check(level.resolveOp("svc/price", caller: nil, target: nil, owner: owner)?.node == key, "owner-id/op")
            check(level.resolveOp("../beat", caller: nil, target: nil, owner: owner)?.op.id == "beat", "../op")
            check(level.resolveOp("take", caller: "api", target: "lock", owner: owner)?.node == "lock", "an inner op wins over the owner's")
            check(level.resolveOp("list", caller: "api", target: "db") == nil && level.resolveOp("list", caller: "api", target: "db", owner: nil) == nil,
                  "no owner, no fallback")
            check(level.resolveOp("missing", caller: "api", target: "db", owner: owner) == nil &&
                  level.resolveOp("svc/missing", caller: nil, target: nil, owner: owner) == nil, "unknown owner ops")
            var shadowed = Level()
            shadowed.nodes = [Node(id: "svc", kind: .service)]
            check(shadowed.resolveOp("svc/list", caller: nil, target: nil, owner: owner) == nil &&
                  shadowed.resolveOp("../list", caller: nil, target: nil, owner: owner) != nil,
                  "an inner node with the owner's id keeps svc/op; ../op still names the owner")
            let references = level.opReferences(owner: owner)
            check(references["\(key)/serve"] == ["requests"] && references["\(key)/list"] == ["requests"] &&
                  references["\(key)/price"] == ["requests"] && references["\(key)/beat"] == ["requests"],
                  "opReferences keys inherited ops as ../op: \(references)")
            check(level.opReferences()["\(key)/list"] == nil, "without an owner they don't resolve")
        },
        CheckCase(name: "deep dive op references validate") {
            let unknown = fixture.replacingOccurrences(of: "{ call: db, op: list }", with: "{ call: db, op: lst }")
            let (_, diagnostics) = parse(unknown)
            check(diagnostics.contains { $0.severity == .error && $0.message.contains("unknown op 'lst' on 'api' or 'db' or 'svc', the node this level is inside") &&
                                         $0.message.contains("did you mean 'list'") },
                  "unknown op names the owner: \(diagnostics)")
            let explicit = fixture.replacingOccurrences(of: "op: ../beat", with: "op: ../bet")
            check(parse(explicit).1.contains { $0.message.contains("unknown op 'bet' on 'svc', the node this level is inside; did you mean 'beat'?") },
                  "unknown ../op: \(parse(explicit).1)")
            let flowOp = fixture.replacingOccurrences(of: "rate: 20/s\n", with: "rate: 20/s\n          op: serve\n")
            check(parse(flowOp).1.isEmpty, "a flow op names an owner op: \(parse(flowOp).1)")
            // The root level has no owner: an id neither the caller nor the target has stays unknown.
            let root = fixture.replacingOccurrences(of: "  - { from: svc, to: events }", with: """
                  - { from: svc, to: events }
                flows:
                  - { id: f, from: web, steps: [{ call: svc, op: lst }] }
                """)
            check(parse(root).1.contains { $0.message.contains("unknown op 'lst' on 'web' or 'svc'; did you mean 'list'?") },
                  "root op references: \(parse(root).1)")
        },
        CheckCase(name: "deep dive engine counts inherited ops on ..") {
            guard let manifest = parse(fixture).0 else { check(false, "fixture"); return }
            let sim = Simulation(manifest: manifest, path: ["svc"])
            sim.run(seconds: 3)
            let key = InheritedOps.ownerKey
            let list = sim.opMetrics(node: key, op: "list")
            check(list.referenced && list.rate > 5 && list.total > 20, "a step naming an owner op counts it: \(list)")
            check(sim.opMetrics(node: key, op: "serve").referenced && sim.opMetrics(node: key, op: "beat").referenced,
                  "every named owner op counts")
            check(!sim.opMetrics(node: key, op: "report").referenced, "an owner op no step names has no numbers")
            check(!sim.opMetrics(node: "lock", op: "take").referenced, "the inner op of the same id is another op")
            check(!sim.opSeries(node: key, op: "list", metric: "rate").isEmpty, "series for inherited ops")
            let root = Simulation(manifest: manifest)
            root.run(seconds: 1)
            check(!root.opMetrics(node: key, op: "list").referenced, "the root has no owner")
        },
    ]
}
