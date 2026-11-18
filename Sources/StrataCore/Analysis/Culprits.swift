import Foundation

// Live trouble spots in a running simulation, worst first (docs/manifest.md, Culprits). Reads only
// the engine's recent metrics (5 s rate windows, 10 s latency windows, 0.25 s samples), so it is
// cheap enough for the Pressure tab to call four times a second.

@MainActor
extension Simulation {
    func liveCulprits() -> [Culprit] {
        var found: [(culprit: Culprit, score: Double)] = []
        func add(_ kind: Culprit.Kind, _ severity: Culprit.Severity, _ subject: String, _ message: String, _ magnitude: Double) {
            let weight: Double = switch kind {
            case .down: 8
            case .sloBreach: 7
            case .saturated: 6
            case .timeouts: 5
            case .errors: 4
            case .queueing: 3
            case .lagging: 2
            case .breakerOpen: 1
            }
            let culprit = Culprit(kind: kind, severity: severity, subject: subject, message: message)
            found.append((culprit, weight * 10 + min(9.99, max(0, magnitude.isFinite ? magnitude : 9.99))))
        }
        /// Rising over the window by more than noise: at least one item and 5% of where it started.
        func growing(_ trend: MetricTrend?) -> MetricTrend? {
            guard let trend, trend.recent - trend.earlier >= max(1, 0.05 * trend.earlier) else { return nil }
            return trend
        }

        for runtime in nodes {
            let node = runtime.node
            let label = node.label
            switch node.kind.role {
            case .annotation: continue
            case .source:
                if !runtime.up { add(.down, .critical, node.id, "\(label) is down: its flows can't start.", 9) }
                continue
            case .buffer, .server: break
            }
            guard runtime.up else {
                let effect = node.kind.role == .buffer ? "publishes to it fail and its consumers starve"
                    : "calls to it fail with connection refused"
                add(.down, .critical, node.id, "\(label) is down: \(effect).", 9)
                continue
            }
            if let buffer = runtime.buffer {
                let capacity = max(1, runtime.params.capacity ?? 10_000)
                // A backlog worth less than a second of the consumers' work is normal jitter.
                var drained = 0.0
                for flow in buffer.consumers { drained += flows[flow].ok.value(at: now) + flows[flow].failed.value(at: now) }
                let floor = max(10, Int(drained.rounded(.up)))
                if node.kind == .topic {
                    guard let trend = growing(trend(.node(node.id, .lag), seconds: 5)) else { continue }
                    var worst: (flow: Int, lag: Int)?
                    for flow in buffer.consumers {
                        guard let group = flows[flow].group, group.lag > (worst?.lag ?? 0) else { continue }
                        worst = (flow, group.lag)
                    }
                    guard let worst, worst.lag >= floor, let consumer = flows[worst.flow].consumer else { continue }
                    add(.lagging, worst.lag * 2 >= capacity ? .critical : .warn, node.id,
                        "\(label): \(nodes[consumer].node.label) is \(Format.grouped(Double(worst.lag))) messages behind, falling back \(Format.rate(trend.perSecond))/s.",
                        Double(worst.lag) / Double(capacity) * 10)
                } else {
                    let depth = buffer.messages.count
                    guard depth >= floor, let trend = growing(trend(.node(node.id, .depth), seconds: 5)) else { continue }
                    add(.lagging, depth * 2 >= capacity ? .critical : .warn, node.id,
                        "\(label): \(Format.grouped(Double(depth))) messages waiting, growing \(Format.rate(trend.perSecond))/s.",
                        Double(depth) / Double(capacity) * 10)
                }
                continue
            }
            let slots = runtime.slots
            if slots > 0 {
                let queued = runtime.waiting.count + runtime.deliveryQueued
                let samples = recent(.node(node.id, .util), seconds: 2)
                let utilization = samples.isEmpty ? Double(runtime.busy) / Double(slots) : samples.reduce(0, +) / Double(samples.count)
                if utilization >= 0.75 {
                    let busy = min(slots, Int((utilization * Double(slots)).rounded()))
                    let unit = switch node.kind {
                    case .database, .cache, .search, .vector, .store: "connections"
                    case .worker: "workers"
                    default: "slots"
                    }
                    add(.saturated, utilization >= 0.9 ? .critical : .warn, node.id,
                        "\(label): \(busy)/\(slots) \(unit) busy" + (queued > 0 ? ", \(queued) queued." : "."), utilization * 5 + 4)
                }
                let room = runtime.params.queue ?? 0
                let full = room > 0 && queued >= room
                if full || queued >= 2 && (growing(trend(.node(node.id, .queued))).map { $0.recent >= 2 } ?? false) {
                    let change = trend(.node(node.id, .queued)).map { Int(($0.recent - $0.earlier).rounded()) } ?? 0
                    let message = full ? "\(label): waiting room full (\(queued)/\(room)), so new calls get 503."
                        : "\(label): \(queued) requests waiting for a slot, up \(change) in 3 s."
                    add(.queueing, full || queued * 2 >= room ? .critical : .warn, node.id, message,
                        Double(queued) / Double(max(1, room)) * 10)
                }
            }
            let injected = runtime.params.errors ?? 0
            let failures = runtime.errors.value(at: now)
            if injected > 0, failures > 0 {
                add(.errors, injected >= 0.2 ? .critical : .warn, node.id,
                    "\(label): \(Format.percent(injected)) of its handling fails, \(Format.rate(failures)) errors/s.", injected * 10)
            }
        }

        for edge in edges where edge.openCircuits > 0 {
            add(.breakerOpen, .warn, edge.id,
                "Breaker open on \(nodes[edge.from].node.label) → \(nodes[edge.to].node.label): calls fail fast until the cooldown ends.", 1)
        }

        for runtime in flows {
            let flow = runtime.flow
            let started = runtime.started.value(at: now)
            let ok = runtime.ok.value(at: now), failed = runtime.failed.value(at: now)
            let timeouts = runtime.timeouts.value(at: now)
            let finished = ok + failed
            let failing = finished > 0 ? failed / finished : 0
            if timeouts >= 0.2 {
                let share = started > 0 ? min(1, timeouts / started) : 1
                add(.timeouts, share >= 0.1 ? .critical : .warn, flow.id,
                    "\(flow.id): \(Format.rate(timeouts)) timeouts/s at \(Format.rate(started)) requests/s.", share * 10)
            }
            if failed >= 0.2, failing >= 0.01 {
                add(.errors, failing >= 0.1 ? .critical : .warn, flow.id,
                    "\(flow.id): \(Format.percent(failing)) of requests fail (\(Format.rate(failed))/s).", failing * 10)
            }
            guard let slo = flow.slo else { continue }
            var breaches: [String] = []
            var worst = 0.0
            if slo.p50 != nil || slo.p99 != nil {
                let latency = runtime.latency.percentiles(at: now)
                for (name, target, value) in [("p50", slo.p50, latency.p50), ("p99", slo.p99, latency.p99)] {
                    guard let target, let value, value > target else { continue }
                    breaches.append("\(flow.id) \(name) \(Format.duration(value)) > SLO \(Format.duration(target))")
                    worst = max(worst, target > 0 ? value / target : 10)
                }
            }
            if let target = slo.errors, finished > 0, failing > target {
                breaches.append("\(flow.id) errors \(Self.ratio(failing)) > SLO \(Self.ratio(target))")
                worst = max(worst, target > 0 ? failing / target : 10)
            }
            if !breaches.isEmpty { add(.sloBreach, .critical, flow.id, breaches.joined(separator: "; ") + ".", worst) }
        }

        var seen: Set<String> = []
        return found.sorted { a, b in
            a.culprit.severity != b.culprit.severity ? a.culprit.severity > b.culprit.severity : a.score > b.score
        }.map(\.culprit).filter { seen.insert($0.id).inserted }
    }

    /// An error ratio with enough digits for SLOs like 0.1%.
    private static func ratio(_ value: Double) -> String {
        let percent = value * 100
        if percent >= 10 || percent == percent.rounded() { return String(format: "%.0f%%", percent) }
        return percent >= 1 ? String(format: "%.1f%%", percent) : String(format: "%.2g%%", percent)
    }
}
