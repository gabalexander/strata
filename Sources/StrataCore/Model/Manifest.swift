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
    public var root: Level
    public var source: ManifestSource

    public init(id: String, title: String, root: Level, source: ManifestSource) {
        self.id = id; self.title = title; self.root = root; self.source = source
    }

    /// The level reached by following `path` (node ids) through `inside:` levels. nil if the path
    /// leaves this manifest (a node with `detail:` instead of `inside:`) or doesn't exist.
    public func level(at path: [String]) -> Level? {
        var level = root
        for id in path {
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
    public var group: String?
    public var doc: String?
    public var term: String?
    public var code: [String] = []
    public var links: [Link] = []
    public var params = NodeParams()
    public var inside: Level?
    public var detail: String?
    public var actions: [Action] = []
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
    public var line: Int?
    public init(_ action: StepAction) { self.action = action }
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
