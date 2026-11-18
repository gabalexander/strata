import Foundation
import Observation

// PLACEHOLDER. The engine agent replaces this file's body with the real discrete-event engine
// (docs/manifest.md, "What happens on a call" and "Messages"). The public API below is the
// contract the UI codes against: keep every signature; add more if useful and say so.
//
// Until then this stub animates one token around each edge so the UI has something to draw.

@MainActor
@Observable
public final class Simulation {
    public let manifest: Manifest
    /// Node ids from the manifest root to this level (empty = root).
    public let path: [String]
    /// The level being simulated, with implicit edges present and every node positioned.
    public let level: Level

    /// Sim seconds since reset. Not observed: read it inside a TimelineView.
    @ObservationIgnored public private(set) var now: Double = 0
    public var playing = true
    /// 0.25 … 4
    public var speed: Double = 1
    /// The running scenario, if any.
    public private(set) var scenario: String?
    /// Latest narration (scenario `say`, step `say`, command feedback). nil = none.
    public private(set) var narration: String?
    /// Bumps on every discrete change (a command, a log entry, a scenario step, a param change).
    public private(set) var revision = 0
    @ObservationIgnored public private(set) var log: [LogEntry] = []

    @ObservationIgnored private var params: [Binding: Value] = [:]

    /// `parentRate`: measured request rate of the node this level is inside (for `rate: parent`).
    public init(manifest: Manifest, path: [String] = [], parentRate: Double? = nil, seed: UInt64 = 1) {
        self.manifest = manifest
        self.path = path
        self.level = manifest.level(at: path) ?? manifest.root
    }

    /// Called every display frame with wall-clock seconds since the previous frame.
    /// Advances `now` by `dt * speed` when playing (clamped so a stall never jumps far).
    public func tick(_ wallDelta: Double) {
        guard playing else { return }
        now += min(wallDelta, 0.1) * speed
    }

    /// While paused: advance a short slice (0.1 s sim) so you can watch one step at a time.
    public func step() { now += 0.1; revision += 1 }

    /// Back to t = 0 with the manifest's parameters (and the same seed).
    public func reset() { now = 0; log = []; narration = nil; scenario = nil; params = [:]; revision += 1 }

    public func perform(_ commands: [Command]) {
        for c in commands { append("\(c)", .info) }
        revision += 1
    }

    /// Fire `count` requests of a source flow now (also works for `rate: manual`).
    public func send(_ flow: String, count: Int = 1) { append("send \(flow) ×\(count)", .info) }

    /// Current value of a bindable parameter (effective: kind defaults applied), nil if unknown.
    public func value(_ b: Binding) -> Value? { params[b] }
    public func setValue(_ v: Value, for b: Binding) { params[b] = v; revision += 1 }

    /// The node's effective parameters with every field filled from kind defaults.
    public func effective(_ node: String) -> NodeParams { level.node(node)?.params ?? NodeParams() }

    public func start(scenario id: String) { reset(); scenario = id; revision += 1 }
    public func stopScenario() { scenario = nil; revision += 1 }

    public func frame() -> SimFrame {
        var f = SimFrame(t: now)
        for (i, e) in level.edges.enumerated() {
            let period = 1.6
            let phase = (now + Double(i) * 0.37).truncatingRemainder(dividingBy: period * 2)
            let forward = phase < period
            f.tokens.append(TokenView(id: i, edge: e.id, progress: (forward ? phase : phase - period) / period,
                                      reverse: !forward, kind: forward ? .request : .response,
                                      color: (i % 6) + 1, flow: level.flows.first?.id ?? ""))
            f.edges[e.id] = EdgeState()
        }
        for (i, n) in level.nodes.enumerated() {
            var s = NodeState()
            s.slots = 8
            s.busy = Int((sin(now + Double(i)) + 1) * 4)
            s.utilization = Double(s.busy) / 8
            if n.kind.role == .buffer { s.depth = Int((sin(now / 2 + Double(i)) + 1) * 6); s.held = Array(repeating: 1, count: min(12, s.depth)) }
            s.throughput = 10
            f.nodes[n.id] = s
        }
        return f
    }

    public func metrics(flow: String) -> FlowMetrics { FlowMetrics() }

    /// Headless: advance `seconds` of sim time as fast as possible (playing or not). For checks and `strata simulate`.
    public func run(seconds: Double) { now += seconds }

    /// A plain-text table of per-flow and per-node metrics at `now`, for `strata simulate`.
    public func report() -> String { "t=\(now)s (engine not implemented yet)" }

    /// Recent samples (one per 0.25 s of sim time, up to 240) for sparklines.
    public func series(_ key: MetricKey) -> [Double] { (0..<60).map { sin((now - Double(60 - $0) * 0.25) / 2) * 0.5 + 0.5 } }

    private func append(_ text: String, _ level: LogEntry.Level, node: String? = nil) {
        log.append(LogEntry(id: log.count, t: now, text: text, level: level, node: node))
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }
}
