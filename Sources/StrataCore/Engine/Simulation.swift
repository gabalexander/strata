import Foundation
import Observation

/// A discrete-event simulation of one level, driven on the main actor by the stage.
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
    /// True if the most recent advance stopped at a simulation safety limit.
    public private(set) var eventLimitReached = false
    /// Bumps on every discrete change (a command, a log entry, a scenario step, a param change).
    public private(set) var revision = 0
    @ObservationIgnored public private(set) var log: [LogEntry] = []

    let topology: ProgramTopology
    /// Arrival rate supplied by the parent level when this session was opened.
    public let parentRate: Double?
    private let seed: UInt64
    private let topicConsumers: Set<Int>

    @ObservationIgnored var nodes: [NodeRuntime] = []
    @ObservationIgnored var flows: [FlowRuntime] = []
    @ObservationIgnored var edges: [LinkRuntime] = []
    @ObservationIgnored private var links: [Endpoints: Int] = [:]
    @ObservationIgnored var circuits: [CircuitKey: Circuit] = [:]
    @ObservationIgnored var jobs = RecordPool<Job>()
    @ObservationIgnored var calls = RecordPool<CallRecord>()
    @ObservationIgnored var deliveries = RecordPool<Delivery>()
    @ObservationIgnored var random: SimulationRandom
    @ObservationIgnored private var events = EventQueue()
    @ObservationIgnored var tokens: [InTransit] = []
    @ObservationIgnored var tokenSequence = 0
    @ObservationIgnored var logSequence = 0
    @ObservationIgnored var floodSecond = 0
    @ObservationIgnored var floods: [Flood: FloodBatch] = [:]
    @ObservationIgnored var histories: [MetricKey: SeriesHistory] = [:]
    @ObservationIgnored var opRuntimes: [OpRuntime] = []
    @ObservationIgnored var narratedSteps: Set<Int> = []
    @ObservationIgnored private var scenarioGeneration = 0

    private struct Endpoints: Hashable {
        let from: Int
        let to: Int
    }

    /// `parentRate`: measured request rate of the node this level is inside (for `rate: parent`).
    public init(manifest: Manifest, path: [String] = [], parentRate: Double? = nil, seed: UInt64 = 1) {
        self.manifest = manifest
        self.path = path
        let topology = ProgramTopology(manifest.level(at: path) ?? manifest.root)
        self.topology = topology
        self.level = topology.level
        self.parentRate = parentRate
        self.seed = seed
        random = SimulationRandom(state: seed)
        var queueConsumers: Set<Int> = []
        var topicConsumers: Set<Int> = []
        for flow in topology.level.flows {
            guard let on = flow.on, let by = flow.by,
                  let buffer = topology.nodeIndex[on], let consumer = topology.nodeIndex[by] else { continue }
            if topology.level.nodes[buffer].kind == .topic { topicConsumers.insert(consumer) }
            else { queueConsumers.insert(consumer) }
        }
        self.topicConsumers = topicConsumers.subtracting(queueConsumers)
        reset()
    }

    /// Called every display frame with wall-clock seconds since the previous frame.
    public func tick(_ wallDelta: Double) {
        guard playing, wallDelta.isFinite, wallDelta >= 0, speed.isFinite else { return }
        advance(to: now + min(wallDelta, 0.1) * min(4, max(0.25, speed)), whilePlaying: true)
    }

    /// While paused: advance a short slice (0.1 s sim) so you can watch one step at a time.
    public func step() {
        guard !playing else { return }
        advance(to: now + 0.1)
        revision += 1
    }

    /// Back to t = 0 with the manifest's parameters (and the same seed).
    public func reset() {
        now = 0
        log = []
        narration = nil
        scenario = nil
        eventLimitReached = false
        scenarioGeneration = 0
        events = EventQueue()
        jobs = RecordPool()
        calls = RecordPool()
        deliveries = RecordPool()
        random = SimulationRandom(state: seed)
        tokens.removeAll(keepingCapacity: true)
        tokenSequence = 0
        logSequence = 0
        floodSecond = 0
        floods.removeAll(keepingCapacity: true)
        histories.removeAll(keepingCapacity: true)
        circuits.removeAll(keepingCapacity: true)
        narratedSteps.removeAll(keepingCapacity: true)
        nodes = level.nodes.enumerated().map { NodeRuntime($1, topicConsumer: topicConsumers.contains($0)) }
        opRuntimes = topology.ops.map { OpRuntime(referenced: $0.referenced) }
        let countLimits = SimulationLimits.nodeCounts.sorted { $0.key < $1.key }
        for node in nodes {
            for (param, limit) in countLimits {
                if let count = NodeConfiguration.value(param, in: node.node.params)?.number, count > Double(limit) {
                    logCountClamp(Binding(.node(node.node.id), param), to: limit)
                }
            }
        }
        flows = level.flows.enumerated().map {
            FlowRuntime($1, index: $0, program: topology.flowPrograms[$0], topology: topology)
        }
        edges.removeAll(keepingCapacity: true)
        links.removeAll(keepingCapacity: true)
        for edge in level.edges {
            if let from = topology.nodeIndex[edge.from], let to = topology.nodeIndex[edge.to] {
                addLink(edge, from: from, to: to)
            }
        }
        for (index, flow) in flows.enumerated() {
            if let buffer = flow.buffer, let consumer = flow.consumer {
                nodes[buffer].buffer?.consumers.append(index)
                nodes[consumer].consumerFlows.append(index)
            }
            scheduleSource(index)
        }
        schedule(.sample(1), at: 0.25)
        revision += 1
    }

    public func perform(_ commands: [Command]) {
        for command in commands { apply(command) }
    }

    /// Fire `count` requests of a source flow now (also works for `rate: manual`).
    public func send(_ flow: String, count: Int = 1) {
        guard count > 0, let index = topology.flowIndex[flow], flows[index].source != nil else { return }
        let allowed = min(count, SimulationLimits.send)
        if count > allowed { append("Clamped send on \(flow) to \(allowed) requests", .warn) }
        for _ in 0..<allowed { startSource(index) }
    }

    /// Current value of a bindable parameter (effective: kind defaults applied), nil if unknown.
    public func value(_ b: Binding) -> Value? { read(b) }

    public func setValue(_ v: Value, for b: Binding) {
        if write(v, to: b) { revision += 1 }
    }

    /// The node's effective parameters with every field filled from kind defaults.
    public func effective(_ node: String) -> NodeParams {
        guard let index = topology.nodeIndex[node] else { return NodeParams() }
        return nodes[index].params
    }

    public func start(scenario id: String) {
        guard let definition = level.scenarios.first(where: { $0.id == id }) else { return }
        reset()
        scenarioGeneration += 1
        scenario = id
        playing = true
        append("Started \(definition.label)", .info)
        perform(definition.setup)
        for step in definition.steps {
            schedule(.scenario(step, scenarioGeneration), at: step.at)
        }
        schedule(.endScenario(scenarioGeneration), at: (definition.steps.map(\.at).max() ?? 0) + 10)
        advance(to: now)
    }

    public func stopScenario() {
        scenario = nil
        scenarioGeneration += 1
        revision += 1
    }

    /// Current state of a single node, without constructing a render frame.
    public func nodeState(_ id: String) -> NodeState? {
        topology.nodeIndex[id].map(nodeState)
    }

    /// Current state of a single diagram edge, without constructing a render frame.
    public func edgeState(_ id: String) -> EdgeState? {
        let endpoints = id.components(separatedBy: "->")
        guard endpoints.count == 2,
              let from = topology.nodeIndex[endpoints[0]], let to = topology.nodeIndex[endpoints[1]],
              let index = existingLink(from: from, to: to) else { return nil }
        return edgeState(edges[index])
    }

    private func edgeState(_ edge: LinkRuntime) -> EdgeState {
        var state = EdgeState()
        state.cut = edge.cut
        state.extraLatency = edge.extra
        state.rate = edge.traversals.value(at: now)
        state.breakerOpen = edge.openCircuits > 0
        return state
    }

    public func frame() -> SimFrame {
        var frame = SimFrame(t: now)
        for index in nodes.indices { frame.nodes[nodes[index].node.id] = nodeState(index) }
        for edge in edges { frame.edges[edge.id] = edgeState(edge) }
        frame.tokens.reserveCapacity(tokens.count)
        for token in tokens where now < token.end {
            let fraction = min(1, max(0, (now - token.start) / (token.end - token.start)))
            let eased = fraction * fraction * (3 - 2 * fraction)
            let kind: TokenView.Kind = token.reply.map { isWaiting(for: $0) ? token.kind : .orphan } ?? token.kind
            let flow = flows[token.traffic.flow]
            frame.tokens.append(TokenView(id: token.id, edge: edges[token.edge].id,
                                          progress: token.reverse ? 1 - eased : eased, reverse: token.reverse,
                                          kind: kind, color: flow.color, flow: flow.flow.id, label: token.label))
        }
        return frame
    }

    public func metrics(flow: String) -> FlowMetrics {
        guard let index = topology.flowIndex[flow] else { return FlowMetrics() }
        return flowState(index)
    }

    /// Live numbers for an operation on a node of this level: every step that names it counts.
    /// Zero, with `referenced == false`, for an op no step names or one that doesn't exist.
    public func opMetrics(node: String, op: String) -> OpMetrics {
        opIndex(node: node, op: op).map(opState) ?? OpMetrics()
    }

    /// Recent samples (one per 0.25 s, up to 240) of an operation's `rate`, `errors`, `p50` or `p99`.
    /// Empty for an op no step names.
    public func opSeries(node: String, op: String, metric: String) -> [Double] {
        guard let index = opIndex(node: node, op: op), let slot = OpRuntime.metrics.firstIndex(of: metric) else { return [] }
        return opRuntimes[index].history[slot].ordered
    }

    /// Headless: advance `seconds` of sim time as fast as possible, stopping at safety limits.
    public func run(seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        advance(to: now + seconds, eventBudget: 1_000_000)
    }

    /// A plain-text table of per-flow, per-node and per-op metrics at `now`, for `strata simulate`.
    public func report() -> String {
        func table(_ rows: [[String]]) -> String {
            let widths = rows[0].indices.map { column in rows.map { $0[column].count }.max() ?? 0 }
            return rows.map { row in
                row.enumerated().map { index, cell in
                    let padding = String(repeating: " ", count: widths[index] - cell.count)
                    return index == 0 ? cell + padding : padding + cell
                }.joined(separator: "  ")
            }.joined(separator: "\n")
        }
        func number(_ value: Double) -> String { String(format: "%.2f", value) }
        func ms(_ value: Double?) -> String { value.map { number($0 * 1000) } ?? "–" }
        var flowRows = [["Flow", "rate/s", "ok/s", "err/s", "p50 ms", "p99 ms", "retry/s"]]
        for index in flows.indices {
            let state = flowState(index)
            flowRows.append([flows[index].flow.id, number(state.started), number(state.ok), number(state.failed),
                             ms(state.p50), ms(state.p99), number(state.retries)])
        }
        var nodeRows = [["Node", "arr/s", "util", "in-flight", "queued", "depth", "lag", "err/s"]]
        for index in nodes.indices {
            let node = nodes[index]
            let state = nodeState(index)
            nodeRows.append([node.node.id, number(state.arrivals), number(state.utilization),
                             String(node.live.count - node.queuedCalls), String(state.queued),
                             node.buffer == nil ? "–" : String(state.depth),
                             state.lag.isEmpty ? "–" : String(state.lag.values.reduce(0, +)), number(state.errors)])
        }
        let opRows = opRows(number: number, ms: ms)
        let recent = log.suffix(10).map { "[\(number($0.t))s] \($0.text)" }.joined(separator: "\n")
        return ["t = \(number(now))s", table(flowRows), table(nodeRows), opRows.count > 1 ? table(opRows) : "", recent]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Recent samples (one per 0.25 s of sim time, up to 240) for sparklines.
    public func series(_ key: MetricKey) -> [Double] { histories[key]?.ordered ?? [] }

    func schedule(_ event: SimulationEvent, at time: Double) {
        if time.isFinite { events.insert(event, at: max(now, time)) }
    }

    private func advance(to target: Double, whilePlaying: Bool = false, eventBudget: Int = 20_000) {
        guard target.isFinite else { return }
        eventLimitReached = false
        var handled = 0
        var eventTime: Double?
        var nextWave = 0
        var sameTimeWaves = 0
        while let entry = events.first, entry.time <= target, !whilePlaying || playing {
            if eventTime != entry.time {
                eventTime = entry.time
                sameTimeWaves = 0
                nextWave = events.nextSequence
            } else if entry.sequence >= nextWave {
                // Count successive waves of newly scheduled work, so a wide batch alone isn't a loop.
                sameTimeWaves += 1
                nextWave = events.nextSequence
            }
            if sameTimeWaves >= 1024 {
                pauseAtLimit("Paused: zero-time loop \(eventContext(entry.event))")
                break
            }
            if handled >= eventBudget {
                pauseAtLimit("Paused: event budget of \(eventBudget) exhausted \(eventContext(entry.event))")
                break
            }
            _ = events.pop()
            now = entry.time
            handled += 1
            process(entry.event)
        }
        if !eventLimitReached && (!whilePlaying || playing) { now = target }
        if !tokens.isEmpty { tokens.removeAll { $0.end <= now } }
    }

    private func pauseAtLimit(_ message: String) {
        eventLimitReached = true
        playing = false
        narrate(message)
        append(message, .warn)
    }

    private func eventContext(_ event: SimulationEvent) -> String {
        switch event {
        case .request(let attempt, _), .response(let attempt, _, _):
            return "on \(edges[attempt.edge].id)"
        case .delivery(_, let edge, _), .deadLetter(_, let edge, _):
            return "on \(edges[edge].id)"
        case .pumpBuffer(let index):
            let buffer = nodes[index]
            let consumers = buffer.buffer!.consumers.prefix(3).map { flows[$0].flow.by! }
            return "at \(buffer.node.id) feeding \(consumers.joined(separator: ", "))"
        case .source(let index, _): return "in flow \(flows[index].flow.id)"
        case .pumpNode(let index), .expire(let index, _), .finishPublish(let index, _, _, _):
            return "at \(nodes[index].node.id)"
        default: return "at \(Value.number(now))s"
        }
    }

    private func process(_ event: SimulationEvent) {
        switch event {
        case .source(let flow, let generation):
            guard flows[flow].generation == generation else { return }
            startSource(flow)
            scheduleSource(flow)
        case .continueJob(let id): advanceJob(id)
        case .deadline(let id):
            guard let job = jobs[id] else { return }
            let duration = now - job.arrived
            flows[job.traffic.flow].timeouts.add(at: now)
            note(.timeout, Failure.deadline(duration).describe(level, edges: edges), visible: job.traffic.visible)
            finishJob(id, failure: .deadline(duration))
        case .request(let attempt, let epoch): receiveRequest(attempt, epoch: epoch)
        case .finishPublish(let target, let origin, let epoch, let arrived):
            finishPublish(to: target, from: origin, ingressEpoch: epoch, arrived: arrived)
        case .response(let attempt, let epoch, let failure): receiveResponse(attempt, epoch: epoch, failure: failure)
        case .timeout(let id, let number): timeoutCall(id, number: number)
        case .retry(let id): startAttempt(id)
        case .pumpNode(let index): pumpNode(index)
        case .pumpBuffer(let index): pumpBuffer(index)
        case .delivery(let delivery, let edge, let epoch): receiveDelivery(delivery, edge: edge, epoch: epoch)
        case .deadLetter(let letter, let edge, let epoch): receiveDeadLetter(letter, edge: edge, epoch: epoch)
        case .retryDelivery(let id): retryDelivery(id)
        case .expire(let buffer, let message): expire(buffer, message: message)
        case .scenario(let step, let generation):
            guard generation == scenarioGeneration, scenario != nil else { return }
            append("Scenario step at \(Value.number(step.at))s", .info)
            perform(step.commands)
            if let say = step.say { narrate(say) }
        case .endScenario(let generation):
            if generation == scenarioGeneration, scenario != nil { stopScenario() }
        case .sample(let sequence):
            sampleMetrics()
            schedule(.sample(sequence + 1), at: Double(sequence + 1) * 0.25)
        case .flushLog(let second):
            if second == floodSecond { flushLog() }
        }
    }

    func append(_ text: String, _ level: LogEntry.Level, node: Int? = nil, time: Double? = nil) {
        logSequence += 1
        let id = node.map { nodes[$0].node.id }
        log.append(LogEntry(id: logSequence, t: time ?? now, text: text, level: level, node: id))
        if log.count > 300 { log.removeFirst(log.count - 300) }
        revision += 1
    }

    func updateLog(_ id: Int, withSummary summary: String) {
        guard let index = log.lastIndex(where: { $0.id == id }) else { return }
        log[index].text = summary + " · " + log[index].text
        revision += 1
    }

    func narrate(_ text: String) {
        narration = text
        revision += 1
    }

    func rate(for flow: FlowRuntime) -> Double {
        let rate = flow.rate.perSecondValue ?? parentRate ?? 5
        return rate.isFinite ? min(SimulationLimits.rate, rate) : 0
    }

    func changeRate(_ flow: Int, to rate: Rate) {
        flows[flow].rate = rate
        flows[flow].generation += 1
        scheduleSource(flow)
    }

    private func scheduleSource(_ index: Int) {
        let flow = flows[index]
        guard flow.source != nil else { return }
        let rate = rate(for: flow)
        guard rate.isFinite, rate > 0 else { return }
        let spacing: Double
        switch flow.rate {
        case .every(let seconds): spacing = max(seconds, 1 / SimulationLimits.rate)
        case .manual: return
        case .perSecond, .parent: spacing = random.sample(.exponential(1 / rate))
        }
        schedule(.source(index, flow.generation), at: max(now.nextUp, now + spacing))
    }

    func startSource(_ index: Int) {
        let flow = flows[index]
        guard let source = flow.source else { return }
        let traffic = Traffic(flow: index, visible: flow.sample(at: now))
        startFlow(index)
        let node = nodes[source]
        node.arrivals.add(at: now)
        let id = jobs.insert(Job(end: .source, node: source, traffic: traffic, arrived: now, program: flow.program))
        node.live.insert(id)
        guard node.up else {
            note(.failed, "\(node.node.id): connection refused", node: source, visible: traffic.visible)
            finishJob(id, failure: .refused)
            return
        }
        if flow.deadline > 0 { schedule(.deadline(id), at: now + flow.deadline) }
        advanceJob(id)
    }

    func startFlow(_ index: Int) {
        let flow = flows[index]
        flow.started.add(at: now)
        flow.inFlight += 1
    }

    @discardableResult
    private func addLink(_ edge: Edge, from: Int, to: Int) -> Int {
        let key = Endpoints(from: from, to: to)
        if let index = links[key] { return index }
        links[key] = edges.count
        edges.append(LinkRuntime(edge, from: from, to: to))
        return edges.count - 1
    }

    func existingLink(from: Int, to: Int) -> Int? { links[Endpoints(from: from, to: to)] }

    func link(from: Int, to: Int) -> Int {
        if let index = existingLink(from: from, to: to) { return index }
        return addLink(Edge(from: nodes[from].node.id, to: nodes[to].node.id), from: from, to: to)
    }

    func destination(_ index: Int) -> Int {
        var resolved = index
        for _ in nodes.indices {
            guard let redirect = nodes[resolved].redirect else { return resolved }
            resolved = redirect
        }
        return index
    }
}
