import Foundation

struct InvalidValue: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

enum Syntax {
    static func isID(_ text: String) -> Bool {
        func alphanumeric(_ c: UInt8) -> Bool { (97...122).contains(c) || (48...57).contains(c) }
        guard let first = text.utf8.first, alphanumeric(first) else { return false }
        return text.utf8.dropFirst().allSatisfy { alphanumeric($0) || $0 == 45 || $0 == 95 }
    }

    static func id(_ text: String) throws -> String {
        guard isID(text) else { throw InvalidValue("invalid id '\(text)'; use lowercase letters, digits, underscores, or hyphens and start with a letter or digit") }
        return text
    }

    static func termID(_ text: String) throws -> String {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy({ isID(String($0)) }) else {
            throw InvalidValue("invalid term reference '\(text)'; use id or pack/id")
        }
        return text
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func number(_ text: String) -> Double? {
        guard text.utf8.allSatisfy({ (48...57).contains($0) || [43, 45, 46, 69, 101].contains($0) }),
              let value = Double(text), value.isFinite else { return nil }
        return value
    }

    static func bool(_ text: String) -> Bool? {
        switch text.lowercased() {
        case "true": true
        case "false": false
        default: nil
        }
    }

    static func value(_ text: String) -> Value {
        if let flag = bool(text) { return .bool(flag) }
        if let number = number(text) { return .number(number) }
        return .string(text)
    }

    static func duration(_ text: String) throws -> Double {
        for (unit, factor) in [("ms", 0.001), ("us", 0.000001), ("s", 1.0), ("m", 60.0)] where text.hasSuffix(unit) {
            if let raw = number(String(text.dropLast(unit.count))), raw >= 0, (raw * factor).isFinite {
                return raw * factor
            }
            break
        }
        if number(text) != nil { throw InvalidValue("a duration needs a unit; write \(text)ms, not \(text)") }
        throw InvalidValue("expected a nonnegative duration with a unit (us, ms, s, or m), such as 20ms")
    }

    static func distribution(_ text: String) throws -> Dist {
        let parts = words(text)
        if parts.count == 2 {
            if parts[0] == "fixed" { return .fixed(try duration(parts[1])) }
            if parts[0] == "exp" {
                let mean = try duration(parts[1])
                guard mean > 0 else { throw InvalidValue("an exponential mean must be greater than zero") }
                return .exponential(mean)
            }
        }
        if parts.count == 4, parts[0] == "p50", parts[2] == "p99" {
            let median = try duration(parts[1])
            let tail = try duration(parts[3])
            let distribution = Dist.lognormal(p50: median, p99: tail)
            guard median > 0, tail >= median, distribution.mean.isFinite else {
                throw InvalidValue("expected a positive p50 and a p99 at least as large as p50, with a finite mean")
            }
            return distribution
        }
        let bounds = text.components(separatedBy: "..")
        if bounds.count == 2 {
            let low = try duration(bounds[0].trimmingCharacters(in: .whitespaces))
            let high = try duration(bounds[1].trimmingCharacters(in: .whitespaces))
            guard low <= high, (low + high).isFinite else { throw InvalidValue("expected an ascending duration range (10ms..40ms) with a finite mean") }
            return .uniform(low, high)
        }
        if parts.count == 1 { return .jitter(try duration(parts[0])) }
        throw InvalidValue("expected a duration or distribution (20ms, fixed 20ms, 10ms..40ms, exp 20ms, or p50 20ms p99 400ms)")
    }

    static func rate(_ text: String) throws -> Rate {
        if text == "manual" { return .manual }
        if text == "parent" { return .parent }
        let parts = words(text)
        if parts.count == 2, parts[0] == "every" {
            let interval = try duration(parts[1])
            guard interval > 0, (1 / interval).isFinite else { throw InvalidValue("an arrival interval must be positive and yield a finite rate") }
            let minimum = 1 / SimulationLimits.rate
            // Converting a duration such as 100us may round down by one ULP.
            guard interval >= minimum.nextDown else { throw InvalidValue(rateLimitMessage) }
            return .every(max(minimum, interval))
        }
        for (unit, divisor) in [("/s", 1.0), ("/min", 60.0)] where text.hasSuffix(unit) {
            if let value = number(String(text.dropLast(unit.count))), value >= 0 {
                let rate = value / divisor
                guard rate <= SimulationLimits.rate else { throw InvalidValue(rateLimitMessage) }
                return .perSecond(rate)
            }
        }
        throw InvalidValue("expected a rate such as 10/s, 600/min, every 2s, manual, or parent")
    }

    static let rateLimitMessage = "a flow rate cannot exceed \(Int(SimulationLimits.rate))/s"

    static func probability(_ text: String) throws -> Double {
        let percent = text.hasSuffix("%")
        let raw = percent ? String(text.dropLast()) : text
        if let number = number(raw), (0...(percent ? 100.0 : 1.0)).contains(number) {
            return percent ? number / 100 : number
        }
        throw InvalidValue("expected a probability between 0 and 1 or between 0% and 100%")
    }

    static func binding(_ text: String, nodeOnly: Bool = false) throws -> Binding {
        let pieces = text.components(separatedBy: ".")
        guard pieces.count == 2, !pieces[1].isEmpty else {
            throw InvalidValue("expected a binding such as \(nodeOnly ? "mailer.prefetch" : "mailer.prefetch, checkout.rate, or api->db.loss")")
        }
        let ids = pieces[0].components(separatedBy: "->")
        if !nodeOnly, ids.count == 2 {
            return Binding(.edge(from: try id(ids[0]), to: try id(ids[1])), pieces[1])
        }
        let target = try id(pieces[0])
        return Binding(!nodeOnly && pieces[1] == "rate" ? .flow(target) : .node(target), pieces[1])
    }

    static func condition(_ text: String) throws -> Condition {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw InvalidValue("expected an insight condition such as '< 5', '1..10', or 'manual'") }
        for prefix in ["<=", ">=", "<", ">", "=="] where text.hasPrefix(prefix) {
            let rhs = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            guard !rhs.isEmpty else { throw InvalidValue("expected a value after '\(prefix)'") }
            if prefix == "==" { return .eq(value(rhs)) }
            guard let number = number(rhs) else { throw InvalidValue("expected a number after '\(prefix)'") }
            switch prefix {
            case "<=": return .le(number)
            case ">=": return .ge(number)
            case "<": return .lt(number)
            default: return .gt(number)
            }
        }
        let bounds = text.components(separatedBy: "..")
        if bounds.count > 1 {
            guard bounds.count == 2, let a = number(bounds[0].trimmingCharacters(in: .whitespaces)),
                  let b = number(bounds[1].trimmingCharacters(in: .whitespaces)), a <= b else {
                throw InvalidValue("expected an ascending condition range such as '1..10'")
            }
            return .between(a, b)
        }
        if let first = text.first, "=!".contains(first) { throw InvalidValue("use '==' for an equality condition") }
        return .eq(value(text))
    }
}

enum ParameterType {
    case distribution, duration, integer(min: Int, max: Int = .max), probability, bool, factor, nodeID, choices([String]), rate

    static let node: [String: ParameterType] = [
        "latency": .distribution, "concurrency": .integer(min: 1, max: SimulationLimits.concurrency),
        "replicas": .integer(min: 1, max: SimulationLimits.replicas), "queue": .integer(min: 0, max: SimulationLimits.queue),
        "errors": .probability, "timeout": .duration, "retries": .integer(min: 0),
        "backoff": .duration, "async": .bool, "capacity": .integer(min: 1, max: SimulationLimits.capacity),
        "overflow": .choices(Overflow.allCases.map(\.rawValue)), "ttl": .duration, "dlq": .nodeID,
        "prefetch": .integer(min: 0, max: SimulationLimits.prefetch), "ack": .choices(AckMode.allCases.map(\.rawValue)),
        "onError": .choices(OnError.allCases.map(\.rawValue)), "maxDeliveries": .integer(min: 1),
        "hitRate": .probability, "up": .bool, "slow": .factor,
    ]

    static func forBinding(_ binding: Binding) -> ParameterType? {
        switch binding.target {
        case .node: return node[binding.param]
        case .flow: return binding.param == "rate" ? .rate : nil
        case .edge:
            switch binding.param {
            case "latency": return .distribution
            case "loss": return .probability
            default: return nil
            }
        }
    }

    var allowsRange: Bool {
        switch self {
        case .bool, .nodeID, .choices: false
        default: true
        }
    }

    func validate(_ value: Value, range: Bool = false) throws {
        switch (self, value) {
        case (.duration, .string(let text)): _ = try Syntax.duration(text)
        case (.distribution, .string(let text)): _ = try Syntax.distribution(text)
        case (.duration, .number(let n)), (.distribution, .number(let n)):
            if !range { _ = try Syntax.duration(value.description) }
            if n < 0 { throw InvalidValue("expected a nonnegative duration") }
        case (.rate, .number(let n)):
            if n < 0 { throw InvalidValue("expected a nonnegative rate") }
            if n > SimulationLimits.rate { throw InvalidValue(Syntax.rateLimitMessage) }
        case (.rate, .string(let text)): _ = try Syntax.rate(text)
        case (.integer(let min, let max), .number(let n)) where Int(exactly: n).map((min...max).contains) == true: break
        case (.probability, .number(let n)) where (0...1).contains(n): break
        case (.probability, .string(let text)) where text.hasSuffix("%"): _ = try Syntax.probability(text)
        case (.bool, .bool): break
        case (.factor, .number(let n)) where n > 0: break
        case (.nodeID, .string(let text)): _ = try Syntax.id(text)
        case (.choices(let choices), .string(let text)) where choices.contains(text): break
        default: throw InvalidValue("expected \(expectation)")
        }
    }

    private var expectation: String {
        switch self {
        case .duration: "a duration with units such as 20ms"
        case .distribution: "a latency distribution such as 20ms or 10ms..40ms"
        case .rate: "a rate such as 10/s or a nonnegative number"
        case .integer(let min, let max): max == .max ? "an integer of at least \(min)" : "an integer between \(min) and \(max)"
        case .probability: "a probability between 0 and 1 or a percentage"
        case .bool: "true or false"
        case .factor: "a positive factor"
        case .nodeID: "a node id"
        case .choices(let choices): "one of: \(choices.joined(separator: ", "))"
        }
    }
}
