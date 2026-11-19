import Foundation

// When a journey step happens (docs/manifest.md, Journeys): `at` is an offset from the start (`40ms`),
// an offset from the step before (`+16ms`), a wall clock (`14:31:17.020`) or a timestamp
// (`2026-11-19T14:31:17Z`). Steps resolve to one timeline; the player and `strata journey` show each
// step's time and the gap since the one before.

public struct JourneyTime: Sendable, Hashable {
    public enum Kind: String, Sendable { case offset, clock, timestamp }
    public var kind: Kind
    /// `+16ms`: after the step before, in that step's kind.
    public var relative = false
    /// Offset: seconds since the start. Clock: seconds since midnight. Timestamp: seconds since 1970, UTC.
    public var seconds: Double

    public init(kind: Kind, seconds: Double, relative: Bool = false) { self.kind = kind; self.seconds = seconds; self.relative = relative }

    public static func parse(_ raw: String) throws -> JourneyTime {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("+") {
            return JourneyTime(kind: .offset, seconds: try Syntax.duration(String(text.dropFirst())), relative: true)
        }
        if let seconds = timestamp(text) { return JourneyTime(kind: .timestamp, seconds: seconds) }
        if let seconds = clock(text) { return JourneyTime(kind: .clock, seconds: seconds) }
        do { return JourneyTime(kind: .offset, seconds: try Syntax.duration(text)) }
        catch {
            throw InvalidValue("expected a time: an offset from the start (40ms), from the step before (+16ms), a clock (14:31:17.020) or a timestamp (2026-11-19T14:31:17Z)")
        }
    }

    /// `14:31`, `14:31:17` or `14:31:17.020`.
    static func clock(_ text: String) -> Double? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (2...3).contains(parts.count), let hours = Int(parts[0]), (0...23).contains(hours), parts[0].count <= 2,
              let minutes = Int(parts[1]), (0...59).contains(minutes), parts[1].count == 2 else { return nil }
        var seconds = 0.0
        if parts.count == 3 {
            guard parts[2].count >= 2, let value = Double(parts[2]), value >= 0, value < 61, parts[2].first?.isNumber == true else { return nil }
            seconds = value
        }
        return Double(hours * 3600 + minutes * 60) + seconds
    }

    /// `2026-11-19T14:31:17Z`, with an optional fraction and a `+02:00` style offset; a space works for `T`.
    static func timestamp(_ text: String) -> Double? {
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?(Z|[+-]\d{2}:?\d{2})?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
        guard let year = group(1).flatMap(Int.init), let month = group(2).flatMap(Int.init), let day = group(3).flatMap(Int.init),
              let hour = group(4).flatMap(Int.init), let minute = group(5).flatMap(Int.init) else { return nil }
        let second = group(6).flatMap(Double.init) ?? 0
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute; components.second = Int(second)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard let date = calendar.date(from: components), calendar.component(.day, from: date) == day else { return nil }
        var offset = 0.0
        if let zone = group(7), zone != "Z" {
            let sign: Double = zone.hasPrefix("-") ? -1 : 1
            let digits = zone.dropFirst().filter(\.isNumber)
            guard digits.count == 4, let h = Double(digits.prefix(2)), let m = Double(digits.suffix(2)) else { return nil }
            offset = sign * (h * 3600 + m * 60)
        }
        return date.timeIntervalSince1970 + (second - Double(Int(second))) - offset
    }
}

/// A step's place on the journey's timeline.
public struct JourneyInstant: Sendable, Hashable {
    public var kind: JourneyTime.Kind
    public var seconds: Double
    public init(kind: JourneyTime.Kind, seconds: Double) { self.kind = kind; self.seconds = seconds }
}

public enum JourneyClock {
    /// Each step's instant, from its `at` and the step before (a step without `at` happens when the one
    /// before it did). The problems are (step index, message) pairs: a mixed timeline, time going back.
    public static func timeline(_ steps: [JourneyStep]) -> (instants: [JourneyInstant?], problems: [(Int, String)]) {
        var instants: [JourneyInstant?] = []
        var problems: [(Int, String)] = []
        var previous: JourneyInstant?
        for (index, step) in steps.enumerated() {
            guard let raw = step.at, let time = try? JourneyTime.parse(raw) else {
                instants.append(previous)
                continue
            }
            var instant: JourneyInstant
            if time.relative {
                let base = previous ?? JourneyInstant(kind: .offset, seconds: 0)
                instant = JourneyInstant(kind: base.kind, seconds: base.seconds + time.seconds)
            } else {
                instant = JourneyInstant(kind: time.kind, seconds: time.seconds)
                if let previous, previous.kind != time.kind {
                    problems.append((index, "at mixes a \(name(time.kind)) with the \(name(previous.kind)) before it; keep one kind, or write offsets from the step before (+16ms)"))
                }
            }
            if let previous, previous.kind == instant.kind, instant.seconds < previous.seconds - 1e-9 {
                problems.append((index, "at goes back in time: \(format(instant)) is before \(format(previous))"))
            }
            instants.append(instant)
            previous = instant
        }
        return (instants, problems)
    }

    private static func name(_ kind: JourneyTime.Kind) -> String {
        switch kind {
        case .offset: "offset"
        case .clock: "clock time"
        case .timestamp: "timestamp"
        }
    }

    /// `14:31:17.020` for a clock or a timestamp (UTC), `0 ms`, `40 ms`, `1.24 s`, `2 m 05 s` for an offset.
    public static func format(_ instant: JourneyInstant) -> String {
        switch instant.kind {
        case .offset: return duration(instant.seconds)
        case .clock: return timeOfDay(instant.seconds.truncatingRemainder(dividingBy: 86400))
        case .timestamp:
            let day = instant.seconds.truncatingRemainder(dividingBy: 86400)
            return timeOfDay(day < 0 ? day + 86400 : day)
        }
    }

    /// The date of a timestamp, `2026-11-19`; nil for clocks and offsets.
    public static func date(_ instant: JourneyInstant) -> String? {
        guard instant.kind == .timestamp else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: instant.seconds))
    }

    /// The gap since the step before, `+16 ms`; nil when either has no time, the kinds differ, or no time passed.
    public static func delta(_ instant: JourneyInstant?, after previous: JourneyInstant?) -> String? {
        guard let instant, let previous, instant.kind == previous.kind else { return nil }
        let gap = instant.seconds - previous.seconds
        guard gap > 1e-9 else { return nil }
        return "+" + duration(gap)
    }

    static func timeOfDay(_ seconds: Double) -> String {
        let millis = Int((seconds * 1000).rounded())
        let h = millis / 3_600_000, m = millis / 60_000 % 60, s = millis / 1000 % 60, ms = millis % 1000
        let base = String(format: "%02d:%02d:%02d", h, m, s)
        return ms == 0 ? base : base + String(format: ".%03d", ms)
    }

    public static func duration(_ seconds: Double) -> String {
        if seconds < 1 {
            let ms = (seconds * 10_000).rounded() / 10
            return (ms == ms.rounded() || ms >= 10 ? String(Int(ms.rounded())) : String(format: "%.1f", ms)) + " ms"
        }
        if seconds < 60 {
            let text = String(format: "%.2f", seconds).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
            return text + " s"
        }
        if seconds < 3600 {
            let total = Int(seconds.rounded())
            return total % 60 == 0 ? "\(total / 60) m" : String(format: "%d m %02d s", total / 60, total % 60)
        }
        let total = Int(seconds.rounded())
        return total % 3600 == 0 ? "\(total / 3600) h" : String(format: "%d h %02d m", total / 3600, total / 60 % 60)
    }
}
