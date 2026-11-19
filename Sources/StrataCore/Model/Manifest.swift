import Foundation

// The decoded form of a manifest (docs/manifest.md). Plain values: the parser builds them, the
// engine and the UI read them. Durations and times are seconds (Double) throughout.
// CONTRACT FILE: owned by the lead. Add fields only additively and say so in your report.

public enum ManifestKind: String, Sendable, Codable, CaseIterable { case sim, architecture }

public enum ManifestSource: Sendable, Hashable {
    case bundled(URL)            // shipped in the app (read-only)
    case file(URL)               // ~/.strata/sims or another configured dir
    case inline(note: String, index: Int)   // a ```strata block in a vault note
}

public struct Manifest: Sendable, Identifiable {
    public var id: String
    public var title: String
    public var kind: ManifestKind = .sim
    public var category: String?
    public var summary: String?
    public var tags: [String] = []
    public var repo: String?            // tilde-expanded absolute path
    public var glossaries: [String] = []
    public var terms: [Term] = []
    public var notes: String?
    public var links: [Link] = []
    /// Value dictionaries such as status codes (docs/manifest.md, Enums). Shared by every level.
    public var enums: [EnumDef] = []
    /// `auto` (default): the layout engine places every node; `at` positions are only hints.
    public var layout: LayoutMode = .auto
    public var root: Level
    public var source: ManifestSource

    public init(id: String, title: String, root: Level, source: ManifestSource) {
        self.id = id; self.title = title; self.root = root; self.source = source
    }

    /// The level reached by following `path` (node ids) through `inside:` levels. nil if the path
    /// leaves this manifest (a node with `detail:` instead of `inside:`) or doesn't exist.
    /// An element `node#op` enters the `inside:` level of that node's operation.
    public func level(at path: [String]) -> Level? {
        var level = root
        for id in path {
            if let hash = id.firstIndex(of: "#") {
                let nodeID = String(id[..<hash]), opID = String(id[id.index(after: hash)...])
                guard let node = level.nodes.first(where: { $0.id == nodeID }),
                      let inner = node.ops.first(where: { $0.id == opID })?.inside else { return nil }
                level = inner
                continue
            }
            guard let node = level.nodes.first(where: { $0.id == id }), let inner = node.inside else { return nil }
            level = inner
        }
        return level
    }
}

/// One diagram: the root of a manifest or the inside of a node.
public struct Level: Sendable {
    public var nodes: [Node] = []
    public var edges: [Edge] = []
    public var groups: [Group] = []
    public var flows: [Flow] = []
    public var controls: [Control] = []
    public var scenarios: [Scenario] = []
    public var narration: String?
    /// Which way auto layout runs this level (docs/manifest.md, Layout). Parsing fills it in: a level
    /// without `direction:` takes its enclosing level's, and the root defaults to `right`.
    public var direction: FlowDirection?
    public init() {}

    public func node(_ id: String) -> Node? { nodes.first { $0.id == id } }
    public func flow(_ id: String) -> Flow? { flows.first { $0.id == id } }
}

public struct GridPoint: Sendable, Hashable { public var x: Double; public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y } }

public enum NodeRole: Sendable { case source, server, buffer, annotation }

public enum NodeKind: String, Sendable, CaseIterable, Codable {
    case client, user, cron
    case gateway, service, worker, function, database, cache, search, store, external, cdn, dns, llm, vector, port
    case queue, topic
    case note

    public var role: NodeRole {
        switch self {
        case .client, .user, .cron: .source
        case .queue, .topic: .buffer
        case .note: .annotation
        default: .server   // .port is also usable as a source (flows may start `from:` a port)
        }
    }

    /// SF Symbol drawn on the node.
    public var symbol: String {
        switch self {
        case .client: "macbook.and.iphone"
        case .user: "person.fill"
        case .cron: "clock.arrow.circlepath"
        case .gateway: "arrow.triangle.branch"
        case .service: "shippingbox.fill"
        case .worker: "gearshape.2.fill"
        case .function: "function"
        case .database: "cylinder.split.1x2.fill"
        case .cache: "bolt.fill"
        case .search: "magnifyingglass"
        case .store: "archivebox.fill"
        case .external: "cloud.fill"
        case .cdn: "globe"
        case .dns: "signpost.right.fill"
        case .llm: "brain"
        case .vector: "circle.hexagongrid.fill"
        case .port: "arrow.right.to.line"
        case .queue: "tray.full.fill"
        case .topic: "dot.radiowaves.left.and.right"
        case .note: "note.text"
        }
    }

    /// Alias spellings accepted in `kind:` (lowercased) → (kind, tech badge to use when `tech` is unset).
    public static let aliases: [String: NodeKind] = [
        "browser": .client, "mobile": .client, "app": .client, "person": .user,
        "scheduler": .cron, "job": .cron,
        "lb": .gateway, "proxy": .gateway, "ingress": .gateway, "loadbalancer": .gateway, "nginx": .gateway, "envoy": .gateway,
        "api": .service, "server": .service, "microservice": .service,
        "consumer": .worker, "lambda": .function, "serverless": .function,
        "db": .database, "postgres": .database, "mysql": .database, "sql": .database,
        "redis": .cache, "memcached": .cache, "elasticsearch": .search, "opensearch": .search,
        "s3": .store, "blob": .store, "bucket": .store, "gcs": .store,
        "thirdparty": .external, "saas": .external, "partner": .external, "edge": .cdn, "resolver": .dns,
        "model": .llm, "inference": .llm, "vectordb": .vector, "embeddings": .vector,
        "in": .port, "out": .port, "boundary": .port,
        "rabbitmq": .queue, "sqs": .queue, "amqp": .queue,
        "kafka": .topic, "pubsub": .topic, "sns": .topic, "stream": .topic, "kinesis": .topic,
        "sticky": .note,
    ]
}

public enum AckMode: String, Sendable, CaseIterable { case manual, auto }
public enum Overflow: String, Sendable, CaseIterable { case reject, dropOldest = "drop-oldest" }
public enum OnError: String, Sendable, CaseIterable { case requeue, dlq, drop, retry, skip }

/// A random duration. `sample` lives in the engine.
public enum Dist: Sendable, Hashable {
    case jitter(Double)                 // "20ms": mean ±25% uniform
    case fixed(Double)                  // "fixed 20ms"
    case uniform(Double, Double)        // "10ms..40ms"
    case exponential(Double)            // "exp 20ms" (mean)
    case lognormal(p50: Double, p99: Double)   // "p50 20ms p99 400ms"

    public var mean: Double {
        switch self {
        case .jitter(let m), .fixed(let m), .exponential(let m): m
        case .uniform(let a, let b): (a + b) / 2
        case .lognormal(let p50, let p99):
            // sigma from p99/p50 = exp(2.326 sigma); mean = p50 * exp(sigma^2 / 2)
            { let s = log(max(p99 / max(p50, 1e-9), 1)) / 2.326; return p50 * exp(s * s / 2) }()
        }
    }
}

public enum Rate: Sendable, Hashable {
    case perSecond(Double)   // Poisson
    case every(Double)       // evenly spaced, seconds
    case manual
    case parent              // follow the measured rate of the node this level is inside

    public var perSecondValue: Double? {
        switch self {
        case .perSecond(let r): r
        case .every(let s): s > 0 ? 1 / s : 0
        case .manual: 0
        case .parent: nil
        }
    }
}

/// Every behaviour parameter is optional: nil means "kind default" (see NodeDefaults).
public struct NodeParams: Sendable, Hashable {
    public var latency: Dist?
    public var concurrency: Int?
    public var replicas: Int?
    public var queue: Int?
    public var errors: Double?
    public var timeout: Double?
    public var retries: Int?
    public var backoff: Double?
    public var async: Bool?
    public var capacity: Int?
    public var overflow: Overflow?
    public var ttl: Double?
    public var dlq: String?
    public var prefetch: Int?
    public var ack: AckMode?
    public var onError: OnError?
    public var maxDeliveries: Int?
    public var hitRate: Double?
    public init() {}
}

public struct Node: Sendable, Identifiable {
    public var id: String
    public var kind: NodeKind
    public var label: String
    public var tech: String?
    public var icon: String?
    public var at: GridPoint?
    /// The `at` the manifest wrote, kept when auto layout replaces `at`, so the level can be laid out again
    /// (in another direction) from the author's hints.
    public var hint: GridPoint?
    public var group: String?
    public var doc: String?
    public var term: String?
    public var code: [String] = []
    /// The executable this node runs as, such as `cmd/worker` in a Go repo with several binaries.
    public var binary: String?
    public var links: [Link] = []
    public var params = NodeParams()
    public var inside: Level?
    public var detail: String?
    public var actions: [Action] = []
    /// What this node does, operation by operation: the queries it runs, endpoints it serves,
    /// messages it publishes or consumes, keys it reads (docs/manifest.md, Operations).
    public var ops: [Operation] = []
    /// Databases and stores: tables with columns, foreign keys, sample rows and volumes (docs/manifest.md, Data).
    public var schema: [TableSchema] = []
    /// Services: the domain objects they load and save, assembled from tables (docs/manifest.md, Data).
    public var entities: [Entity] = []
    /// Step-by-step explanations of mechanisms this node implements (docs/manifest.md, How it works).
    public var how: [Mechanism] = []
    /// A formula this node computes, shown on hover (docs/manifest.md, Formulas).
    public var formula: Formula?
    public var line: Int?               // source line, for diagnostics

    public init(id: String, kind: NodeKind, label: String? = nil) {
        self.id = id; self.kind = kind; self.label = label ?? id
    }

    public var canDeepDive: Bool { inside != nil || detail != nil }
}

public struct Edge: Sendable, Identifiable, Hashable {
    public var from: String
    public var to: String
    public var label: String?
    public var `protocol`: String?
    public var latency: Dist?
    public var loss: Double?
    public var implicit = false          // created by the loader for a flow hop with no declared edge
    public var line: Int?
    /// Set by auto layout for an edge spanning several columns: where it passes each column in
    /// between (grid units, centre of the track), in from → to order. The stage routes along it.
    public var via: [GridPoint] = []
    public var id: String { "\(from)->\(to)" }
    public init(from: String, to: String) { self.from = from; self.to = to }
}

public enum GroupKind: String, Sendable, CaseIterable { case cluster, vpc, region, zone, team, boundary }

public struct Group: Sendable, Identifiable {
    public var id: String
    public var label: String
    public var kind: GroupKind = .boundary
    public var parent: String?
    public init(id: String, label: String? = nil) { self.id = id; self.label = label ?? id }
}

public struct Flow: Sendable, Identifiable {
    public var id: String
    public var label: String
    public var color: Int?               // 1...6
    public var from: String?             // source flows
    public var on: String?               // consumer flows: buffer id
    public var by: String?               // consumer flows: consumer node id
    public var rate: Rate = .manual      // source flows only
    public var deadline: Double?
    public var steps: [Step] = []
    /// The op each run of this flow performs, counted when the run finishes (a consumer flow's
    /// consume op on its `by` node, or an op on its `from` node); an op id on that node, or "node/op".
    public var op: String?
    /// Real-world numbers for this traffic, compared against the simulation in the Pressure tab.
    public var traffic: FlowTraffic?
    public var slo: SLO?
    public var line: Int?
    public init(id: String, label: String? = nil) { self.id = id; self.label = label ?? id }

    public var isConsumer: Bool { on != nil }
}

public struct Breaker: Sendable, Hashable {
    public var failures: Int
    public var cooldown: Double
    public init(failures: Int, cooldown: Double) { self.failures = failures; self.cooldown = cooldown }
}

public indirect enum StepAction: Sendable {
    case call(target: String, steps: [Step], miss: [Step])
    case publish(target: String)
    case work(Dist)
    case parallel([Step])
}

public struct Step: Sendable {
    public var action: StepAction
    public var label: String?
    public var say: String?
    public var p: Double?
    public var optional = false
    public var timeout: Double?
    public var retries: Int?
    public var backoff: Double?
    public var breaker: Breaker?
    /// The operation this step performs: an op id on the calling node, then on the target, or "node/op".
    public var op: String?
    public var line: Int?
    public init(_ action: StepAction) { self.action = action }
}

// MARK: - Operations

public enum OpKind: String, Sendable, CaseIterable {
    case sql, cache, publish, consume, rpc, http, search, storage, llm, call

    /// SF Symbol for rows and badges.
    public var symbol: String {
        switch self {
        case .sql: "tablecells"
        case .cache: "bolt.horizontal"
        case .publish: "paperplane"
        case .consume: "tray.and.arrow.down"
        case .rpc: "point.3.connected.trianglepath.dotted"
        case .http: "globe"
        case .search: "magnifyingglass"
        case .storage: "externaldrive"
        case .llm: "brain"
        case .call: "arrow.right.circle"
        }
    }
}

public enum OpAccess: String, Sendable, CaseIterable { case read, write, readWrite = "read-write" }

/// Inbound: something the node serves (an endpoint, an RPC method, a consumer).
/// Outbound: something it calls on `target`.
public enum OpDirection: String, Sendable { case inbound = "in", outbound = "out" }

/// One thing a node does. Every field except `id`, `kind` and `label` is optional; kinds use the
/// fields that make sense for them (docs/manifest.md, Operations).
public struct Operation: Sendable, Identifiable {
    public var id: String
    public var kind: OpKind
    public var label: String
    public var direction: OpDirection
    public var target: String?          // node id (outbound)
    public var access: OpAccess?
    public var doc: String?
    public var code: [String] = []
    public var risks: [String] = []
    public var tags: [String] = []
    // sql / search
    public var query: String?
    public var tables: [String] = []
    public var indexes: [String] = []
    public var tx: Bool?
    public var locks: String?
    // cache
    public var command: String?         // "GET", "SET EX 300", "HINCRBY", "EVAL"
    public var key: String?             // key pattern, routing key or partition key
    public var ttl: Double?
    // publish / consume
    public var topic: String?           // topic, exchange or queue name
    public var group: String?           // consumer group / queue
    public var payload: String?         // example message or schema
    // rpc / http
    public var method: String?          // "POST", or "orders.v1.Orders/Create"
    public var path: String?            // "/orders/{id}"
    public var request: String?
    public var response: String?
    public var streaming: String?       // unary | server | client | bidi
    public var status: [String] = []    // "201", "409 duplicate", ...
    public var calls: String?           // "node/op": the inbound op this outbound call reaches
    // free-form facts shown as a table (timeout, auth, idempotency, ...)
    public var facts: [(key: String, value: String)] = []
    // deeper
    public var how: [Mechanism] = []
    public var formula: Formula?
    public var inside: Level?
    public var detail: String?
    public var line: Int?

    public init(id: String, kind: OpKind, label: String? = nil, direction: OpDirection = .outbound) {
        self.id = id; self.kind = kind; self.label = label ?? id; self.direction = direction
    }
}


/// A scalar value for parameters and controls.
public enum Value: Sendable, Hashable, CustomStringConvertible {
    case number(Double)
    case string(String)
    case bool(Bool)
    public var description: String {
        switch self {
        case .number(let d): d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
        case .string(let s): s
        case .bool(let b): b ? "true" : "false"
        }
    }
    public var number: Double? { if case .number(let d) = self { d } else { nil } }
}

/// What a control or `set` command targets.
public enum BindTarget: Sendable, Hashable {
    case node(String)
    case flow(String)
    case edge(from: String, to: String)
}

public struct Binding: Sendable, Hashable, CustomStringConvertible {
    public var target: BindTarget
    public var param: String
    public init(_ target: BindTarget, _ param: String) { self.target = target; self.param = param }
    public var description: String {
        switch target {
        case .node(let n), .flow(let n): "\(n).\(param)"
        case .edge(let a, let b): "\(a)->\(b).\(param)"
        }
    }
}

public enum ControlInput: Sendable, Hashable {
    case range(min: Double, max: Double, step: Double)
    case options([Value])
    case toggle
}

public enum Condition: Sendable, Hashable {
    case lt(Double), le(Double), gt(Double), ge(Double)
    case eq(Value)
    case between(Double, Double)
    case always
}

public struct EffectSpec: Sendable, Hashable {
    public enum Dir: String, Sendable { case up, down, flat }
    public var metric: String
    public var dir: Dir
    public var good: Bool?
    public init(metric: String, dir: Dir, good: Bool? = nil) { self.metric = metric; self.dir = dir; self.good = good }
}

public struct InsightRule: Sendable, Hashable {
    public var when: Condition = .always
    public var text: String
    public var effects: [EffectSpec] = []
    public init(text: String) { self.text = text }
}

public struct Control: Sendable, Identifiable {
    public var id: String
    public var label: String
    public var bind: Binding
    public var input: ControlInput
    public var unit: String?
    public var hint: String?
    public var term: String?
    public var insights: [InsightRule] = []
    public var line: Int?
    public init(id: String, label: String, bind: Binding, input: ControlInput) {
        self.id = id; self.label = label; self.bind = bind; self.input = input
    }
}

/// A parsed command line (docs/manifest.md#commands).
public enum Command: Sendable, Hashable {
    case kill(String), restore(String)
    case slow(String, Double)
    case fail(String, Double)
    case scale(String, Int, relative: Bool)
    case set(Binding, Value)
    case rate(String, Rate)
    case send(String, Int)
    case cut(String, String), heal(String, String)
    case delay(String, String, Double)
    case redirect(String, String), unredirect(String)
    case purge(String)
    case say(String)
    case pause
}

public struct Action: Sendable, Identifiable {
    public var id: String
    public var label: String
    public var icon: String?
    public var commands: [Command]
    public init(id: String, label: String, commands: [Command]) { self.id = id; self.label = label; self.commands = commands }
}

public struct ScenarioStep: Sendable {
    public var at: Double
    public var commands: [Command] = []
    public var say: String?
    public init(at: Double) { self.at = at }
}

public struct Scenario: Sendable, Identifiable {
    public var id: String
    public var label: String
    public var goal: String?
    public var setup: [Command] = []
    public var steps: [ScenarioStep] = []
    public var watch: [String] = []
    public init(id: String, label: String) { self.id = id; self.label = label }
}

public struct Term: Sendable, Identifiable, Hashable, Codable {
    public var id: String
    public var term: String
    public var short: String
    public var detail: String?
    public var design: String?
    public var match: [String]?
    public var related: [String]?
    public init(id: String, term: String, short: String) { self.id = id; self.term = term; self.short = short }
}

public struct Link: Sendable, Hashable {
    public enum Target: Sendable, Hashable { case url(String), note(String), sim(String) }
    public var label: String
    public var target: Target
    public init(label: String, target: Target) { self.label = label; self.target = target }
}

/// A loader/validator finding. `line` is 1-based in the source file.
public struct Diagnostic: Error, Sendable, Hashable, CustomStringConvertible {
    public enum Severity: String, Sendable { case error, warning }
    public var severity: Severity
    public var message: String
    public var line: Int?
    public var path: String?             // e.g. "nodes[2].latency" or "flows.place-order.steps[0]"
    public init(_ severity: Severity, _ message: String, line: Int? = nil, path: String? = nil) {
        self.severity = severity; self.message = message; self.line = line; self.path = path
    }
    public var description: String {
        var s = severity.rawValue
        if let line { s += " (line \(line))" }
        if let path { s += " \(path)" }
        return s + ": " + message
    }
}


// MARK: - Data (schemas, sample rows, entities)

public struct Column: Sendable, Hashable {
    public var name: String
    public var type: String?
    public var pk = false
    public var ref: String?              // "table.column" (same database node), or "node.table.column"
    public var nullable: Bool?
    public var unique = false
    public var note: String?
    /// Id of an `enums:` entry whose values this column holds (YAML key `enum`).
    public var enumRef: String?
    public init(name: String) { self.name = name }
}

/// A count with an optional per-day growth, e.g. `rows: 12M`, `growth: 40k/day`.
public struct TableVolume: Sendable, Hashable {
    public var rows: Double?
    public var growthPerDay: Double?
    public init() {}
}

public struct TableSchema: Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var doc: String?
    public var columns: [Column] = []
    public var indexes: [String] = []
    /// Sample rows in column order; nil is SQL NULL. Synthetic, never copied from production.
    public var rows: [[String?]] = []
    public var volume: TableVolume?
    public var owner: String?            // node id that writes it (inferred from ops when nil)
    public var line: Int?
    public init(name: String) { self.name = name }
}

public struct Entity: Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var source: String?           // database node id (default: the one database this node has ops on)
    public var root: String              // root table
    public var includes: [String] = []   // tables joined to the root through ref columns
    public var doc: String?
    public var code: [String] = []
    public var line: Int?
    public init(name: String, root: String) { self.name = name; self.root = root }
}

// MARK: - Traffic and SLOs

public struct FlowTraffic: Sendable, Hashable {
    public var peak: Double?             // requests per second at peak
    public var daily: Double?            // requests per day
    public init() {}
}

public struct SLO: Sendable, Hashable {
    public var p50: Double?              // seconds
    public var p99: Double?              // seconds
    public var errors: Double?           // max error ratio, 0...1
    public init() {}
}


// MARK: - Layout

public enum LayoutMode: String, Sendable, CaseIterable { case auto, manual }

/// Which way flow runs: `right` puts layers in columns from left to right, `down` puts them in rows
/// from top to bottom.
public enum FlowDirection: String, Sendable, CaseIterable, Codable { case right, down }

// MARK: - How it works (mechanisms as playable sequences)

/// One actor in a mechanism: an instance, a store, a client. `node` links it to a node of the level.
public struct Participant: Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var node: String?
    public var kind: NodeKind?
    public init(id: String, label: String? = nil) { self.id = id; self.label = label ?? id }
}

/// A key (or any named piece of state) shown in the state panel while the sequence plays.
public struct StateEntry: Sendable, Hashable {
    public var key: String
    public var value: String?            // nil = absent/deleted
    public var ttl: Double?              // seconds left when the step completes
    public init(key: String, value: String?, ttl: Double? = nil) { self.key = key; self.value = value; self.ttl = ttl }
}

/// One message in the sequence: `from` sends `label` (and optionally an exact `command`) to `to`.
public struct MechStep: Sendable, Identifiable {
    public var id: String                // stable within the mechanism ("s1", or given)
    public var from: String
    public var to: String
    public var label: String
    public var command: String?          // exact command / query / call, e.g. "SET roster:42 inst-a NX PX 15000"
    public var reply: String?            // e.g. "OK", "(nil)", "1"
    public var note: String?             // markdown, shown beside the step
    public var at: Double?               // seconds since the start (for timelines like heartbeats)
    public var state: [StateEntry] = []  // state changes this step causes
    public var code: [String] = []       // where the code takes this step, e.g. "internal/lock.go:88"
    public var line: Int?
    public init(id: String, from: String, to: String, label: String) { self.id = id; self.from = from; self.to = to; self.label = label }
}

/// An alternative path (failure case, race) that branches after a step of the main sequence.
public struct MechBranch: Sendable, Identifiable {
    public var id: String
    public var label: String
    public var after: String?            // step id it branches from (nil = from the start)
    public var note: String?
    public var steps: [MechStep] = []
    public init(id: String, label: String) { self.id = id; self.label = label }
}

public struct Mechanism: Sendable, Identifiable {
    public var id: String
    public var title: String
    public var summary: String?          // markdown: the idea in a paragraph
    public var participants: [Participant] = []
    public var initial: [StateEntry] = []
    public var steps: [MechStep] = []
    public var branches: [MechBranch] = []
    public var code: [String] = []
    public var line: Int?
    public init(id: String, title: String) { self.id = id; self.title = title }
}

// MARK: - Formulas

public struct Formula: Sendable {
    public var expr: String                              // "score = w_r · recency + w_c · ctr − penalty"
    public var vars: [(name: String, meaning: String)] = []
    public var example: String?                          // a worked example with numbers
    public var doc: String?
    public var code: [String] = []
    public init(expr: String) { self.expr = expr }
}

// MARK: - Enums (value dictionaries and state machines)

public struct EnumValue: Sendable, Hashable {
    public var value: String             // "3100" or "pending"
    public var name: String              // "draft"
    public var doc: String?
    public var terminal = false
    public init(value: String, name: String) { self.value = value; self.name = name }
}

public struct EnumTransition: Sendable, Hashable {
    public var from: String
    public var to: String
    public var label: String?
    public var by: String?               // "node" or "node/op" that performs it
    public init(from: String, to: String) { self.from = from; self.to = to }
}

public struct EnumDef: Sendable, Identifiable {
    public var id: String
    public var label: String
    public var doc: String?
    public var values: [EnumValue] = []
    public var transitions: [EnumTransition] = []
    public var code: [String] = []
    public var line: Int?
    public init(id: String, label: String? = nil) { self.id = id; self.label = label ?? id }
    public func value(_ v: String) -> EnumValue? { values.first { $0.value == v } }
}
