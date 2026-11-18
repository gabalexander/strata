import Foundation

/// Live numbers for one op of the level: every step that names it records its result here.
@MainActor
final class OpRuntime {
    static let metrics = ["rate", "errors", "p50", "p99"]

    let referenced: Bool
    var total = 0
    var rate = RecentRate()
    var errors = RecentRate()
    var latency = RecentLatency()
    var history = Array(repeating: SeriesHistory(), count: OpRuntime.metrics.count)

    init(referenced: Bool) { self.referenced = referenced }
}

@MainActor
extension Simulation {
    /// One finished execution of a step that names op `index`: `latency` from step start to its result.
    func recordOp(_ index: Int, latency: Double, failed: Bool) {
        let op = opRuntimes[index]
        op.total += 1
        op.rate.add(at: now)
        if failed { op.errors.add(at: now) }
        op.latency.add(max(0, latency), at: now)
    }

    func opIndex(node: String, op: String) -> Int? {
        topology.opIndex["\(node)/\(op)"]
    }

    func opState(_ index: Int) -> OpMetrics {
        let runtime = opRuntimes[index]
        var metrics = OpMetrics()
        metrics.referenced = runtime.referenced
        guard runtime.referenced else { return metrics }
        metrics.rate = runtime.rate.value(at: now)
        metrics.errors = runtime.errors.value(at: now)
        let percentiles = runtime.latency.percentiles(at: now)
        metrics.p50 = percentiles.p50
        metrics.p99 = percentiles.p99
        metrics.total = runtime.total
        return metrics
    }

    func sampleOps() {
        for index in opRuntimes.indices where opRuntimes[index].referenced {
            let state = opState(index)
            let values = [state.rate, state.errors, state.p50 ?? 0, state.p99 ?? 0]
            for (metric, value) in values.enumerated() { opRuntimes[index].history[metric].add(value) }
        }
    }

    /// Rows for `report()`: referenced ops only, in node order.
    func opRows(number: (Double) -> String, ms: (Double?) -> String) -> [[String]] {
        var rows = [["Op", "Node", "rate/s", "err/s", "p50 ms", "p99 ms"]]
        for (index, key) in topology.ops.enumerated() where key.referenced {
            let state = opState(index)
            rows.append([key.op, key.node, number(state.rate), number(state.errors), ms(state.p50), ms(state.p99)])
        }
        return rows
    }
}
