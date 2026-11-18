import Foundation

// Expected-value capacity model of one level (docs/manifest.md, Traffic, SLOs and pressure).
//
// Each flow's steps compile once into a tree with the probabilities resolved (`p`, cache misses,
// retries, failures). An evaluation walks every tree with the current queueing delays and sums,
// per node and flow, the visits and the slot-seconds held per request. Rates multiply those into
// demand (busy slots) and utilization (demand / slots).
//
// Approximations, and where they stop being true:
// - Means only. A request holds a slot for the mean of its latency distribution (× the slow
//   factor), plus `work` steps, plus, unless the node is `async`, everything it waits on.
// - Retries add expected attempts 1 + f + f² + … + f^retries and the mean backoff between them,
//   where f is the chance an attempt fails: the callee's `errors`, a failed non-optional step
//   inside it, or 1 when it is down. Timeouts aren't modelled statically: a caller that gives up
//   still counts the callee's full time, and the callee's work after a timeout isn't added.
// - Queueing. A call waits for a slot in the callee's waiting room for the M/M/c mean (Erlang C)
//   once the callee is at 70% utilization or more; below that the wait is taken as 0 (service
//   time only). The wait never exceeds a full waiting room (`queue` × hold time / slots), and is 0
//   with `queue: 0`, where overflow is rejected instead.
// - `parallel` takes its slowest branch's mean, which underestimates the mean of the maximum.
// - Breakers, link loss and cuts, deadlines, TTLs and buffer overflow aren't modelled.
// - Consumer flows run at the rate messages arrive at their buffer: a topic gives every consumer
//   flow the full rate, a queue splits it by the consumers' replicas. Node demand counts that
//   offered rate even when the consumer can't keep up, so a utilization above 1 says how far
//   short the node falls; the flow's own `rate` is capped at what the consumer can handle.

/// Runtime state the static analysis takes into account beyond node parameters: a running sim's
/// slow factors, killed nodes, redirects and link delays. Empty for a manifest at rest.
struct AnalysisInputs {
    var rates: [String: Double] = [:]          // flow id → per second, asked for; a consumer flow given here is fixed
    var liveRates: [String: Double] = [:]      // source flow id → per second in a running sim (traffic.peak still plans)
    var params: [String: NodeParams] = [:]     // node id → overrides (non-nil fields win)
    var slow: [String: Double] = [:]
    var down: Set<String> = []
    var redirects: [String: String] = [:]
    var edgeLatency: [String: Double] = [:]    // Edge.id → one-way mean seconds, added delay included
    var parentRate: Double?
}

struct CapacityModel {
    struct NodeInfo {
        let node: Node
        var params: NodeParams                 // effective: the engine's kind defaults applied
        let down: Bool
        let service: Double                    // own latency mean × slow
        var unlimited: Bool                    // sources, buffers, ports: no slots to run out of

        var slots: Int {
            guard !down else { return 0 }
            let (value, overflow) = (params.concurrency ?? 0).multipliedReportingOverflow(by: params.replicas ?? 1)
            return overflow ? Int.max : value
        }
        /// Down, or a server with no slots at all: nothing gets through.
        var blocked: Bool { !unlimited && slots == 0 }
        var async: Bool { params.async == true }
    }

    struct Call {
        let target: Int
        let p: Double
        let optional: Bool
        let latency: Double                    // one way; the response crosses the same edge
        let nested: [Work]
        let miss: [Work]
        let attempts: Double
        let backoff: Double                    // expected seconds spent between attempts
        let missChance: Double                 // chance the miss branch runs once the step runs
        let fail: Double                       // chance the step fails its parent once it runs
        let source: Int
    }

    struct Publish {
        let target: Int
        let p: Double
        let optional: Bool
        let latency: Double
        let attempts: Double
        let backoff: Double
        let fail: Double
        let source: Int
    }

    indirect enum Work {
        case work(mean: Double, p: Double)
        case call(Call)
        case publish(Publish)
        case parallel(branches: [[Work]], p: Double, optional: Bool, fail: Double)
    }

    enum Role { case source(Int), consumer(buffer: Int, by: Int), inert }

    struct SourceKey: Hashable {
        let target: Int
        let caller: Int
        let op: String?
        let flow: Int
    }

    struct SourceInfo {
        let key: SourceKey
        let tables: [String]
        let access: OpAccess?
    }

    /// Per request of each flow (cells are node × flowCount + flow).
    struct Tally {
        let flowCount: Int
        var visits: [Double]
        var demand: [Double]                   // slot-seconds held
        var published: [Double]                // messages stored at a buffer
        var sourceVisits: [Double]
        var sourceDemand: [Double]
        var latency: [Double]                  // per flow: seconds per run

        init(nodes: Int, flows: Int, sources: Int) {
            flowCount = flows
            visits = Array(repeating: 0, count: nodes * flows)
            demand = visits
            published = visits
            sourceVisits = Array(repeating: 0, count: sources)
            sourceDemand = sourceVisits
            latency = Array(repeating: 0, count: flows)
        }

        mutating func add(_ node: Int, _ flow: Int, visits count: Double, demand held: Double, source: Int?) {
            let cell = node * flowCount + flow
            visits[cell] += count
            demand[cell] += held
            if let source {
                sourceVisits[source] += count
                sourceDemand[source] += held
            }
        }
    }

    struct Evaluation {
        var rates: [Double]                    // per flow, per second (consumer flows derived)
        var demand: [Double]                   // per node, busy slots
        var arrivals: [Double]                 // per node, per second
        var wait: [Double]                     // per node, seconds a call waits for a slot
        var tally: Tally
    }

    let level: Level
    let inputs: AnalysisInputs
    var nodes: [NodeInfo] = []
    let index: [String: Int]
    var roles: [Role] = []
    var programs: [[Work]] = []
    var success: [Double] = []                 // per flow: chance a run succeeds
    var deliveries: [Double] = []              // consumer flows: deliveries per message, redeliveries included
    var transit: [Double] = []                 // topic consumer flows: a pull holds its slot while in transit
    var deliverySources: [Int?] = []
    var syncNodes: [Set<Int>] = []             // per flow: servers its own steps call, and its consumer
    var waitsOn: [Set<Int>] = []               // per node: servers it waits on, transitively
    var publishesTo: [Set<Int>] = []           // per flow: buffers its steps publish to
    var sources: [SourceInfo] = []
    var sourceIndex: [SourceKey: Int] = [:]
    var order: [Int] = []                      // flows, publishers before their consumers
    var configured: [Double] = []              // per flow: the analysed rate (0 for derived consumer flows)
    var fixed: [Bool] = []                     // the rate is given, not derived from publishers
    var notes: [String] = []
    private var edgeLatency: [String: Double] = [:]

    var flowCount: Int { roles.count }

    init(_ level: Level, _ inputs: AnalysisInputs) {
        self.level = level
        self.inputs = inputs
        index = Dictionary(level.nodes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        for edge in level.edges where edgeLatency[edge.id] == nil { edgeLatency[edge.id] = edge.latency?.mean ?? 0.001 }
        for (id, latency) in inputs.edgeLatency { edgeLatency[id] = latency }

        // Same rule as the engine for a consumer's default onError (topic-only consumers retry).
        var queueConsumers: Set<String> = [], topicConsumers: Set<String> = []
        for flow in level.flows {
            guard let on = flow.on, let by = flow.by, let buffer = level.node(on) else { continue }
            if buffer.kind == .topic { topicConsumers.insert(by) } else { queueConsumers.insert(by) }
        }
        nodes = level.nodes.map { node in
            var merged = node
            if let overrides = inputs.params[node.id] { merged.params = Self.merge(node.params, overrides) }
            let params = NodeConfiguration.effective(merged, topicConsumer: topicConsumers.subtracting(queueConsumers).contains(node.id))
            let slow = inputs.slow[node.id].map { $0.isFinite ? max(0, $0) : 1 } ?? 1
            return NodeInfo(node: node, params: params, down: inputs.down.contains(node.id),
                            service: (params.latency?.mean ?? 0) * slow,
                            unlimited: node.kind.role != .server || params.concurrency == .max)
        }
        waitsOn = Array(repeating: [], count: nodes.count)
        for (position, flow) in level.flows.enumerated() { compileFlow(position, flow) }
        order = dependencyOrder()
    }

    // MARK: Compiling flows

    private mutating func compileFlow(_ f: Int, _ flow: Flow) {
        var sync: Set<Int> = []
        var reach: Set<Int> = []
        var buffers: Set<Int> = []
        if let on = flow.on, let by = flow.by, let buffer = index[on], let worker = index[by],
           nodes[buffer].node.kind.role == .buffer, nodes[worker].node.kind.role == .server {
            roles.append(.consumer(buffer: buffer, by: worker))
            sync.insert(worker)
            let (program, alive) = compile(flow.steps, at: worker, flow: f, sync: &sync, reach: &reach, buffers: &buffers)
            programs.append(program)
            let info = nodes[worker]
            let failure = 1 - (1 - (info.params.errors ?? 0)) * alive
            success.append(1 - failure)
            let topic = nodes[buffer].node.kind == .topic
            let mode = inputs.params[by]?.onError ?? info.node.params.onError ?? (topic ? .retry : .requeue)
            let redelivers = topic ? mode == .retry : mode == .requeue && info.params.ack == .manual
            deliveries.append(redelivers ? Self.geometric(failure, terms: max(1, info.params.maxDeliveries ?? 5)) : 1)
            transit.append(topic ? latency(from: buffer, to: worker) : 0)
            deliverySources.append(source(target: worker, caller: buffer, op: nil, flow: f, tables: [], access: nil))
            configured.append(max(0, inputs.rates[flow.id] ?? 0))
            fixed.append(inputs.rates[flow.id] != nil)
        } else if flow.on == nil, let from = flow.from, let origin = index[from] {
            roles.append(.source(origin))
            let (program, alive) = compile(flow.steps, at: origin, flow: f, sync: &sync, reach: &reach, buffers: &buffers)
            programs.append(program)
            success.append(alive)
            deliveries.append(1)
            transit.append(0)
            deliverySources.append(nil)
            let given = inputs.rates[flow.id] ?? inputs.liveRates[flow.id]
            var rate = given ?? flow.rate.perSecondValue ?? inputs.parentRate ?? 5
            if given == nil {
                if flow.rate.perSecondValue == nil, inputs.parentRate == nil {
                    notes.append("\(flow.id) follows its parent's rate (rate: parent); analysed at 5/s.")
                }
                rate = min(SimulationLimits.rate, rate)
            }
            configured.append(nodes[origin].down || !rate.isFinite ? 0 : max(0, rate))
            fixed.append(true)
        } else {
            roles.append(.inert)
            programs.append([])
            success.append(1)
            deliveries.append(0)
            transit.append(0)
            deliverySources.append(nil)
            configured.append(0)
            fixed.append(true)
        }
        syncNodes.append(sync)
        publishesTo.append(buffers)
    }

    /// Compiles steps that run at `caller`; returns them with the chance a run gets through them.
    private mutating func compile(_ steps: [Step], at caller: Int, flow: Int, sync: inout Set<Int>,
                                  reach: inout Set<Int>, buffers: inout Set<Int>) -> ([Work], Double) {
        var program: [Work] = []
        var alive = 1.0
        for step in steps {
            let p = min(1, max(0, step.p ?? 1))
            let retries = max(0, step.retries ?? nodes[caller].params.retries ?? 0)
            let backoff = max(0, step.backoff ?? nodes[caller].params.backoff ?? 0.1)
            switch step.action {
            case .work(let duration):
                program.append(.work(mean: duration.mean, p: p))
            case .call(let id, let nested, let miss):
                guard let original = index[id] else { continue }
                let target = resolve(original)
                let info = nodes[target]
                guard info.node.kind.role == .server else { continue }   // the engine fails it as an invalid target
                sync.insert(target)
                var inner: Set<Int> = []
                let (innerProgram, innerAlive) = compile(nested, at: target, flow: flow, sync: &sync, reach: &inner, buffers: &buffers)
                waitsOn[caller].insert(target)
                waitsOn[caller].formUnion(inner)
                reach.insert(target)
                reach.formUnion(inner)
                let cache = info.node.kind == .cache
                let (missProgram, missAlive) = cache && !miss.isEmpty
                    ? compile(miss, at: caller, flow: flow, sync: &sync, reach: &reach, buffers: &buffers) : ([], 1)
                var attempts = 1.0, waiting = 0.0, callFail = 0.0, missChance = 0.0
                if info.down && cache {
                    // A refused cache call completes as a miss at once, without retries.
                    missChance = missProgram.isEmpty ? 0 : 1
                } else {
                    let attemptFail = info.down ? 1 : 1 - (1 - (info.params.errors ?? 0)) * innerAlive
                    (attempts, waiting) = Self.retryCost(attemptFail, retries: retries, backoff: backoff)
                    callFail = pow(attemptFail, Double(retries) + 1)
                    if !missProgram.isEmpty { missChance = (1 - callFail) * (1 - (info.params.hitRate ?? 0.9)) }
                }
                let fail = callFail + missChance * (1 - missAlive)
                let op = opDetails(step, caller: caller, target: original)
                program.append(.call(Call(target: target, p: p, optional: step.optional, latency: latency(from: caller, to: target),
                                          nested: innerProgram, miss: missProgram, attempts: attempts, backoff: waiting,
                                          missChance: missChance, fail: fail,
                                          source: source(target: target, caller: caller, op: op.id, flow: flow,
                                                         tables: op.tables, access: op.access))))
                if !step.optional { alive *= 1 - p * fail }
            case .publish(let id):
                guard let original = index[id] else { continue }
                let target = resolve(original)
                let info = nodes[target]
                guard info.node.kind.role == .buffer else { continue }
                buffers.insert(target)
                let attemptFail = info.down ? 1 : info.params.errors ?? 0
                let (attempts, waiting) = Self.retryCost(attemptFail, retries: retries, backoff: backoff)
                let fail = pow(attemptFail, Double(retries) + 1)
                let op = opDetails(step, caller: caller, target: original)
                program.append(.publish(Publish(target: target, p: p, optional: step.optional, latency: latency(from: caller, to: target),
                                                attempts: attempts, backoff: waiting, fail: fail,
                                                source: source(target: target, caller: caller, op: op.id, flow: flow,
                                                               tables: op.tables, access: op.access))))
                if !step.optional { alive *= 1 - p * fail }
            case .parallel(let branches):
                guard !branches.isEmpty else { continue }
                var compiled: [[Work]] = []
                var together = 1.0
                for branch in branches {
                    let (work, branchAlive) = compile([branch], at: caller, flow: flow, sync: &sync, reach: &reach, buffers: &buffers)
                    compiled.append(work)
                    together *= branchAlive
                }
                program.append(.parallel(branches: compiled, p: p, optional: step.optional, fail: 1 - together))
                if !step.optional { alive *= 1 - p * (1 - together) }
            }
        }
        return (program, alive)
    }

    /// Expected attempts and backoff seconds when each attempt fails with `fail`.
    /// The engine waits backoff × 2^n (±50%) before retry n + 1.
    static func retryCost(_ fail: Double, retries: Int, backoff: Double) -> (attempts: Double, waiting: Double) {
        var attempts = 1.0, waiting = 0.0, chance = 1.0
        for retry in 0..<min(retries, 1000) {
            chance *= fail
            guard chance > 1e-15 else { break }
            attempts += chance
            waiting += chance * backoff * exp2(Double(min(1023, retry)))
        }
        return (attempts, waiting.isFinite ? waiting : Double.greatestFiniteMagnitude)
    }

    /// 1 + f + f² + … (terms in all).
    static func geometric(_ fail: Double, terms: Int) -> Double {
        var total = 0.0, term = 1.0
        for _ in 0..<min(terms, 1000) {
            total += term
            term *= fail
            if term < 1e-15 { break }
        }
        return total
    }

    static func merge(_ base: NodeParams, _ overrides: NodeParams) -> NodeParams {
        var merged = base
        func take<T>(_ path: WritableKeyPath<NodeParams, T?>) {
            if let value = overrides[keyPath: path] { merged[keyPath: path] = value }
        }
        take(\.latency); take(\.concurrency); take(\.replicas); take(\.queue); take(\.errors); take(\.timeout)
        take(\.retries); take(\.backoff); take(\.async); take(\.capacity); take(\.overflow); take(\.ttl)
        take(\.dlq); take(\.prefetch); take(\.ack); take(\.onError); take(\.maxDeliveries); take(\.hitRate)
        return merged
    }

    /// Follows `redirect` like the engine does.
    private func resolve(_ start: Int) -> Int {
        var current = start
        for _ in nodes.indices {
            guard let next = inputs.redirects[nodes[current].node.id].flatMap({ index[$0] }) else { return current }
            current = next
        }
        return start
    }

    private func latency(from a: Int, to b: Int) -> Double {
        let value = edgeLatency["\(nodes[a].node.id)->\(nodes[b].node.id)"] ?? 0.001
        return value.isFinite ? max(0, value) : 0.001
    }

    /// The op a step names, as the caller's op: its own outbound op, or its client op whose `calls`
    /// reaches the callee endpoint the step names. Tables and access come from whichever op has them.
    private func opDetails(_ step: Step, caller: Int, target: Int) -> (id: String?, tables: [String], access: OpAccess?) {
        let callerID = nodes[caller].node.id
        guard let reference = step.op,
              let resolved = level.resolveOp(reference, caller: callerID, target: nodes[target].node.id) else { return (nil, [], nil) }
        if resolved.node == callerID { return (resolved.op.id, resolved.op.tables, resolved.op.access) }
        let endpoint = "\(resolved.node)/\(resolved.op.id)"
        if let client = nodes[caller].node.ops.first(where: { $0.calls == endpoint }) {
            return (client.id, client.tables.isEmpty ? resolved.op.tables : client.tables, client.access ?? resolved.op.access)
        }
        return (nil, resolved.op.tables, resolved.op.access)
    }

    private mutating func source(target: Int, caller: Int, op: String?, flow: Int, tables: [String], access: OpAccess?) -> Int {
        let key = SourceKey(target: target, caller: caller, op: op, flow: flow)
        if let existing = sourceIndex[key] { return existing }
        sourceIndex[key] = sources.count
        sources.append(SourceInfo(key: key, tables: tables, access: access))
        return sources.count - 1
    }

    /// Source flows first, then consumer flows after every flow that publishes to their buffer.
    private func dependencyOrder() -> [Int] {
        var placed = Array(repeating: false, count: flowCount)
        var result: [Int] = []
        for f in roles.indices {
            if case .consumer = roles[f] { continue }
            placed[f] = true
            result.append(f)
        }
        var progress = true
        while progress {
            progress = false
            for f in roles.indices where !placed[f] {
                guard case .consumer(let buffer, _) = roles[f] else { continue }
                let ready = roles.indices.allSatisfy { g in g == f || placed[g] || !publishesTo[g].contains(buffer) }
                if ready {
                    placed[f] = true
                    result.append(f)
                    progress = true
                }
            }
        }
        result += roles.indices.filter { !placed[$0] }   // publish cycles: declaration order
        return result
    }

    // MARK: Evaluating

    func evaluate(_ base: [Double], fixed given: [Bool]? = nil, queueing: Bool = true) -> Evaluation {
        let fixed = given ?? self.fixed
        var wait = Array(repeating: 0.0, count: nodes.count)
        var iteration = 0
        while true {
            let tally = walk(wait)
            let rates = resolveRates(base, fixed: fixed, tally: tally)
            var demand = Array(repeating: 0.0, count: nodes.count)
            var arrivals = demand
            for node in nodes.indices {
                var busy = 0.0, count = 0.0
                for flow in rates.indices where rates[flow] > 0 {
                    let cell = node * flowCount + flow
                    busy += rates[flow] * tally.demand[cell]
                    count += rates[flow] * tally.visits[cell]
                }
                demand[node] = busy
                arrivals[node] = count
            }
            let evaluation = Evaluation(rates: rates, demand: demand, arrivals: arrivals, wait: wait, tally: tally)
            iteration += 1
            // Waits only feed callers, and calls can't cycle, so this settles within the call depth.
            guard queueing, iteration < nodes.count + 3 else { return evaluation }
            let next = nodes.indices.map { queueWait($0, demand: demand[$0], arrivals: arrivals[$0]) }
            if zip(next, wait).allSatisfy({ abs($0 - $1) <= 1e-12 + 1e-9 * $1 }) { return evaluation }
            wait = next
        }
    }

    /// Consumer flows run at the rate their buffer receives messages (unless their rate is fixed).
    func resolveRates(_ base: [Double], fixed: [Bool], tally: Tally) -> [Double] {
        var rates = base
        for f in order {
            guard case .consumer(let buffer, _) = roles[f], !fixed[f] else { continue }
            rates[f] = inflow(buffer, rates: rates, tally: tally, excluding: f) * share(f)
        }
        return rates
    }

    /// Messages per second stored at `buffer`.
    func inflow(_ buffer: Int, rates: [Double], tally: Tally, excluding: Int? = nil) -> Double {
        var total = 0.0
        for g in rates.indices where g != excluding && rates[g] > 0 {
            total += rates[g] * tally.published[buffer * flowCount + g]
        }
        return total
    }

    /// A topic gives every consumer flow each message; a queue splits them by the replicas of the
    /// consumers that are up (all of them when none is, so the messages stay meant for someone).
    func share(_ f: Int) -> Double {
        guard case .consumer(let buffer, let by) = roles[f] else { return 1 }
        if nodes[buffer].node.kind == .topic { return 1 }
        var up = 0, all = 0
        for case .consumer(buffer, let other) in roles {
            let replicas = nodes[other].params.replicas ?? 1
            all += replicas
            if !nodes[other].down { up += replicas }
        }
        let mine = Double(nodes[by].params.replicas ?? 1)
        if up > 0 { return nodes[by].down ? 0 : mine / Double(up) }
        return all > 0 ? mine / Double(all) : 0
    }

    func walk(_ wait: [Double]) -> Tally {
        var tally = Tally(nodes: nodes.count, flows: flowCount, sources: sources.count)
        for f in roles.indices {
            switch roles[f] {
            case .source(let origin):
                tally.latency[f] = run(programs[f], at: origin, weight: 1, flow: f, wait: wait, into: &tally).elapsed
            case .consumer(_, let by):
                let worker = nodes[by]
                let count = deliveries[f]
                guard !worker.down else {
                    // Nothing is delivered, but the messages are meant for it: it shows as blocked.
                    tally.add(by, f, visits: count, demand: 0, source: deliverySources[f])
                    continue
                }
                let handled = run(programs[f], at: by, weight: count, flow: f, wait: wait, into: &tally)
                tally.add(by, f, visits: count, demand: count * (worker.service + transit[f] + handled.held), source: deliverySources[f])
                tally.latency[f] = worker.service + handled.elapsed
            case .inert:
                break
            }
        }
        return tally
    }

    /// Runs compiled steps at node `x`, `weight` times per request of the flow. Returns the mean
    /// seconds one run takes and the seconds it holds x's slot.
    private func run(_ program: [Work], at x: Int, weight: Double, flow: Int, wait: [Double],
                     into tally: inout Tally) -> (elapsed: Double, held: Double) {
        var elapsed = 0.0, held = 0.0, alive = 1.0
        let async = nodes[x].async
        for work in program {
            switch work {
            case .work(let mean, let p):
                let chance = p * alive
                elapsed += chance * mean
                held += chance * mean
            case .call(let call):
                let chance = call.p * alive
                let callee = nodes[call.target]
                let calls = weight * chance * call.attempts
                var attempt = 2 * call.latency
                if callee.down {
                    tally.add(call.target, flow, visits: calls, demand: 0, source: call.source)
                } else {
                    let inner = run(call.nested, at: call.target, weight: calls, flow: flow, wait: wait, into: &tally)
                    tally.add(call.target, flow, visits: calls, demand: calls * (callee.service + inner.held), source: call.source)
                    attempt += wait[call.target] + callee.service + inner.elapsed
                }
                var time = call.attempts * attempt + call.backoff
                var holding = async ? 0 : time
                if call.missChance > 0 {
                    let miss = run(call.miss, at: x, weight: weight * chance * call.missChance, flow: flow, wait: wait, into: &tally)
                    time += call.missChance * miss.elapsed
                    holding += call.missChance * miss.held
                }
                elapsed += chance * time
                held += chance * holding
                if !call.optional { alive *= 1 - call.p * call.fail }
            case .publish(let publish):
                let chance = publish.p * alive
                let buffer = nodes[publish.target]
                let sends = weight * chance * publish.attempts
                let ingress = buffer.down ? 0 : buffer.service
                tally.add(publish.target, flow, visits: sends, demand: sends * ingress, source: publish.source)
                tally.published[publish.target * flowCount + flow] += weight * chance * (1 - publish.fail)
                let time = publish.attempts * (2 * publish.latency + ingress) + publish.backoff
                elapsed += chance * time
                held += chance * (async ? 0 : time)
                if !publish.optional { alive *= 1 - publish.p * publish.fail }
            case .parallel(let branches, let p, let optional, let fail):
                let chance = p * alive
                var slowest = 0.0, longest = 0.0
                for branch in branches {
                    let result = run(branch, at: x, weight: weight * chance, flow: flow, wait: wait, into: &tally)
                    slowest = max(slowest, result.elapsed)
                    longest = max(longest, result.held)
                }
                elapsed += chance * slowest
                held += chance * longest
                if !optional { alive *= 1 - p * fail }
            }
        }
        return (elapsed, held)
    }

    /// Mean seconds a call waits for a slot at `node`: M/M/c from 70% utilization, 0 below.
    func queueWait(_ node: Int, demand: Double, arrivals: Double) -> Double {
        let info = nodes[node]
        guard !info.unlimited, !info.blocked, arrivals > 0, demand > 0 else { return 0 }
        let servers = Double(info.slots)
        let utilization = demand / servers
        let room = Double(info.params.queue ?? 0)
        guard utilization >= 0.7, room > 0 else { return 0 }
        let hold = demand / arrivals
        let full = room * hold / servers
        guard utilization < 1 else { return full }
        return min(full, Queueing.wait(servers: info.slots, load: demand, hold: hold))
    }

    func utilization(_ node: Int, _ evaluation: Evaluation) -> Double {
        let info = nodes[node]
        if info.unlimited { return 0 }
        if info.blocked { return evaluation.arrivals[node] > 0 ? 1 : 0 }
        return evaluation.demand[node] / Double(info.slots)
    }

    // MARK: Solving

    /// The largest rate of flow `f`, others held, before a server its steps reach hits 100%.
    func maxRate(_ f: Int, current: Evaluation) -> (rate: Double?, bottleneck: Int?) {
        if case .consumer(_, let by) = roles[f], nodes[by].blocked { return (0, by) }
        let watched = syncNodes[f].sorted().filter { !nodes[$0].unlimited && current.tally.visits[$0 * flowCount + f] > 0 }
        guard !watched.isEmpty else { return (nil, nil) }
        if let blocked = watched.first(where: { nodes[$0].blocked }) { return (0, blocked) }
        var flags = fixed
        flags[f] = true
        func rates(_ x: Double) -> [Double] {
            var rates = configured
            rates[f] = x
            return rates
        }
        func peak(_ x: Double) -> Double {
            let evaluation = evaluate(rates(x), fixed: flags)
            return watched.map { utilization($0, evaluation) }.max() ?? 0
        }
        if peak(0) >= 1 { return (0, attribute(rates(0), fixed: flags, among: watched)) }
        let now = current.rates[f]
        let busiest = watched.map { utilization($0, current) }.max() ?? 0
        var guess = now > 0 && busiest > 0 ? now / busiest : 1
        if !guess.isFinite || guess <= 0 { guess = 1 }
        var low = 0.0, high = guess
        if peak(guess) < 1 {
            low = guess
            high = guess * 2
            while peak(high) < 1 {
                low = high
                high *= 2
                if high > 1e9 { return (nil, nil) }
            }
        } else {
            while low == 0, high > 1e-9 {
                let half = high / 2
                if peak(half) < 1 { low = half } else { high = half }
            }
        }
        for _ in 0..<60 where high - low > 1e-6 * high {
            let middle = (low + high) / 2
            if peak(middle) < 1 { low = middle } else { high = middle }
        }
        return (low, attribute(rates(high), fixed: flags, among: watched))
    }

    /// The scale of `base` (every rate × the same factor) at which the first node saturates, up to `horizon`.
    func saturation(_ base: [Double], horizon: Double = 100) -> (scale: Double, node: Int)? {
        let candidates = nodes.indices.filter { !nodes[$0].unlimited && !nodes[$0].blocked }
        guard !candidates.isEmpty, base.contains(where: { $0 > 0 }) else { return nil }
        func peak(_ scale: Double) -> Double {
            let evaluation = evaluate(base.map { $0 * scale })
            return candidates.map { utilization($0, evaluation) }.max() ?? 0
        }
        guard peak(horizon) >= 1 else { return nil }
        var low = 0.0, high = horizon
        for _ in 0..<80 where high - low > 1e-6 * high {
            let middle = (low + high) / 2
            if peak(middle) < 1 { low = middle } else { high = middle }
        }
        guard let node = attribute(base.map { $0 * high }, fixed: fixed, among: candidates) else { return nil }
        return (low, node)
    }

    /// Which node to blame at a saturating rate: the busiest candidate, or a node it waits on that is
    /// busier on its own service time. A caller near a saturated callee fills up from the callee's
    /// queue; scaling the callee is the fix.
    func attribute(_ rates: [Double], fixed flags: [Bool], among candidates: [Int]) -> Int? {
        let full = evaluate(rates, fixed: flags)
        guard let saturated = candidates.max(by: { utilization($0, full) < utilization($1, full) }) else { return nil }
        let service = evaluate(rates, fixed: flags, queueing: false)
        // An async node frees its slot while it waits, so it fills on its own service time.
        let callees = nodes[saturated].async ? [] : waitsOn[saturated].sorted()
        let suspects = [saturated] + callees.filter { !nodes[$0].unlimited && !nodes[$0].blocked }
        return suspects.max { utilization($0, service) < utilization($1, service) }
    }

    /// For each flow, the source flows its traffic comes from (fractions summing to 1).
    func origins(_ evaluation: Evaluation) -> [[Int: Double]] {
        var result = Array(repeating: [Int: Double](), count: flowCount)
        for f in order {
            switch roles[f] {
            case .source: result[f] = [f: 1]
            case .consumer(let buffer, _):
                if fixed[f] {
                    result[f] = [f: 1]
                    continue
                }
                var total = 0.0
                var mix: [Int: Double] = [:]
                for g in roles.indices where g != f {
                    let weight = evaluation.rates[g] * evaluation.tally.published[buffer * flowCount + g]
                    guard weight > 0 else { continue }
                    total += weight
                    for (origin, fraction) in result[g] { mix[origin, default: 0] += weight * fraction }
                }
                result[f] = total > 0 ? mix.mapValues { $0 / total } : [:]
            case .inert: break
            }
        }
        return result
    }

    /// The flow whose traffic (followed back through buffers) makes up most of a node's demand.
    func primaryFlow(of node: Int, _ evaluation: Evaluation) -> Int? {
        let origins = origins(evaluation)
        var credit: [Int: Double] = [:]
        for f in roles.indices {
            let busy = evaluation.rates[f] * evaluation.tally.demand[node * flowCount + f]
            guard busy > 0 else { continue }
            for (origin, fraction) in origins[f] { credit[origin, default: 0] += busy * fraction }
        }
        return credit.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
    }
}

enum Queueing {
    /// Mean wait for a slot in an M/M/c queue: Erlang C × hold / (c − load). Exact (Erlang B
    /// recurrence) up to 2,000 servers; above that, Sakasegawa's approximation of the queue length.
    static func wait(servers: Int, load: Double, hold: Double) -> Double {
        let c = Double(servers)
        guard servers > 0, load > 0, hold > 0 else { return 0 }
        guard load < c else { return .infinity }
        if servers > 2000 {
            let utilization = load / c
            let queued = pow(utilization, (2 * (c + 1)).squareRoot()) / (1 - utilization)
            return queued * hold / load
        }
        var blocking = 1.0
        for k in 1...servers { blocking = load * blocking / (Double(k) + load * blocking) }
        let delayed = blocking / (1 - load / c * (1 - blocking))
        return delayed * hold / (c - load)
    }
}

@MainActor
extension Simulation {
    /// The running sim as analysis inputs: current rates, parameters, slow factors, down nodes,
    /// redirects and link latencies.
    func analysisInputs() -> AnalysisInputs {
        var inputs = AnalysisInputs()
        inputs.parentRate = parentRate
        for flow in flows where flow.source != nil { inputs.liveRates[flow.flow.id] = rate(for: flow) }
        for runtime in nodes {
            let id = runtime.node.id
            inputs.params[id] = runtime.params
            if runtime.slow != 1 { inputs.slow[id] = runtime.slow }
            if !runtime.up { inputs.down.insert(id) }
            if let redirect = runtime.redirect { inputs.redirects[id] = nodes[redirect].node.id }
        }
        for edge in edges { inputs.edgeLatency[edge.id] = edge.latency.mean + edge.extra }
        return inputs
    }
}
