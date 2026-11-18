import Foundation

// Recent-trend accessors over the engine's 0.25 s metric samples, and exact busy time per node.
// The Pressure analysis reads them for live culprits and to compare the static model with the engine.

/// How a metric moved over a recent window of its 0.25 s samples.
public struct MetricTrend: Sendable {
    public var latest: Double        // the newest sample
    public var mean: Double          // mean over the window
    public var earlier: Double       // mean of the oldest second of the window
    public var recent: Double        // mean of the newest second of the window
    public var perSecond: Double     // (recent − earlier) per second between the two
    public var seconds: Double       // window actually covered (shorter right after a reset)
}

@MainActor
public extension Simulation {
    /// The newest samples of a metric over the last `seconds` (one per 0.25 s, at most 60 s), oldest first.
    func recent(_ key: MetricKey, seconds: Double) -> [Double] {
        guard seconds.isFinite, seconds > 0 else { return [] }
        return histories[key]?.last(Int((min(seconds, 60) * 4).rounded(.up))) ?? []
    }

    /// The trend of a metric over the last `seconds`; nil until two samples exist.
    func trend(_ key: MetricKey, seconds: Double = 3) -> MetricTrend? {
        let samples = recent(key, seconds: seconds)
        guard samples.count >= 2, let latest = samples.last else { return nil }
        let edge = max(1, min(4, samples.count / 2))
        let earlier = samples.prefix(edge).reduce(0, +) / Double(edge)
        let recent = samples.suffix(edge).reduce(0, +) / Double(edge)
        let span = Double(samples.count - edge) * 0.25
        return MetricTrend(latest: latest, mean: samples.reduce(0, +) / Double(samples.count), earlier: earlier,
                           recent: recent, perSecond: span > 0 ? (recent - earlier) / span : 0,
                           seconds: Double(samples.count) * 0.25)
    }

    /// Slot-seconds of work a node has done since reset: busy slots integrated over sim time.
    /// Two readings give its exact mean utilization in between: Δbusy / (Δt × slots).
    func busySeconds(_ node: String) -> Double {
        guard let index = topology.nodeIndex[node] else { return 0 }
        let runtime = nodes[index]
        return runtime.busyArea + Double(runtime.busy) * (now - runtime.busySince)
    }
}
