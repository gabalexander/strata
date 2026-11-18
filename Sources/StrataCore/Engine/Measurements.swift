import Foundation

struct RecentRate {
    private static let buckets = 500
    private var counts: [Int] = []
    private var tick = 0
    private var total = 0

    private mutating func advance(to time: Double) {
        let next = Int(time * 100 + 1e-8)
        guard next > tick else { return }
        defer { tick = next }
        guard total > 0 else { return }
        let distance = next - tick
        if distance >= Self.buckets {
            counts = Array(repeating: 0, count: Self.buckets)
            total = 0
        } else {
            for offset in 1...distance {
                let index = (tick + offset) % Self.buckets
                total -= counts[index]
                counts[index] = 0
            }
        }
    }

    mutating func add(at time: Double) {
        if counts.isEmpty { counts = Array(repeating: 0, count: Self.buckets) }
        advance(to: time)
        counts[tick % Self.buckets] += 1
        total += 1
    }

    mutating func value(at time: Double) -> Double {
        advance(to: time)
        return Double(total) / max(0.01, min(5, time))
    }
}

struct RecentLatency {
    private struct Sample {
        let time: Double
        let bin: Int
    }

    // Six mantissa bits bound the bin width to about 1.6% without sorting samples on the render path.
    private static let firstBin = Int(Double(0.000_000_001).bitPattern >> 46)
    private static let binCount = 4096
    private static let limit = 16_384

    private var samples = FIFO<Sample>()
    private var counts: [Int] = []
    private var representatives: [Double] = []
    private var low = binCount - 1
    private var high = 0

    mutating func add(_ latency: Double, at time: Double) {
        if counts.isEmpty {
            counts = Array(repeating: 0, count: Self.binCount)
            representatives = Array(repeating: 0, count: Self.binCount)
        }
        expire(at: time)
        if samples.count == Self.limit, let old = samples.pop() { counts[old.bin] -= 1 }
        let bin = min(Self.binCount - 1, max(0, Int(latency.bitPattern >> 46) - Self.firstBin))
        samples.append(Sample(time: time, bin: bin))
        counts[bin] += 1
        representatives[bin] = latency
        low = min(low, bin)
        high = max(high, bin)
    }

    private mutating func expire(at time: Double) {
        while let sample = samples.first, sample.time <= time - 10 {
            _ = samples.pop()
            counts[sample.bin] -= 1
        }
    }

    mutating func percentiles(at time: Double) -> (p50: Double?, p95: Double?, p99: Double?) {
        expire(at: time)
        let count = samples.count
        guard count > 0 else {
            low = Self.binCount - 1
            high = 0
            return (nil, nil, nil)
        }
        while counts[low] == 0 { low += 1 }
        while counts[high] == 0 { high -= 1 }
        let middle = (count + 1) / 2
        let upper = (count * 95 + 99) / 100
        let tail = (count * 99 + 99) / 100
        var seen = 0
        var p50: Double?
        var p95: Double?
        for bin in low...high {
            seen += counts[bin]
            if p50 == nil, seen >= middle { p50 = representatives[bin] }
            if p95 == nil, seen >= upper { p95 = representatives[bin] }
            if seen >= tail { return (p50, p95, representatives[bin]) }
        }
        preconditionFailure("Latency sample counts do not match the sample queue")
    }
}

struct SeriesHistory {
    private var values: [Double] = []
    private var next = 0

    mutating func add(_ value: Double) {
        if values.count < 240 { values.append(value) } else { values[next] = value }
        next = (next + 1) % 240
    }

    var ordered: [Double] {
        guard values.count == 240, next > 0 else { return values }
        return Array(values[next...] + values[..<next])
    }
}

struct InTransit {
    let id: Int
    let traffic: Traffic
    let edge: Int
    let start: Double
    let end: Double
    let kind: TokenView.Kind
    let reverse: Bool
    let label: String?
    let reply: Attempt?
}

struct FloodBatch {
    var count = 0
    var detail: Int?
    var lastTime = 0.0
}

enum Flood: CaseIterable {
    case failed, timeout, overflow, expired, retention, lost

    func summary(_ count: Int) -> String {
        switch self {
        case .failed: "\(count) requests failed in the last second"
        case .timeout: "\(count) requests timed out in the last second"
        case .overflow: "\(count) buffer overflows in the last second"
        case .expired: "\(count) messages expired in the last second"
        case .retention: "\(count) messages fell behind retention in the last second"
        case .lost: "\(count) deliveries were lost in the last second"
        }
    }
}

@MainActor
extension Simulation {
    func note(_ kind: Flood, _ text: @autoclosure () -> String, node: Int? = nil,
              visible: Bool = true) {
        let second = Int(now)
        if floodSecond != second {
            flushLog()
            floodSecond = second
        }
        if floods.isEmpty { schedule(.flushLog(second), at: Double(second) + 1) }
        var batch = floods[kind] ?? FloodBatch()
        batch.count += 1
        batch.lastTime = now
        if visible, batch.detail == nil {
            append(text(), .warn, node: node)
            batch.detail = logSequence
        }
        floods[kind] = batch
    }

    func flushLog() {
        for kind in Flood.allCases {
            guard let batch = floods[kind] else { continue }
            let summary = kind.summary(batch.count)
            if let id = batch.detail {
                if batch.count > 1 { updateLog(id, withSummary: summary) }
            } else {
                append(summary, .warn, time: batch.lastTime)
            }
        }
        floods.removeAll(keepingCapacity: true)
    }

    func recordFailure(at index: Int) {
        let node = nodes[index]
        node.errors.add(at: now)
        node.lastFailure = now
    }

    func addToken(_ traffic: Traffic, edge: Int, duration: Double, kind: TokenView.Kind,
                  label: String?, reverse: Bool = false, reply: Attempt? = nil) {
        guard traffic.visible, duration > 0 else { return }
        if tokens.count >= 800 { tokens.removeAll { $0.end <= now } }
        guard tokens.count < 800 else { return }
        tokenSequence += 1
        tokens.append(InTransit(id: tokenSequence, traffic: traffic, edge: edge, start: now, end: now + duration,
                                kind: kind, reverse: reverse, label: label, reply: reply))
    }

    func nodeState(_ index: Int) -> NodeState {
        let runtime = nodes[index]
        let params = runtime.params
        var state = NodeState()
        if !runtime.up { state.health = .down }
        else if runtime.slow != 1 { state.health = .slow }
        else if params.errors! > 0 { state.health = .failing }
        state.replicas = params.replicas!
        state.busy = runtime.busy
        state.slots = runtime.slots
        state.queued = runtime.waiting.count + runtime.deliveryQueued
        if let buffer = runtime.buffer {
            state.depth = buffer.messages.count
            state.lost = buffer.lost
            state.unacked = buffer.unacked
            state.held = buffer.order.elements.lazy.compactMap { buffer.messages[$0]?.traffic }
                .prefix(12).map { flows[$0.flow].color }
            for flow in buffer.consumers {
                guard let group = flows[flow].group, let index = flows[flow].consumer else { continue }
                let id = nodes[index].node.id
                state.lag[id, default: 0] += group.lag
                state.groupLag[flows[flow].flow.id] = group.lag
            }
        }
        state.throughput = runtime.completed.value(at: now)
        state.arrivals = runtime.arrivals.value(at: now)
        state.errors = runtime.errors.value(at: now)
        let percentiles = runtime.latency.percentiles(at: now)
        state.p50 = percentiles.p50
        state.p99 = percentiles.p99
        if state.slots > 0 { state.utilization = min(1, Double(state.busy) / Double(state.slots)) }
        state.redirectedTo = runtime.redirect.map { nodes[$0].node.id }
        state.lastFailure = runtime.lastFailure
        return state
    }

    func flowState(_ index: Int) -> FlowMetrics {
        let runtime = flows[index]
        var result = FlowMetrics()
        result.configuredRate = rate(for: runtime)
        result.started = runtime.started.value(at: now)
        result.ok = runtime.ok.value(at: now)
        result.failed = runtime.failed.value(at: now)
        result.retries = runtime.retries.value(at: now)
        result.timeouts = runtime.timeouts.value(at: now)
        let percentiles = runtime.latency.percentiles(at: now)
        result.p50 = percentiles.p50
        result.p95 = percentiles.p95
        result.p99 = percentiles.p99
        result.inFlight = runtime.inFlight
        result.totalOK = runtime.totalOK
        result.totalFailed = runtime.totalFailed
        return result
    }

    func sampleMetrics() {
        for (index, node) in nodes.enumerated() {
            let state = nodeState(index)
            for metric in NodeMetric.allCases {
                let value: Double
                switch metric {
                case .inflight: value = Double(node.live.count - node.queuedCalls)
                case .queued: value = Double(state.queued)
                case .util: value = state.utilization
                case .throughput: value = state.throughput
                case .errors: value = state.errors
                case .p50: value = state.p50 ?? 0
                case .p99: value = state.p99 ?? 0
                case .depth: value = Double(state.depth)
                case .lag: value = Double(state.lag.values.reduce(0, +))
                }
                histories[.node(node.node.id, metric), default: SeriesHistory()].add(value)
            }
        }
        for (index, flow) in flows.enumerated() {
            let state = flowState(index)
            for metric in FlowMetric.allCases {
                let value: Double
                switch metric {
                case .rate: value = state.started
                case .ok: value = state.ok
                case .errors: value = state.failed
                case .p50: value = state.p50 ?? 0
                case .p99: value = state.p99 ?? 0
                case .retries: value = state.retries
                }
                histories[.flow(flow.flow.id, metric), default: SeriesHistory()].add(value)
            }
        }
        sampleOps()
    }
}
