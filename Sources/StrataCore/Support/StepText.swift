import Foundation

// Text helpers for the How it works player (docs/design.md, How it works): reading a step's command
// (SQL, a Valkey/Redis command, anything else), fitting long keys and labels into the room they have,
// and placing the sequence diagram's rows and columns so nothing draws over anything else. Pure
// functions: the UI measures text and hands the widths in.

/// What a step's `command` is, and a Valkey/Redis command split into its parts.
public enum StepCommand {
    public enum Kind: Sendable, Equatable { case sql, redis, other }

    /// A Valkey/Redis command: `SET roster:inst:a 1 NX PX 15000` is verb `SET`, key `roster:inst:a`,
    /// args `1 NX PX 15000`. `EVALSHA sha 2 k1 k2 a` has the script `sha` and keys `k1 k2`.
    public struct Redis: Sendable, Equatable {
        public var verb: String
        public var script: String?
        public var keys: [String]
        public var args: [String]
        public init(verb: String, script: String? = nil, keys: [String] = [], args: [String] = []) {
            self.verb = verb; self.script = script; self.keys = keys; self.args = args
        }
    }

    public static func kind(_ command: String) -> Kind {
        if redis(command) != nil { return .redis }
        return SQLFormat.looksLikeSQL(command) ? .sql : .other
    }

    /// The command on one line: every run of whitespace (newlines too) becomes one space.
    public static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// A step's `command → reply` in lines of at most `chars` characters, for the diagram: one line when
    /// both fit (`\0` between them), else the command, then `\0` and the reply on a line of its own, so
    /// the reply is never cut off by a long command. `cut` says the line lost something.
    public static func lines(command: String?, reply: String?, chars: Int) -> [(text: String, cut: Bool)] {
        let reply = reply.map(oneLine)
        guard let command else {
            guard let reply else { return [] }
            let fitted = fit(reply, chars - 2)
            return [("\u{0}" + fitted, fitted != reply)]
        }
        let whole = oneLine(command)
        if let reply {
            if whole.count + 5 + reply.count <= chars { return [(whole + "\u{0}" + reply, false)] }
            let second = fit(reply, chars - 2)
            return [shortened(command, chars: chars), ("\u{0}" + second, second != reply)]
        }
        return [shortened(command, chars: chars)]
    }

    /// A command on one line in `chars` characters. A Valkey command keeps its verb and arguments and
    /// cuts its keys in the middle (`SET app:…:nightly 17 NX PX 15000`), and a long script hash to its
    /// start; anything else is cut at the end.
    public static func shortened(_ command: String, chars: Int) -> (text: String, cut: Bool) {
        let whole = oneLine(command)
        if whole.count <= chars { return (whole, false) }
        guard let redis = redis(command), let tokens = tokens(command) else { return (fit(whole, chars), true) }
        let keys = Set(redis.keys)
        func short(_ token: String) -> String { token == redis.script && token.count > 12 ? String(token.prefix(8)) + "…" : token }
        let fixed = tokens.filter { !keys.contains($0) }.map(short)
        let keyCount = tokens.count - fixed.count
        guard keyCount > 0 else { return (fit(tokens.map(short).joined(separator: " "), chars), true) }
        let budget = chars - fixed.reduce(0) { $0 + $1.count } - (tokens.count - 1)
        let each = max(14, budget / keyCount)
        return (fit(tokens.map { keys.contains($0) ? TextFit.middle($0, limit: each) : short($0) }.joined(separator: " "), chars), true)
    }

    private static func fit(_ text: String, _ chars: Int) -> String {
        text.count <= chars ? text : String(text.prefix(max(1, chars - 1))) + "…"
    }

    /// Splits a Valkey/Redis command; nil when the text isn't one (SQL, a gRPC call, prose, several lines).
    public static func redis(_ command: String) -> Redis? {
        guard let tokens = tokens(command), let first = tokens.first else { return nil }
        let name = first.uppercased()
        guard first.allSatisfy({ $0.isLetter || $0 == "_" || $0 == "." }), commands.contains(name) else { return nil }
        var rest = Array(tokens.dropFirst())
        // `SET a b` sets a key; `SET LOCAL lock_timeout = '1s'` is SQL. (`SELECT` is always SQL here.)
        if name == "SET" {
            let sqlWords: Set<String> = ["LOCAL", "SESSION", "TRANSACTION", "CONSTRAINTS", "ROLE", "TIME", "SEARCH_PATH"]
            if rest.count < 2 || command.contains("=") || sqlWords.contains(rest[0].uppercased()) || rest.contains(where: { $0.uppercased() == "TO" }) {
                return nil
            }
        }
        var verb = name
        if containers.contains(name), let sub = rest.first {
            verb += " " + sub.uppercased()
            rest.removeFirst()
            return Redis(verb: verb, args: rest)
        }
        switch name {
        case "EVAL", "EVALSHA", "EVAL_RO", "EVALSHA_RO", "FCALL", "FCALL_RO":
            guard rest.count >= 2, let count = Int(rest[1]), count >= 0, rest.count >= 2 + count else {
                return Redis(verb: verb, args: rest)
            }
            return Redis(verb: verb, script: rest[0], keys: Array(rest[2..<(2 + count)]), args: Array(rest[(2 + count)...]))
        case "DEL", "UNLINK", "EXISTS", "TOUCH", "WATCH", "MGET", "SUNION", "SINTER", "SDIFF", "PFCOUNT":
            return Redis(verb: verb, keys: rest)
        case "MSET", "MSETNX":
            return Redis(verb: verb, keys: stride(from: 0, to: rest.count, by: 2).map { rest[$0] },
                         args: stride(from: 1, to: rest.count, by: 2).map { rest[$0] })
        case "XREAD", "XREADGROUP":
            guard let at = rest.firstIndex(where: { $0.uppercased() == "STREAMS" }) else { return Redis(verb: verb, args: rest) }
            let tail = Array(rest[(at + 1)...])
            let half = tail.count / 2
            return Redis(verb: verb, keys: Array(tail.prefix(half)), args: Array(rest[...at]) + tail.dropFirst(half))
        case _ where keyless.contains(name):
            return Redis(verb: verb, args: rest)
        default:
            guard let key = rest.first else { return Redis(verb: verb) }
            return Redis(verb: verb, keys: [key], args: Array(rest.dropFirst()))
        }
    }

    /// Words split on spaces, with quoted strings ('…', "…") kept whole, quotes included. Nil when a line
    /// break sits outside quotes (several commands, or not a command at all) or a quote never closes.
    public static func tokens(_ text: String) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for c in text.trimmingCharacters(in: .whitespacesAndNewlines) {
            if let open = quote {
                current.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == open { quote = nil }
                continue
            }
            if c == "\n" || c == "\r" { return nil }
            if c == " " || c == "\t" {
                if !current.isEmpty { tokens.append(current); current = "" }
                continue
            }
            if (c == "\"" || c == "'") && current.isEmpty { quote = c }
            current.append(c)
        }
        guard quote == nil else { return nil }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Commands that take a subcommand (`CLIENT SETNAME`, `XGROUP CREATE`); their arguments are shown as written.
    private static let containers: Set<String> = ["CLIENT", "CONFIG", "SCRIPT", "FUNCTION", "CLUSTER", "OBJECT", "MEMORY", "ACL",
                                                  "XGROUP", "XINFO", "COMMAND", "LATENCY", "MODULE", "PUBSUB", "SLOWLOG"]
    /// Commands whose first argument is not a key.
    private static let keyless: Set<String> = ["PING", "ECHO", "MULTI", "EXEC", "DISCARD", "UNWATCH", "INFO", "TIME", "DBSIZE",
                                               "FLUSHALL", "FLUSHDB", "AUTH", "HELLO", "QUIT", "RESET", "SCAN", "KEYS",
                                               "PUBLISH", "SPUBLISH", "SUBSCRIBE", "SSUBSCRIBE", "PSUBSCRIBE", "UNSUBSCRIBE",
                                               "PUNSUBSCRIBE", "WAIT", "RANDOMKEY", "SWAPDB", "LASTSAVE", "SAVE", "BGSAVE",
                                               "SHUTDOWN", "MONITOR", "READONLY", "READWRITE", "ROLE", "FAILOVER", "REPLICAOF"]
    private static let commands: Set<String> = containers.union(keyless).union([
        "GET", "SET", "SETNX", "SETEX", "PSETEX", "GETSET", "GETDEL", "GETEX", "GETRANGE", "SETRANGE", "APPEND", "STRLEN",
        "INCR", "INCRBY", "INCRBYFLOAT", "DECR", "DECRBY", "MGET", "MSET", "MSETNX", "DEL", "UNLINK", "EXISTS", "TOUCH",
        "EXPIRE", "PEXPIRE", "EXPIREAT", "PEXPIREAT", "PERSIST", "TTL", "PTTL", "EXPIRETIME", "PEXPIRETIME", "TYPE",
        "RENAME", "RENAMENX", "COPY", "DUMP", "RESTORE", "WATCH", "SORT",
        "HGET", "HSET", "HSETNX", "HMSET", "HMGET", "HGETALL", "HDEL", "HEXISTS", "HINCRBY", "HINCRBYFLOAT", "HKEYS", "HVALS",
        "HLEN", "HSCAN", "HSTRLEN", "HRANDFIELD", "HEXPIRE", "HPEXPIRE", "HTTL", "HPTTL", "HGETDEL", "HGETEX", "HSETEX",
        "LPUSH", "RPUSH", "LPUSHX", "RPUSHX", "LPOP", "RPOP", "LRANGE", "LLEN", "LINDEX", "LSET", "LREM", "LTRIM", "LINSERT",
        "LMOVE", "BLMOVE", "BLPOP", "BRPOP", "LPOS", "LMPOP", "BLMPOP", "RPOPLPUSH", "BRPOPLPUSH",
        "SADD", "SREM", "SMEMBERS", "SISMEMBER", "SMISMEMBER", "SCARD", "SPOP", "SRANDMEMBER", "SMOVE", "SSCAN",
        "SUNION", "SINTER", "SDIFF", "SUNIONSTORE", "SINTERSTORE", "SDIFFSTORE", "SINTERCARD",
        "ZADD", "ZREM", "ZSCORE", "ZMSCORE", "ZINCRBY", "ZCARD", "ZCOUNT", "ZRANGE", "ZRANGEBYSCORE", "ZREVRANGE",
        "ZREVRANGEBYSCORE", "ZRANGEBYLEX", "ZRANK", "ZREVRANK", "ZREMRANGEBYSCORE", "ZREMRANGEBYRANK", "ZREMRANGEBYLEX",
        "ZPOPMIN", "ZPOPMAX", "BZPOPMIN", "BZPOPMAX", "ZSCAN", "ZRANGESTORE", "ZUNIONSTORE", "ZINTERSTORE", "ZMPOP",
        "XADD", "XREAD", "XREADGROUP", "XACK", "XCLAIM", "XAUTOCLAIM", "XPENDING", "XRANGE", "XREVRANGE", "XLEN", "XDEL", "XTRIM",
        "PFADD", "PFCOUNT", "PFMERGE", "SETBIT", "GETBIT", "BITCOUNT", "BITPOS", "BITFIELD", "GEOADD", "GEOSEARCH", "GEODIST",
        "EVAL", "EVALSHA", "EVAL_RO", "EVALSHA_RO", "FCALL", "FCALL_RO", "OBJECT", "SCAN",
    ])
}

/// Fitting text into a width: middle truncation for keys, word wrap with an ellipsis for labels.
public enum TextFit {
    /// Characters a long key breaks after, and that middle truncation keeps whole segments between.
    public static let keySeparators: Set<Character> = [":", "/"]

    /// `text` in at most `limit` characters, cut in the middle. A key keeps whole segments at both ends,
    /// more of its end than its start (the end names the thing): `app:…:nightly-sweep`. Text without
    /// separators, or whose first and last segment alone are too long, is cut between characters.
    public static func middle(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        guard limit > 1 else { return limit == 1 ? "…" : "" }
        let chars = Array(text)
        // Segments and the separator after each: "a:b/c" → [("a", ":"), ("b", "/"), ("c", nil)].
        var segments: [(text: String, separator: Character?)] = []
        var current = ""
        for c in chars {
            if keySeparators.contains(c) { segments.append((current, c)); current = "" } else { current.append(c) }
        }
        segments.append((current, nil))
        if segments.count >= 3 {
            func build(_ head: Int, _ tail: Int) -> String {
                // `head` segments from the start (with their separators), `tail` from the end (each with the separator before it).
                let start = segments.prefix(head).map { $0.text + ($0.separator.map(String.init) ?? "") }.joined()
                let end = segments.suffix(tail).enumerated().map { offset, segment in
                    let before = segments[segments.count - tail + offset - 1].separator.map(String.init) ?? ""
                    return before + segment.text
                }.joined()
                return start + "…" + end
            }
            var head = 1, tail = 1
            if build(head, tail).count <= limit {
                while head + tail < segments.count {
                    let longerTail = build(head, tail + 1), longerHead = build(head + 1, tail)
                    // The shorter of the two first; on a tie, more of the end.
                    let options = longerTail.count <= longerHead.count ? [(head, tail + 1), (head + 1, tail)] : [(head + 1, tail), (head, tail + 1)]
                    guard let next = options.first(where: { build($0.0, $0.1).count <= limit }) else { break }
                    (head, tail) = next
                }
                return build(head, tail)
            }
        }
        let keep = limit - 1
        let front = keep * 2 / 5
        return String(chars.prefix(front)) + "…" + String(chars.suffix(keep - front))
    }

    /// `text` wrapped at spaces into at most `maxLines` lines no wider than `width` by `measure`. The last
    /// line ends in `…` when the text doesn't fit. A word wider than a whole line is cut between
    /// characters, or with `breakWords: false` kept whole on its own line and cut short with `…`.
    public static func wrap(_ text: String, width: Double, maxLines: Int, breakWords: Bool = true,
                            measure: (String) -> Double) -> (lines: [String], truncated: Bool) {
        var words: [String] = []
        for word in text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init) {
            var rest = word
            while breakWords, rest.count > 1, measure(rest) > width {
                let fit = max(1, prefixFitting(rest, width: width, measure: measure))
                words.append(String(rest.prefix(fit)))
                rest = String(rest.dropFirst(fit))
            }
            words.append(rest)
        }
        guard !words.isEmpty, maxLines > 0 else { return ([], !words.isEmpty) }
        var lines: [String] = []
        var line = ""
        var truncated = false
        func finish(_ text: String) -> String {
            let fitted = ellipsize(text, width: width, measure: measure)
            if fitted != text { truncated = true }
            return fitted
        }
        for (index, word) in words.enumerated() {
            let candidate = line.isEmpty ? word : line + " " + word
            if line.isEmpty || measure(candidate) <= width { line = candidate; continue }
            if lines.count == maxLines - 1 {
                return (lines + [ellipsize(line + " " + words[index...].joined(separator: " "), width: width, measure: measure)], true)
            }
            lines.append(finish(line))
            line = word
        }
        let all = lines + [finish(line)]
        return (all, truncated)
    }

    /// The longest start of `text` that fits `width` with a trailing `…`; the whole text when it fits as is.
    public static func ellipsize(_ text: String, width: Double, measure: (String) -> Double) -> String {
        if measure(text) <= width { return text }
        let chars = Array(text)
        var low = 0, high = chars.count
        while low < high {
            let mid = (low + high + 1) / 2
            if measure(String(chars.prefix(mid)) + "…") <= width { low = mid } else { high = mid - 1 }
        }
        var start = String(chars.prefix(low))
        while start.last == " " { start.removeLast() }
        return start + "…"
    }

    private static func prefixFitting(_ word: String, width: Double, measure: (String) -> Double) -> Int {
        let chars = Array(word)
        var low = 0, high = chars.count
        while low < high {
            let mid = (low + high + 1) / 2
            if measure(String(chars.prefix(mid))) <= width { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// A key with a zero-width space after each separator, so wrapped text breaks between segments
    /// (`app:jobs:lock:` then `nightly-sweep`) instead of inside one. Copying strips them (`unbroken`).
    public static func softBreaks(_ key: String) -> String {
        var out = ""
        for c in key {
            out.append(c)
            if keySeparators.contains(c) { out.append("\u{200B}") }
        }
        return out
    }

    public static func unbroken(_ text: String) -> String { text.replacingOccurrences(of: "\u{200B}", with: "") }
}

/// Where the sequence diagram's columns and rows go.
public enum SequenceGeometry {
    /// The chips (by index) that fit in `maxLines` lines of `lineWidth`, in order, with room left at the
    /// end for a "+N more" chip as wide as `more(N)` when some don't fit. `keep` (the selected chip)
    /// is always among them, in place of the last one that would otherwise show.
    public static func fitChips(_ widths: [Double], lineWidth: Double, maxLines: Int, spacing: Double,
                                more: (Int) -> Double, keep: Int? = nil) -> [Int] {
        func lines(_ items: [Double]) -> Int {
            var count = 1, x = 0.0
            for width in items {
                if x > 0, x + width > lineWidth { count += 1; x = 0 }
                x += width + spacing
            }
            return count
        }
        let all = Array(widths.indices)
        if lines(widths) <= maxLines { return all }
        for shown in stride(from: widths.count - 1, through: 0, by: -1) {
            var pick = Array(all.prefix(shown))
            if let keep, !pick.contains(keep), !pick.isEmpty { pick[pick.count - 1] = keep }
            if lines(pick.map { widths[$0] } + [more(widths.count - pick.count)]) <= maxLines { return pick }
        }
        return keep.map { [$0] } ?? []
    }

    /// What one row needs around its arrow: text above and below it, and the extra room its time gap adds.
    public struct RowExtent: Sendable, Equatable {
        public var above: Double
        public var below: Double
        public var gap: Double
        public init(above: Double, below: Double, gap: Double = 0) { self.above = above; self.below = below; self.gap = gap }
    }

    /// The y of each row's arrow: the first `top + above` down, each next one far enough below the one
    /// before that their text keeps `spacing` apart (never closer than `minPitch`), plus its time gap.
    public static func rows(_ extents: [RowExtent], top: Double, spacing: Double, minPitch: Double) -> [Double] {
        var ys: [Double] = []
        for (index, extent) in extents.enumerated() {
            guard index > 0, let last = ys.last else { ys.append(top + extent.above + extent.gap); continue }
            let previous = extents[index - 1]
            ys.append(last + max(minPitch, previous.below + spacing + extent.above) + extent.gap)
        }
        return ys
    }

    /// Participant columns spread evenly between `left` and `right`, with each header box (ideal widths
    /// in `widths`) centred on its column. One tier when neighbours' boxes fit side by side; else boxes
    /// alternate between two tiers, so only every other box must clear its neighbour. `caps` is the width
    /// each box may use: its ideal width unless even two tiers are too tight, when the box truncates.
    public struct Columns: Sendable, Equatable {
        public var xs: [Double]
        public var tiers: Int
        public var caps: [Double]
    }

    public static func columns(widths: [Double], left: Double, right: Double, gap: Double, minCap: Double = 56) -> Columns {
        let count = widths.count
        guard count > 1 else { return Columns(xs: count == 1 ? [((left + right) / 2).rounded()] : [], tiers: 1, caps: widths) }
        var caps = widths
        var tiers = 1
        var xs: [Double] = []
        // A few rounds: where the end columns go depends on how wide their boxes end up.
        for _ in 0..<3 {
            let first = left + caps[0] / 2
            let last = max(first + Double(count - 1), right - caps[count - 1] / 2)
            let step = (last - first) / Double(count - 1)
            xs = (0..<count).map { (first + step * Double($0)).rounded() }
            let oneTier = (0..<(count - 1)).allSatisfy { (widths[$0] + widths[$0 + 1]) / 2 + gap <= step }
            if oneTier { return Columns(xs: xs, tiers: 1, caps: widths) }
            tiers = 2
            let room = max(minCap, 2 * step - gap)
            caps = widths.map { min($0, room) }
        }
        // The end boxes stay inside the diagram whatever the last round settled on.
        caps[0] = min(caps[0], max(minCap, 2 * (xs[0] - left)))
        caps[count - 1] = min(caps[count - 1], max(minCap, 2 * (right - xs[count - 1])))
        return Columns(xs: xs, tiers: tiers, caps: caps)
    }
}
