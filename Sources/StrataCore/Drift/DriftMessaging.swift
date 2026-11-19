import Foundation

/// Messaging and keys: queue, exchange, topic and subject names and Valkey/Redis key patterns declared
/// in Go code, against the map. Names passed to a broker client (`QueueDeclare`, `ExchangeDeclare`,
/// `QueueBind`, `Consume`, `Publish…`, NATS `Subscribe`, a `Topic:` field) are confident and unmapped
/// ones are warnings; names found only by a constant's name (`ordersQueue = "…"`) and key-shaped strings
/// (`roster:inst:%s`) are notes. A topic or key the map names that no string in the repo contains is a
/// note too, or a warning when the repo declares its other names in code.
enum DriftMessaging {
    enum Kind: String { case queue, exchange, topic, subject, routingKey = "routing key", key }

    struct RepoName {
        var value: String
        var kind: Kind
        var file: String
        var line: Int
        var confident: Bool
    }

    /// amqp091 calls and what each argument position names.
    private static let brokerCalls: [String: [Int: Kind]] = [
        "QueueDeclare": [0: .queue], "QueueDeclarePassive": [0: .queue], "ExchangeDeclare": [0: .exchange], "ExchangeDeclarePassive": [0: .exchange],
        "QueueBind": [0: .queue, 1: .routingKey, 2: .exchange], "ExchangeBind": [0: .exchange, 1: .routingKey, 2: .exchange],
        "Consume": [0: .queue], "ConsumeWithContext": [1: .queue], "Publish": [0: .exchange, 1: .routingKey],
        "PublishWithContext": [1: .exchange, 2: .routingKey], "PublishWithDeferredConfirmWithContext": [1: .exchange, 2: .routingKey],
    ]
    private static let natsCalls: Set<String> = ["Subscribe", "QueueSubscribe", "Publish", "Request", "ChanSubscribe", "PullSubscribe"]
    private static let fields: [String: Kind] = ["Topic": .topic, "Queue": .queue, "QueueName": .queue, "Exchange": .exchange,
                                                 "RoutingKey": .routingKey, "Subject": .subject, "Stream": .topic]
    private static let exchangeKinds: Set<String> = ["direct", "topic", "fanout", "headers", "x-delayed-message"]

    static func repoNames(_ repo: DriftRepo) -> [RepoName] {
        let out = repo.goSources.flatMap { repo.goFacts($0).names }
        // One finding per value and file: the first place it is declared.
        var seen = Set<String>()
        return out.filter { seen.insert("\($0.file)|\($0.value)|\($0.kind.rawValue)").inserted }
    }

    /// The names a Go file declares or hands to a broker or key-value client.
    static func names(in tokens: [GoToken], imports rawImports: [String], literals: [(text: String, line: Int)], file: String) -> [RepoName] {
        var out: [RepoName] = []
        do {
            let imports = rawImports.map { $0.lowercased() }
            let amqp = imports.contains { $0.contains("amqp") }
            let kafka = imports.contains { $0.contains("kafka") || $0.contains("sarama") || $0.contains("franz-go") }
            let nats = imports.contains { $0.contains("nats") }
            let broker = amqp || kafka || nats || imports.contains { $0.contains("sqs") || $0.contains("pubsub") }
            let redis = imports.contains { $0.contains("redis") || $0.contains("valkey") || $0.contains("rueidis") || $0.contains("redigo") }
            let keyFile = redis || file.lowercased().contains("redis") || file.lowercased().contains("valkey") || file.lowercased().contains("cache")
            var i = 0
            while i < tokens.count {
                let token = tokens[i]
                defer { i += 1 }
                guard token.kind == .ident, i + 2 < tokens.count else { continue }
                // Broker client calls: their string arguments, in order.
                if tokens[i + 1].text == "(", amqp, let kinds = brokerCalls[token.text] {
                    for arg in stringArguments(tokens, open: i + 1) {
                        guard let kind = kinds[arg.index], valid(arg.text) else { continue }
                        out.append(RepoName(value: arg.text, kind: kind, file: file, line: arg.line, confident: true))
                    }
                    continue
                }
                if tokens[i + 1].text == "(", nats, natsCalls.contains(token.text),
                   let first = stringArguments(tokens, open: i + 1).first(where: { $0.index == 0 }), valid(first.text) {
                    out.append(RepoName(value: first.text, kind: .subject, file: file, line: first.line, confident: true))
                    continue
                }
                // A `Topic: "orders"` field in a file that talks to a broker.
                if broker, let kind = fields[token.text], tokens[i + 1].text == ":", tokens[i + 2].kind == .string, valid(tokens[i + 2].text) {
                    out.append(RepoName(value: tokens[i + 2].text, kind: kind, file: file, line: tokens[i + 2].line, confident: true))
                    continue
                }
                // name [Type] = "value" or name := "value"
                guard let value = assignedString(tokens, at: i) else { continue }
                let lower = token.text.lowercased()
                if keyShaped(value.text), keyFile || ["key", "prefix", "lock", "lease"].contains(where: lower.contains) {
                    out.append(RepoName(value: value.text, kind: .key, file: file, line: value.line, confident: false))
                } else if valid(value.text), !value.text.contains(" "), !exchangeKinds.contains(value.text) {
                    let kind: Kind? = lower.contains("routingkey") || lower.hasSuffix("routing") ? .routingKey
                        : lower.contains("exchange") ? .exchange
                        : lower.contains("queue") ? .queue
                        : lower.contains("topic") || lower.hasSuffix("stream") ? .topic
                        : lower.contains("subject") ? .subject : nil
                    if let kind { out.append(RepoName(value: value.text, kind: kind, file: file, line: value.line, confident: false)) }
                }
            }
            // Key-shaped strings handed to a Valkey or Redis client (`fmt.Sprintf("roster:%s", id)`).
            if redis {
                for literal in literals where keyShaped(literal.text) {
                    out.append(RepoName(value: literal.text, kind: .key, file: file, line: literal.line, confident: false))
                }
            }
        }
        return out
    }

    /// The call's arguments that are a single string literal, with their position.
    private static func stringArguments(_ tokens: [GoToken], open: Int) -> [(index: Int, text: String, line: Int)] {
        var depth = 0, j = open
        var out: [(Int, String, Int)] = []
        var argument = 0
        var parts = 0
        var literal: GoToken?
        func finish() {
            if parts == 1, let literal { out.append((argument, literal.text, literal.line)) }
            parts = 0
            literal = nil
        }
        while j < tokens.count {
            let t = tokens[j]
            if t.kind == .newline { j += 1; continue }
            if t.text == "(" || t.text == "{" || t.text == "[" {
                depth += 1
                if depth > 1 { parts += 1 }
            } else if t.text == ")" || t.text == "}" || t.text == "]" {
                depth -= 1
                if depth == 0 { finish(); break }
            } else if depth == 1, t.text == "," {
                finish()
                argument += 1
            } else if depth == 1 {
                parts += 1
                if t.kind == .string { literal = t }
            }
            j += 1
        }
        return out
    }

    private static func assignedString(_ tokens: [GoToken], at i: Int) -> (text: String, line: Int)? {
        var j = i + 1
        if j < tokens.count, tokens[j].text == ":=" {
            j += 1
        } else {
            // An optional type: Ident or pkg.Ident.
            if j < tokens.count, tokens[j].kind == .ident { j += 1; if j + 1 < tokens.count, tokens[j].text == ".", tokens[j + 1].kind == .ident { j += 2 } }
            guard j < tokens.count, tokens[j].text == "=" else { return nil }
            j += 1
        }
        guard j < tokens.count, tokens[j].kind == .string else { return nil }
        // The whole value is the literal: the next token ends the statement.
        if j + 1 < tokens.count, ![.newline].contains(tokens[j + 1].kind), ![")", ";", "}", ","].contains(tokens[j + 1].text) { return nil }
        return (tokens[j].text, tokens[j].line)
    }

    /// A broker name: 2–120 characters, no spaces, no format verbs or URLs.
    private static func valid(_ text: String) -> Bool {
        text.count >= 2 && text.count <= 120 && !text.contains(where: \.isWhitespace) && !text.contains("://") && !text.contains("%")
            && !text.hasPrefix("-") && text.contains(where: \.isLetter)
    }

    /// `roster:inst:%s`, `app:lock:{name}`, `price:` — segments separated by colons, the first a word.
    static func keyShaped(_ text: String) -> Bool {
        guard text.count >= 4, text.count <= 200, text.contains(":"), !text.contains(where: \.isWhitespace),
              !text.contains("/"), !text.contains("\""), !text.contains("="), !text.contains(","), !text.contains("("),
              !text.hasPrefix(":") else { return false }
        let segments = text.split(separator: ":", omittingEmptySubsequences: false)
        guard let first = segments.first, let initial = first.first, initial.isLetter,
              first.allSatisfy({ $0.isLetter || $0.isNumber || "_-.".contains($0) }) else { return false }
        // host:6379 and Bearer: aren't keys.
        if segments.count == 2, segments[1].allSatisfy(\.isNumber) { return false }
        let rest = segments.dropFirst().filter { !$0.isEmpty }
        return rest.allSatisfy { segment in segment.allSatisfy { $0.isLetter || $0.isNumber || "_-.{}%*<>$#".contains($0) } }
            && (rest.count >= 1 || text.hasSuffix(":") && first.count >= 3)
    }

    /// Key segments with placeholders as `*`; a trailing colon (a prefix builder) adds nothing.
    static func segments(_ key: String) -> [String] {
        var parts = key.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "" { parts.removeLast() }
        return parts.map { part in part.contains(where: { "%{<*$#".contains($0) }) || part.isEmpty ? "*" : part }
    }

    /// The two patterns could name the same keys: aligned segments are equal or one is a wildcard, the
    /// shorter is a prefix of the longer, and at least one literal segment matches.
    static func keysOverlap(_ a: [String], _ b: [String]) -> Bool {
        let count = min(a.count, b.count)
        guard count > 0 else { return false }
        var literal = false
        for i in 0..<count {
            if a[i] == "*" || b[i] == "*" { continue }
            guard a[i] == b[i] else { return false }
            literal = true
        }
        return literal
    }

    static func run(_ context: DriftContext) {
        let repo = context.repo
        let names = repoNames(repo)
        let facts = context.facts
        let mapText = facts.text
        // Key patterns the map writes anywhere: in ops, commands, state keys and docs.
        let mapKeys: [[String]] = Set(mapText.split(whereSeparator: { $0.isWhitespace || "`'\",;[]()".contains($0) })
            .map(String.init).filter(keyShaped)).sorted().map(segments)

        for name in names {
            let mentioned: Bool
            if name.kind == .key {
                let shape = segments(name.value)
                let prefix = shape.prefix { $0 != "*" }.joined(separator: ":")
                mentioned = mapKeys.contains { keysOverlap(shape, $0) } || (prefix.count >= 5 && DriftRepo.contains(mapText, prefix + ":"))
            } else {
                mentioned = DriftRepo.contains(mapText, name.value)
            }
            guard !mentioned else { continue }
            let what = name.kind == .key ? "key pattern \(name.value)" : "\(name.kind.rawValue) \(name.value)"
            context.add(DriftFinding(name.confident ? .warn : .info, .messaging, "unmapped-name",
                                     message: "\(what) is on no op or node",
                                     fix: name.kind == .key ? "Add a cache op with key: \(name.value) on the node that uses it, or mention the key in a how step."
                                        : "Add the publish or consume op that uses \(name.value), with topic: \(name.value).",
                                     repo: DriftRepoLocation(file: name.file, line: name.line), ref: name.value))
        }

        guard !facts.names.isEmpty else { return }
        let haystack = Haystack(repo)
        let declaresInCode = names.contains(where: \.confident)
        var checkedValues = Set<String>()
        for fact in facts.names {
            let value = fact.value.trimmingCharacters(in: .whitespaces)
            guard value.count >= 3, !value.contains(where: \.isWhitespace) else { continue }
            context.checked(.messaging)
            let key = "messaging|\(fact.location)"
            let pieces: [String]
            if fact.kind == .key {
                let shape = segments(value)
                let prefix = shape.prefix { $0 != "*" }
                pieces = prefix.isEmpty ? [] : [prefix.joined(separator: ":")]
            } else {
                // Placeholders and routing wildcards split the name into the parts the code must contain.
                pieces = value.split(whereSeparator: { "{}<>*#$%".contains($0) }).map(String.init)
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".:-_")) }.filter { $0.count >= 3 }
            }
            guard !pieces.isEmpty else { continue }
            let present = pieces.allSatisfy { haystack.contains($0) }
                || fact.kind == .key && pieces.allSatisfy { piece in piece.split(separator: ":").allSatisfy { haystack.contains(String($0)) } }
            guard !present, checkedValues.insert("\(fact.location)|\(value)").inserted else { continue }
            let confident = declaresInCode && fact.kind != .key
            context.add(DriftFinding(confident ? .warn : .info, .messaging, fact.kind == .key ? "key-gone" : "name-gone",
                                     message: "no string in the repo contains \(fact.kind == .key ? "key pattern" : fact.kind.rawValue) \(value)",
                                     fix: "Check what the code uses now and update \(fact.location.field ?? "the op"), or remove the op.",
                                     map: fact.location, ref: value), fact: key)
        }
    }

    /// Every Go string literal, plus the whole text of configs and code in other languages, for "does
    /// the repo contain this name anywhere". Searched with memmem.
    struct Haystack {
        private var bytes: [UInt8] = []

        init(_ repo: DriftRepo) {
            var buffer: [UInt8] = []
            for file in repo.goSources {
                for literal in repo.goFacts(file).literals { buffer += Array(literal.text.utf8); buffer.append(0) }
            }
            for file in repo.files {
                let name = (file as NSString).lastPathComponent
                let ext = (name as NSString).pathExtension.lowercased()
                guard DriftRepo.configExtensions.contains(ext) || DriftRepo.otherCodeExtensions.contains(ext) || DriftRepo.isConfigName(name),
                      let text = repo.text(file) else { continue }
                buffer += Array(text.utf8)
                buffer.append(0)
            }
            bytes = buffer
        }

        func contains(_ needle: String) -> Bool {
            let pattern = Array(needle.utf8)
            guard !pattern.isEmpty, pattern.count <= bytes.count else { return false }
            return bytes.withUnsafeBytes { hay in
                pattern.withUnsafeBytes { needle in
                    memmem(hay.baseAddress, hay.count, needle.baseAddress, needle.count) != nil
                }
            }
        }
    }
}
