import Foundation

// Where an architecture hurts: capacity and bottlenecks, what to scale, backpressure and blast
// radius, database pressure, volumes, and live trouble spots (docs/manifest.md, Pressure).
// CONTRACT FILE: owned by the lead. PLACEHOLDER bodies until the analysis work lands; keep the API.

/// How much one node can take and how much it's taking.
public struct NodeCapacity: Sendable, Identifiable {
    public var id: String { node }
    public var node: String
    public var slots: Int?               // concurrency × replicas; nil = unlimited (sources, ports, buffers)
    /// Mean seconds a request holds a slot here: own work plus, unless `async`, every downstream call it waits on.
    public var holdTime: Double
    /// Slot-seconds of demand per second at the analysed rates (busy slots on average).
    public var demand: Double
    public var utilization: Double       // demand / slots (0 for unlimited)
    /// Requests per second arriving here per 1 request/s of each flow (visits, including p, cache misses).
    public var visits: [String: Double]
    public init(node: String, slots: Int?, holdTime: Double, demand: Double, utilization: Double, visits: [String: Double]) {
        self.node = node; self.slots = slots; self.holdTime = holdTime; self.demand = demand
        self.utilization = utilization; self.visits = visits
    }
}

public struct FlowCapacity: Sendable, Identifiable {
    public var id: String { flow }
    public var flow: String
    public var rate: Double              // analysed rate, per second
    public var daily: Double             // per day: traffic.daily if declared, else rate × 86 400
    public var maxRate: Double?          // rate at which the first node saturates (others held at their rates); nil = unbounded
    public var bottleneck: String?       // that node
    public var declared: FlowTraffic?
    public var slo: SLO?
    public init(flow: String, rate: Double, daily: Double) { self.flow = flow; self.rate = rate; self.daily = daily }
}

/// One step of "what to scale": scale `node` to `replicas`, and the system then saturates at `newMaxRate` on `nextBottleneck`.
public struct ScaleStep: Sendable, Identifiable {
    public var id: String { "\(node)-\(replicas)" }
    public var node: String
    public var replicas: Int
    public var reason: String
    public var newMaxRate: Double?
    public var nextBottleneck: String?
    public init(node: String, replicas: Int, reason: String) { self.node = node; self.replicas = replicas; self.reason = reason }
}

/// One source of load on a database (or any server): which op from which node, and its share of busy time.
public struct LoadSource: Sendable, Identifiable {
    public var id: String { "\(node)/\(op ?? "-")/\(flow)" }
    public var node: String              // calling node
    public var op: String?               // op id on the calling node, when the step names one
    public var flow: String
    public var tables: [String]
    public var access: OpAccess?
    public var rate: Double              // calls per second at the target
    public var busyShare: Double         // fraction of the target's demand, 0...1
    public init(node: String, op: String?, flow: String, tables: [String], access: OpAccess?, rate: Double, busyShare: Double) {
        self.node = node; self.op = op; self.flow = flow; self.tables = tables; self.access = access; self.rate = rate; self.busyShare = busyShare
    }
}

public struct CapacityReport: Sendable {
    public var nodes: [NodeCapacity] = []        // sorted: highest utilization first
    public var flows: [FlowCapacity] = []
    public var scalePlan: [ScaleStep] = []       // in order; empty when nothing saturates within 100× the current rates
    /// Per target node (databases, caches, search, any server): load sources, biggest share first.
    public var pressure: [String: [LoadSource]] = [:]
    public init() {}
}

/// What backs up when `node` slows down or stops.
public struct BlastRadius: Sendable {
    public var node: String
    /// Synchronous callers that hold slots while waiting on it, nearest first (they saturate next).
    public var upstream: [String] = []
    /// Edges along which the pressure travels (Edge.id).
    public var edges: [String] = []
    /// Buffers (queues/topics) where the pressure stops and turns into depth.
    public var absorbers: [String] = []
    /// Consumers downstream whose lag grows (they starve or fall behind).
    public var lagging: [String] = []
    /// Flows that fail or slow down.
    public var flows: [String] = []
    public init(node: String) { self.node = node }
}

/// A live trouble spot in the running simulation.
public struct Culprit: Sendable, Identifiable {
    public enum Kind: String, Sendable { case saturated, queueing, lagging, timeouts, errors, breakerOpen, down, sloBreach }
    public enum Severity: Int, Sendable, Comparable {
        case watch = 0, warn = 1, critical = 2
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }
    public var id: String { "\(kind.rawValue):\(subject)" }
    public var kind: Kind
    public var severity: Severity
    public var subject: String           // node id, flow id or edge id
    public var message: String           // one plain sentence with the number, e.g. "orders db: 19/20 connections busy, 140 queued"
    public init(kind: Kind, severity: Severity, subject: String, message: String) {
        self.kind = kind; self.severity = severity; self.subject = subject; self.message = message
    }
}

public enum Analysis {
    /// Static (expected-value) capacity analysis of a level at the given flow rates (per second).
    /// Missing rates use each flow's configured rate; `params` overrides node parameters (runtime state).
    public static func capacity(of level: Level, rates: [String: Double] = [:], params: [String: NodeParams] = [:]) -> CapacityReport {
        CapacityReport()
    }

    /// Pure graph analysis of how a slowdown at `node` propagates.
    public static func blastRadius(of node: String, in level: Level) -> BlastRadius { BlastRadius(node: node) }
}

@MainActor
public extension Simulation {
    /// Capacity analysis with the sim's current rates and runtime parameters (scaled replicas, slow factors, …).
    func capacityReport() -> CapacityReport { Analysis.capacity(of: level) }
    /// What is hurting right now, worst first.
    func culprits() -> [Culprit] { [] }
    func blastRadius(_ node: String) -> BlastRadius { Analysis.blastRadius(of: node, in: level) }
}
