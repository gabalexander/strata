import Foundation

// What the engine hands the UI. CONTRACT FILE: owned by the lead; additive changes only, and say so in your report.

/// Everything the stage draws at one instant. Built by `Simulation.frame()`; cheap enough to call every frame.
public struct SimFrame: Sendable {
    public var t: Double
    public var tokens: [TokenView] = []
    public var nodes: [String: NodeState] = [:]
    public var edges: [String: EdgeState] = [:]     // keyed by Edge.id ("from->to")
    public init(t: Double) { self.t = t }
}

/// One visible thing in flight on an edge.
public struct TokenView: Sendable, Identifiable {
    public enum Kind: Sendable { case request, response, message, failure, orphan }
    public var id: Int
    public var edge: String          // Edge.id
    public var progress: Double      // 0 at edge.from … 1 at edge.to, already eased; the UI just places it
    public var reverse: Bool         // travelling to → from (responses, nacks)
    public var kind: Kind
    public var color: Int            // 1...6, the flow's colour
    public var flow: String
    public var label: String?
    public init(id: Int, edge: String, progress: Double, reverse: Bool, kind: Kind, color: Int, flow: String, label: String? = nil) {
        self.id = id; self.edge = edge; self.progress = progress; self.reverse = reverse
        self.kind = kind; self.color = color; self.flow = flow; self.label = label
    }
}

public enum Health: Sendable, Hashable { case up, down, slow, failing }

public struct NodeState: Sendable {
    public var health: Health = .up
    public var replicas = 1
    public var busy = 0                  // slots in use
    public var slots = 0                 // concurrency × replicas; 0 = unlimited (sources, ports)
    public var queued = 0                // requests in the waiting room
    public var depth = 0                 // buffers: ready messages
    public var unacked = 0               // buffers: delivered, not yet acked
    public var held: [Int] = []          // buffers: colours of the oldest ready messages (≤ 12), for drawing slots
    public var lag: [String: Int] = [:]  // topics: consumer node id → messages behind
    public var throughput = 0.0          // completed per second, recent
    public var arrivals = 0.0            // arrived per second, recent
    public var errors = 0.0              // failures per second, recent
    public var p50: Double?              // seconds, recent handling latency (arrival → response)
    public var p99: Double?
    public var utilization = 0.0         // busy / slots, 0...1
    public var redirectedTo: String?
    public var lastFailure: Double?      // sim time of the latest failure at this node (the UI flashes it)
    public var groupLag: [String: Int] = [:] // topics: consumer flow id → messages behind
    public var lost = 0                  // buffers: total messages or group deliveries lost
    public init() {}
}

public struct EdgeState: Sendable {
    public var cut = false
    public var extraLatency = 0.0
    public var rate = 0.0                // traversals per second, recent
    public var breakerOpen = false       // a circuit breaker on calls across this edge is open
    public init() {}
}

public struct LogEntry: Sendable, Identifiable {
    public enum Level: Sendable { case info, good, warn, bad }
    public var id: Int
    public var t: Double
    public var text: String
    public var level: Level
    public var node: String?
    public init(id: Int, t: Double, text: String, level: Level, node: String? = nil) {
        self.id = id; self.t = t; self.text = text; self.level = level; self.node = node
    }
}

public struct FlowMetrics: Sendable {
    public var configuredRate = 0.0      // per second, from `rate`
    public var started = 0.0             // per second, recent
    public var ok = 0.0
    public var failed = 0.0
    public var retries = 0.0
    public var timeouts = 0.0
    public var p50: Double?              // seconds, end to end
    public var p95: Double?
    public var p99: Double?
    public var inFlight = 0
    public var totalOK = 0
    public var totalFailed = 0
    public init() {}
}

public enum NodeMetric: String, Sendable, CaseIterable { case inflight, queued, util, throughput, errors, p50, p99, depth, lag }
public enum FlowMetric: String, Sendable, CaseIterable { case rate, ok, errors, p50, p99, retries }

public enum MetricKey: Sendable, Hashable {
    case node(String, NodeMetric)
    case flow(String, FlowMetric)

    /// Parses `orders.inflight` / `place-order.p99` against a level (node ids win over flow ids).
    public static func parse(_ s: String, in level: Level) -> MetricKey? {
        guard let dot = s.lastIndex(of: ".") else { return nil }
        let id = String(s[..<dot]), m = String(s[s.index(after: dot)...])
        if level.node(id) != nil, let nm = NodeMetric(rawValue: m) { return .node(id, nm) }
        if level.flow(id) != nil, let fm = FlowMetric(rawValue: m) { return .flow(id, fm) }
        return nil
    }
}

/// Live numbers for one operation (steps with `op:` that name it). Zero when nothing references it.
public struct OpMetrics: Sendable {
    public var rate = 0.0                // executions per second, recent
    public var errors = 0.0              // failures per second, recent
    public var p50: Double?              // seconds, from step start to its result
    public var p99: Double?
    public var total = 0
    public var referenced = false        // some flow step names this op
    public init() {}
}
