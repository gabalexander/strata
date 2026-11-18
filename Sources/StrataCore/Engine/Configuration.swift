import Foundation

enum SimulationLimits {
    static let rate = 10_000.0
    static let send = 10_000
    static let replicas = 64
    static let concurrency = 100_000
    static let capacity = 1_000_000
    static let prefetch = 100_000
    static let queue = 1_000_000

    static let nodeCounts = ["replicas": replicas, "concurrency": concurrency,
                             "capacity": capacity, "prefetch": prefetch, "queue": queue]
}

enum NodeConfiguration {
    static func effective(_ node: Node, topicConsumer: Bool = false) -> NodeParams {
        let defaults: (Dist, Int, Int)
        switch node.kind {
        case .gateway: defaults = (.jitter(0.001), 256, 1000)
        case .service: defaults = (.jitter(0.020), 8, 100)
        case .worker: defaults = (.jitter(0.050), 4, 100)
        case .function: defaults = (.jitter(0.030), 100, 0)
        case .database: defaults = (.jitter(0.005), 20, 200)
        case .cache: defaults = (.jitter(0.0005), 1000, 1000)
        case .search: defaults = (.jitter(0.015), 16, 200)
        case .store: defaults = (.jitter(0.030), 1000, 1000)
        case .external: defaults = (.jitter(0.150), 1000, 1000)
        case .cdn: defaults = (.jitter(0.005), 10000, 10000)
        case .dns: defaults = (.jitter(0.002), 1000, 1000)
        case .llm: defaults = (.lognormal(p50: 0.8, p99: 4), 4, 100)
        case .vector: defaults = (.jitter(0.010), 32, 200)
        case .port, .client, .user, .cron: defaults = (.fixed(0), .max, .max)
        case .queue, .topic: defaults = (.fixed(0.0002), 0, 0)
        case .note: defaults = (.fixed(0), 0, 0)
        }
        var params = node.params
        params.latency = params.latency ?? defaults.0
        params.concurrency = params.concurrency.map { min(SimulationLimits.concurrency, max(0, $0)) } ?? defaults.1
        params.queue = params.queue.map { min(SimulationLimits.queue, max(0, $0)) } ?? defaults.2
        params.replicas = min(SimulationLimits.replicas, max(1, params.replicas ?? 1))
        params.errors = params.errors ?? 0
        params.timeout = params.timeout ?? 0
        params.retries = params.retries ?? 0
        params.backoff = params.backoff ?? 0.1
        params.async = params.async ?? false
        params.capacity = min(SimulationLimits.capacity, params.capacity ?? 10000)
        params.overflow = params.overflow ?? (node.kind == .topic ? .dropOldest : .reject)
        params.ttl = params.ttl ?? 0
        params.dlq = params.dlq ?? ""
        params.prefetch = min(SimulationLimits.prefetch, params.prefetch ?? 10)
        params.ack = params.ack ?? .manual
        params.onError = params.onError ?? (node.kind == .topic || topicConsumer ? .retry : .requeue)
        params.maxDeliveries = params.maxDeliveries ?? 5
        params.hitRate = params.hitRate ?? 0.9
        return params
    }

    static func value(_ param: String, in p: NodeParams) -> Value? {
        switch param {
        case "latency": p.latency.map { .number($0.mean) }
        case "concurrency": p.concurrency.map { .number(Double($0)) }
        case "replicas": p.replicas.map { .number(Double($0)) }
        case "queue": p.queue.map { .number(Double($0)) }
        case "errors": p.errors.map(Value.number)
        case "timeout": p.timeout.map(Value.number)
        case "retries": p.retries.map { .number(Double($0)) }
        case "backoff": p.backoff.map(Value.number)
        case "async": p.async.map(Value.bool)
        case "capacity": p.capacity.map { .number(Double($0)) }
        case "overflow": p.overflow.map { .string($0.rawValue) }
        case "ttl": p.ttl.map(Value.number)
        case "dlq": p.dlq.map(Value.string)
        case "prefetch": p.prefetch.map { .number(Double($0)) }
        case "ack": p.ack.map { .string($0.rawValue) }
        case "onError": p.onError.map { .string($0.rawValue) }
        case "maxDeliveries": p.maxDeliveries.map { .number(Double($0)) }
        case "hitRate": p.hitRate.map(Value.number)
        default: nil
        }
    }

    static func apply(_ value: Value, to param: String, in p: inout NodeParams) -> Bool {
        switch (param, value) {
        case ("async", .bool(let flag)): p.async = flag
        case ("ack", .string(let name)):
            guard let ack = AckMode(rawValue: name) else { return false }
            p.ack = ack
        case ("overflow", .string(let name)):
            guard let mode = Overflow(rawValue: name) else { return false }
            p.overflow = mode
        case ("onError", .string(let name)):
            guard let mode = OnError(rawValue: name) else { return false }
            p.onError = mode
        case ("dlq", .string(let id)): p.dlq = id
        case ("timeout", .string(let text)), ("backoff", .string(let text)), ("ttl", .string(let text)):
            guard let seconds = try? Syntax.duration(text) else { return false }
            return apply(.number(seconds), to: param, in: &p)
        case ("errors", .string(let text)), ("hitRate", .string(let text)):
            guard let probability = try? Syntax.probability(text) else { return false }
            return apply(.number(probability), to: param, in: &p)
        case (_, .number(let number)) where number.isFinite && number >= 0:
            switch param {
            case "latency": p.latency = .fixed(number)
            case "errors": p.errors = min(1, number)
            case "hitRate": p.hitRate = min(1, number)
            case "timeout": p.timeout = number
            case "backoff": p.backoff = number
            case "ttl": p.ttl = number
            default:
                guard let integer = Int(exactly: number.rounded(.towardZero)) else { return false }
                switch param {
                case "concurrency": p.concurrency = integer
                case "replicas": p.replicas = max(1, integer)
                case "queue": p.queue = integer
                case "retries": p.retries = integer
                case "capacity": p.capacity = integer
                case "prefetch": p.prefetch = integer
                case "maxDeliveries": p.maxDeliveries = max(1, integer)
                default: return false
                }
            }
        default: return false
        }
        return true
    }
}
