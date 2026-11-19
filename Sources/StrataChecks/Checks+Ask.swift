import Foundation
import StrataCore

// Ask the map: the digest, link parsing and resolution, finding the Claude Code CLI, stream-json
// parsing, the runner and `strata ask`, all without a network (a fake `claude` script replays canned
// streams).

@MainActor func askChecks() -> [CheckCase] {
    [
        CheckCase(name: "ask digest is deterministic and names every kind of id") {
            let checkout = try askExample("checkout")
            let file = StrataResources.url("Examples/checkout.yaml")?.path
            let first = AskDigest.build(checkout, file: file)
            let second = AskDigest.build(checkout, file: file)
            check(first.text == second.text, "two builds of the checkout digest differ")
            let focus = AskFocus(path: ["orders"], node: "relay")
            check(AskDigest.build(checkout, file: file, focus: focus).text == AskDigest.build(checkout, file: file, focus: focus).text,
                  "focused builds differ")
            check(first.tier == 0 && first.cut.isEmpty && !first.truncated, "checkout should fit the default budget whole: \(first.cut)")
            for needle in ["MAP checkout", "file: \(file ?? "")", "NODE orders [service] \"orders-svc\"", "- insert-order sql out →db write",
                           "INSERT INTO orders", "relay-cycle \"Outbox relay claim, publish and ack\"", "SELECT id, payload FROM outbox",
                           "order-status \"Order status\"", "10 placed", "10→20 payment captured (by orders/capture-payment)",
                           "- orders — ", "status smallint", "db-outage \"Postgres outage\"", "place-order \"Place order\" from web",
                           "LEVEL orders · inside orders-svc", "strata:level/orders", "edges: web→api"] {
                check(first.text.contains(needle), "digest is missing \(needle)")
            }
        },
        CheckCase(name: "ask digest cuts the least important detail first and says what it cut") {
            let checkout = try askExample("checkout")
            var previous = Int.max
            var tiers: [Int] = []
            for budget in [100_000, 26_000, 20_000, 16_000, 12_000, 9_000, 6_000] {
                let digest = AskDigest.build(checkout, file: nil, budget: budget)
                check(digest.bytes <= budget, "budget \(budget): \(digest.bytes) bytes")
                check(digest.bytes <= previous, "a smaller budget gave a larger digest at \(budget)")
                check(digest.cut == Array(AskDigest.cuts.prefix(digest.tier)) + (digest.truncated ? [digest.cut.last ?? ""] : []),
                      "budget \(budget): cut list doesn't match tier \(digest.tier): \(digest.cut)")
                previous = digest.bytes
                tiers.append(digest.tier)
            }
            check(tiers == tiers.sorted() && tiers.first == 0 && (tiers.last ?? 0) >= 4, "tiers should rise as the budget falls: \(tiers)")
            // Tier 1 keeps two sample rows at most; tier 2 none; op tables survive every tier.
            // Focused on a deep dive, so the overview gets the global tier.
            let away = AskFocus(path: ["orders"])
            let one = AskDigest.build(checkout, file: nil, focus: away, budget: AskDigest.build(checkout, file: nil, focus: away).bytes - 1)
            let rowLines = one.text.split(separator: "\n").filter { $0.contains("rows: (") }
            check(one.tier == 1 && !rowLines.isEmpty && rowLines.allSatisfy { $0.components(separatedBy: "); (").count <= 2 },
                  "tier 1 should keep at most two sample rows: tier \(one.tier)")
            let deepest = AskDigest.build(checkout, file: nil, focus: away, budget: 9_000)
            check(deepest.text.contains("insert-order sql→db write [orders, order_items, payments, outbox]")
                  || deepest.text.contains("tables orders, order_items, payments, outbox"),
                  "op tables were cut at tier \(deepest.tier)")
            check(!deepest.text.contains("INSERT INTO orders (id, user_id, status, total_cents, currency"), "overview queries should be gone at tier \(deepest.tier)")
            let tiny = AskDigest.build(checkout, file: nil, budget: 2_500)
            check(tiny.truncated && tiny.bytes <= 2_500 && tiny.text.contains("digest cut at 2 KB") && tiny.cut.last == "everything past 2 KB",
                  "a tiny budget should cut the text short and say so: \(tiny.bytes) \(tiny.cut)")
        },
        CheckCase(name: "ask digest keeps the selected node and the level on screen in more detail") {
            let checkout = try askExample("checkout")
            let budget = 12_000
            let plain = AskDigest.build(checkout, file: nil, budget: budget)
            let focused = AskDigest.build(checkout, file: nil, focus: AskFocus(path: [], node: "db"), budget: budget)
            check(plain.tier >= 3, "budget should force a deep tier, got \(plain.tier)")
            check(!plain.text.contains("rows: (u-"), "unfocused digest shouldn't keep sample rows")
            check(focused.text.contains("rows: (") && focused.text.contains("· SELECTED"), "the selected database should keep its sample rows")
            let inside = AskDigest.build(checkout, file: nil, focus: AskFocus(path: ["orders"]), budget: budget)
            let lines = inside.text.split(separator: "\n").map(String.init)
            check(lines.firstIndex { $0.hasPrefix("LEVEL orders") } ?? 99 < lines.firstIndex { $0.hasPrefix("LEVEL root") } ?? 0,
                  "the level on screen should come first")
            check(inside.text.contains("(the user is looking at this level)"), "focus level not marked")
        },
        CheckCase(name: "ask links parse every kind and reject the rest") {
            check(AskLink.parse("strata:node/pacing") == .node(["pacing"]), "node")
            check(AskLink.parse("strata://node/orders/handler") == .node(["orders", "handler"]), "node with slashes after the scheme")
            check(AskLink.parse("strata:op/pacing/list-running") == .op(["pacing", "list-running"]), "op")
            check(AskLink.parse("strata:how/reaper-tick/reaper-tick") == .how(["reaper-tick", "reaper-tick"]), "how")
            check(AskLink.parse("strata:enum/campaign-status/3200") == .enumeration("campaign-status", value: "3200"), "enum value")
            check(AskLink.parse("strata:enum/campaign-status") == .enumeration("campaign-status", value: nil), "whole enum")
            check(AskLink.parse("strata:table/call") == .table(["call"]), "table")
            check(AskLink.parse("strata:level/orders%23insert-order") == .level(["orders#insert-order"]), "percent-encoded op level")
            check(AskLink.parse("strata:dive/orders") == .level(["orders"]), "dive alias")
            check(AskLink.parse("strata:flow/place-order") == .flow(["place-order"]), "flow")
            check(AskLink.parse("strata:scenario/db-outage") == .scenario(["db-outage"]), "scenario")
            for bad in ["strata:bogus/x", "https://example.com", "strata:node/", "strata:op/only-one", "strata:", "node/pacing", "strata:enum"] {
                check(AskLink.parse(bad) == nil, "\(bad) should not parse")
            }
        },
        CheckCase(name: "ask links resolve to app targets, with path fallbacks, and broken ones to nothing") {
            let m = try askExample("checkout")
            let expected: [(String, AskTarget?)] = [
                ("strata:node/db", .node(path: [], node: "db")),
                ("strata:node/orders/relay", .node(path: ["orders"], node: "relay")),
                ("strata:node/relay", .node(path: ["orders"], node: "relay")),
                ("strata:op/orders/insert-order", .op(path: [], node: "orders", op: "insert-order")),
                ("strata:op/orders/handler/commit", .op(path: ["orders"], node: "handler", op: "commit")),
                ("strata:op/handler/commit", .op(path: ["orders"], node: "handler", op: "commit")),
                ("strata:op/relay/insert-order", .op(path: [], node: "orders", op: "insert-order")),
                ("strata:how/orders/relay/relay-cycle", .mechanism(path: ["orders"], node: "relay", op: nil, mechanism: "relay-cycle")),
                ("strata:how/relay/relay-cycle", .mechanism(path: ["orders"], node: "relay", op: nil, mechanism: "relay-cycle")),
                ("strata:how/relay-cycle", .mechanism(path: ["orders"], node: "relay", op: nil, mechanism: "relay-cycle")),
                ("strata:enum/order-status/10", .enumeration(id: "order-status", value: "10")),
                ("strata:enum/order-status/placed", .enumeration(id: "order-status", value: "10")),
                ("strata:enum/order-status/77", .enumeration(id: "order-status", value: nil)),
                ("strata:enum/payment-status", .enumeration(id: "payment-status", value: nil)),
                ("strata:table/orders", .table(path: [], node: "db", table: "orders")),
                ("strata:table/db/outbox", .table(path: [], node: "db", table: "outbox")),
                ("strata:table/db.payments", .table(path: [], node: "db", table: "payments")),
                ("strata:level/orders", .level(path: ["orders"])),
                ("strata:level", .level(path: [])),
                ("strata:flow/place-order", .flow(path: [], flow: "place-order")),
                ("strata:scenario/db-outage", .scenario(path: [], scenario: "db-outage")),
                ("strata:node/ledger", nil), ("strata:op/orders/nope", nil), ("strata:how/nope", nil),
                ("strata:enum/nope/1", nil), ("strata:table/nope", nil), ("strata:level/nope", nil),
                ("strata:flow/nope", nil), ("strata:scenario/nope", nil),
            ]
            for (link, target) in expected {
                let resolved = m.askTarget(link)
                check(resolved == target, "\(link) → \(String(describing: resolved)), expected \(String(describing: target))")
                if let resolved { check(m.askTarget(resolved.link) == resolved, "canonical \(resolved.link) doesn't round-trip") }
            }
        },
        CheckCase(name: "ask answers keep links that resolve and turn broken ones into plain text") {
            let m = try askExample("checkout")
            let found = AskLinks.find(in: AskFixtures.answer)
            check(found.count == 13, "fixture should have 13 links, found \(found.count)")
            check(found.filter { m.askTarget($0.url) == nil }.map(\.label) == ["ledger"], "only ledger should be broken")
            let rewritten = AskLinks.rewrite(AskFixtures.answer, in: m)
            check(!rewritten.contains("strata:node/ledger") && rewritten.contains("The ledger isn't in this map"), "broken link not flattened")
            check(AskLinks.find(in: rewritten).count == 12 && rewritten.contains("[Postgres](strata:node/db)"), "resolved links lost")
            check(AskLinks.find(in: "see [x](<strata:node/db>) and [y]( strata:op/orders/insert-order )").count == 2, "angle brackets and spaces")
        },
        CheckCase(name: "ask stream parses a canned run: init, tool use, streamed text, result") {
            var stream = AskStream(repo: nil)
            var events: [AskEvent] = []
            for line in AskFixtures.success() { events += stream.feed(line) }
            check(events.first == .started(model: "claude-fixture"), "first event: \(String(describing: events.first))")
            check(events.contains(.tool("Searching for “kill db”")), "tool use not described: \(events)")
            let text = events.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
            check(text == AskFixtures.answer && stream.finalAnswer == AskFixtures.answer, "streamed text differs from the answer")
            check(!events.contains(.newTurn), "a tool-only first turn should not clear anything")
            check(stream.result?.isError == false && stream.result?.costUSD == 0.0123 && stream.rateLimit?.status == "allowed",
                  "result or rate limit not read")
            check(AskFailure.classify(result: stream.result, exitStatus: 0, stderr: "", rateLimit: stream.rateLimit) == nil, "success classified as failure")

            var partial = AskStream()
            for line in AskFixtures.streaming() { _ = partial.feed(line) }
            check(!partial.answer.isEmpty && AskFixtures.answer.hasPrefix(partial.answer) && partial.answer.count < AskFixtures.answer.count
                  && partial.result == nil, "mid-answer stream should hold a prefix of the answer")

            var narrated = AskStream(repo: "/repo")
            var seen: [AskEvent] = []
            for line in AskFixtures.narrated { seen += narrated.feed(line) }
            check(seen.contains(.newTurn) && seen.contains(.tool("Reading services/orders/outbox/relay.go")), "narration then tool: \(seen)")
            check(narrated.answer == "The [relay](strata:node/orders/relay) polls every 500 ms." && narrated.finalAnswer == narrated.answer,
                  "the answer should be the last turn: \(narrated.answer)")

            var whole = AskStream()
            let wholeEvents = AskFixtures.wholeMessages.flatMap { whole.feed($0) }
            check(wholeEvents.contains(.text("One line.")) && whole.finalAnswer == "One line.", "whole messages without partials")

            var noisy = AskStream()
            _ = noisy.feed("Error: something went wrong")
            _ = noisy.feed("{not json")
            check(noisy.noise.count == 2 && noisy.result == nil, "non-JSON lines should be kept as noise")
        },
        CheckCase(name: "ask failures read as calm messages with what to do") {
            func failure(_ lines: [String], status: Int32 = 1, stderr: String = "") -> AskFailure? {
                var stream = AskStream()
                for line in lines { _ = stream.feed(line) }
                return AskFailure.classify(result: stream.result, exitStatus: status, stderr: stderr, rateLimit: stream.rateLimit)
            }
            check(failure(AskFixtures.notLoggedIn) == .notLoggedIn, "not logged in")
            check(AskFailure.notLoggedIn.message.contains("Run `claude` once in a terminal to log in"), "login message")
            check(failure(AskFixtures.rateLimited) == .rateLimited(resets: Date(timeIntervalSince1970: 1795112400)), "rate limited")
            check(failure([], stderr: "API Error: 529 Overloaded") == .overloaded, "overloaded")
            check(failure([], stderr: "Invalid API key · Please run /login") == .notLoggedIn, "stderr login")
            check(failure([], stderr: "error: unknown option '--tools'\n") == .failed("error: unknown option '--tools'"), "other errors keep their first line")
            check(failure([], status: 0) == nil, "a clean exit without a result is not a failure")
            check(AskFailure.timedOut(seconds: 90).message.contains("90 s"), "timeout message")
            check(AskFailure.notInstalled.message.contains("ask: { claude:"), "not installed message names the config key")
        },
        CheckCase(name: "ask finds claude: config, then the login shell, then known locations") {
            let executable: Set<String> = ["/custom/claude", "/shell/bin/claude", "/home/.local/bin/claude", "/opt/homebrew/bin/claude"]
            let isExecutable: @Sendable (String) -> Bool = { executable.contains($0) }
            let shell = ClaudeLocator.ShellAnswer(claude: "/shell/bin/claude", path: "/shell/bin:/usr/bin")
            let configured = ClaudeLocator(configured: "/custom/claude", shell: { shell },
                                           candidates: ["/home/.local/bin/claude"], isExecutable: isExecutable).locate()
            check(configured == .init(path: "/custom/claude", via: "config"), "config path should win: \(String(describing: configured))")
            let missing = ClaudeLocator(configured: "/nope/claude", shell: { shell }, candidates: ["/home/.local/bin/claude"],
                                        isExecutable: isExecutable).locate()
            check(missing == nil, "a configured path that isn't executable should not fall back")
            let fromShell = ClaudeLocator(configured: nil, shell: { shell }, candidates: ["/home/.local/bin/claude"],
                                          isExecutable: isExecutable).locate()
            check(fromShell == .init(path: "/shell/bin/claude", via: "login shell", searchPath: "/shell/bin:/usr/bin"), "login shell")
            let alias = ClaudeLocator(configured: nil, shell: { .init(claude: "claude: aliased to ~/x", path: "/usr/bin") },
                                      candidates: ["/nope", "/home/.local/bin/claude", "/opt/homebrew/bin/claude"],
                                      isExecutable: isExecutable).locate()
            check(alias == .init(path: "/home/.local/bin/claude", via: "known location", searchPath: "/usr/bin"), "first executable candidate")
            let none = ClaudeLocator(configured: nil, shell: { nil }, candidates: ["/nope"], isExecutable: isExecutable).locate()
            check(none == nil, "nothing found")
            let known = ClaudeLocator.knownLocations(home: "/Users/x")
            check(known.first == "/Users/x/.local/bin/claude" && known.contains("/opt/homebrew/bin/claude")
                  && known.contains("/Users/x/.claude/local/claude"), "known locations: \(known)")
        },
        CheckCase(name: "ask invokes claude headless, streaming, with read-only tools only") {
            let args = AskInvocation.arguments(model: nil, repo: nil)
            func value(_ flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
            check(args.first == "-p" && value("--output-format") == "stream-json" && args.contains("--verbose")
                  && args.contains("--include-partial-messages"), "headless streaming flags: \(args)")
            check(value("--tools") == "Read,Grep,Glob" && value("--append-system-prompt") == AskPrompt.system, "tools and system prompt")
            let allowed = args.firstIndex(of: "--allowedTools").map { Array(args[($0 + 1)...].prefix { !$0.hasPrefix("--") }) }
            check(allowed == ["Read", "Grep", "Glob"], "allowed tools: \(String(describing: allowed))")
            let denied = args.firstIndex(of: "--disallowedTools").map { Array(args[($0 + 1)...].prefix { !$0.hasPrefix("--") }) } ?? []
            check(["Bash", "Edit", "Write", "WebFetch", "WebSearch"].allSatisfy(denied.contains), "denied tools: \(denied)")
            check(args.contains("--strict-mcp-config") && args.contains("--no-session-persistence") && !args.contains("--model")
                  && !args.contains { $0.contains("dangerously") || $0.contains("bypass") }, "no model by default, nothing that skips permissions")
            let withRepo = AskInvocation.arguments(model: "haiku", repo: "/code/x")
            check(withRepo.suffix(4) == ["--add-dir", "/code/x", "--model", "haiku"], "repo and model: \(withRepo.suffix(4))")
            let env = AskInvocation.environment(base: ["PATH": "/usr/bin:/bin", "CLAUDECODE": "1", "HOME": "/Users/x"],
                                                searchPath: "/Users/x/.nvm/bin:/usr/bin", claude: "/Users/x/.local/bin/claude")
            check(env["CLAUDECODE"] == nil && env["HOME"] == "/Users/x", "nested-session marker should be dropped")
            check(env["PATH"]?.hasPrefix("/Users/x/.nvm/bin:/usr/bin:/bin:/Users/x/.local/bin") == true, "PATH order: \(env["PATH"] ?? "")")
        },
        CheckCase(name: "ask prompt carries the digest, where the user is, and the question last") {
            let m = try askExample("checkout")
            let digest = AskDigest.build(m, file: "/tmp/checkout.yaml")
            let message = AskPrompt.message(question: "  Who writes orders.status? ", manifest: m, digest: digest, file: "/tmp/checkout.yaml",
                                            focus: AskFocus(path: ["orders"], node: "relay"), repoOnDisk: false,
                                            previous: AskExchangeContext(question: "What is the relay?", answer: "It polls."))
            check(message.hasPrefix("<map-digest>\n") && message.contains(digest.text), "digest first")
            check(message.contains("Manifest file: /tmp/checkout.yaml") && message.contains("The map names no repo"), "file and repo")
            check(message.contains("level orders (inside orders-svc), with node relay \"Outbox relay\" [worker] selected"), "focus line")
            check(message.contains("Their previous question, for follow-ups: What is the relay?"), "previous exchange")
            check(message.hasSuffix("Question: Who writes orders.status?\n"), "question last, trimmed")
            for example in ["strata:node/", "strata:op/", "strata:how/", "strata:enum/", "strata:table/", "strata:level/"] {
                check(AskPrompt.system.contains(example), "system prompt doesn't teach \(example)")
            }
        },
        CheckCase(name: "ask suggestions come from the map and the selection") {
            let m = try askExample("checkout")
            let map = AskSuggestions.make(m, focus: AskFocus())
            check(map == AskSuggestions.make(m, focus: AskFocus()) && (1...4).contains(map.count), "map suggestions: \(map)")
            check(map.contains("Who writes orders.status?"), "status column question: \(map)")
            let db = AskSuggestions.make(m, focus: AskFocus(node: "db"))
            check(db.first == "What breaks if Orders DB is down for 30 s?" && db.contains("Which queries hit Orders DB?")
                  && !db.contains("What happens if Orders DB is down for 30 s?"), "db: \(db)")
            check(AskSuggestions.make(m, focus: AskFocus(path: ["orders"], node: "relay")).contains("How does outbox relay claim, publish and ack work?"),
                  "mechanism question for the relay")
            check(AskSuggestions.make(m, focus: AskFocus(path: ["nope"])).isEmpty, "no level, no suggestions")
        },
        CheckCase(name: "ask history and settings round-trip in a private directory") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("strata-ask-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let history = AskHistory(manifestID: "checkout", root: root)
            check(history.load().isEmpty, "empty at first")
            let date = Date(timeIntervalSince1970: 1_800_000_000)
            try history.append(AskRecord(id: "a", date: date, question: "q1", answer: "a1", path: ["orders"], node: "relay"))
            try history.append(AskRecord(id: "b", date: date, question: "q2", answer: "", status: .failed, error: "Not logged in"))
            let loaded = history.load()
            check(loaded.map(\.id) == ["a", "b"] && loaded[0].path == ["orders"] && loaded[1].status == .failed && loaded[0].date == date,
                  "records: \(loaded)")
            check(history.load(limit: 1).map(\.id) == ["b"], "limit keeps the newest")
            let mode = (try? FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int) ?? 0
            check(mode == 0o700, "ask directory should be private, is \(String(mode, radix: 8))")
            try history.clear()
            check(history.load().isEmpty && !FileManager.default.fileExists(atPath: history.url.path), "clear removes the file")
            check(AskSettings.load(root: root) == AskSettings(), "default settings")
            try AskSettings(enabled: false, acknowledged: ["checkout"]).save(root: root)
            check(AskSettings.load(root: root) == AskSettings(enabled: false, acknowledged: ["checkout"]), "settings round trip")
        },
        CheckCase(name: "ask config reads enabled, model and claude") {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("strata-ask-config-\(UUID().uuidString).yaml")
            defer { try? FileManager.default.removeItem(at: url) }
            try Data("ask:\n  enabled: false\n  model: haiku\n  claude: ~/bin/claude\n".utf8).write(to: url)
            let (config, diagnostics) = ConfigLoader.load(url)
            check(diagnostics.isEmpty && !config.ask.enabled && config.ask.model == "haiku" && config.ask.claude == "~/bin/claude",
                  "config: \(config.ask) \(diagnostics)")
            try Data("ask: { modle: x }\n".utf8).write(to: url)
            check(ConfigLoader.load(url).1.contains { $0.message.contains("did you mean 'model'") }, "typo warning")
            check(StrataConfig().ask.enabled && StrataConfig().ask.model == nil, "defaults: on, the user's default model")
        },
        CheckCase(name: "ask runner streams a fake claude, reports failures, timeouts and stop") {
            try askDirectory { root in
                let m = try askExample("checkout")
                func run(_ script: String, idle: TimeInterval = 20, cancelAfter: TimeInterval? = nil) throws -> (AskOutcome, [AskEvent]) {
                    let fake = root.appendingPathComponent("claude-\(UUID().uuidString)")
                    try Data(("#!/bin/sh\n" + script).utf8).write(to: fake)
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
                    let found = ClaudeLocator.Found(path: fake.path, via: "test")
                    let (invocation, _) = AskSession.invocation(question: "q", manifest: m, file: nil, focus: AskFocus(), claude: found, model: nil)
                    let runner = AskRunner(invocation)
                    runner.idleTimeout = idle
                    let done = DispatchSemaphore(value: 0)
                    let box = AskCheckBox()
                    try runner.start(onEvent: { box.add($0) }, onFinish: { box.outcome = $0; done.signal() })
                    if let cancelAfter {
                        Thread.sleep(forTimeInterval: cancelAfter)
                        runner.cancel()
                    }
                    guard done.wait(timeout: .now() + 15) == .success, let outcome = box.outcome else {
                        throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "runner never finished"])
                    }
                    return (outcome, box.events)
                }
                let stream = root.appendingPathComponent("success.jsonl")
                try Data(AskFixtures.success().joined(separator: "\n").utf8).write(to: stream)
                let input = root.appendingPathComponent("stdin.txt")
                let (ok, events) = try run("cat > '\(input.path)'\ncat '\(stream.path)'\n")
                check(ok.failure == nil && !ok.cancelled && ok.answer == AskFixtures.answer && ok.model == "claude-fixture",
                      "fake run: \(ok)")
                check(events.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined() == AskFixtures.answer, "streamed events")
                let sent = (try? String(contentsOf: input, encoding: .utf8)) ?? ""
                check(sent.hasPrefix("<map-digest>\nMAP checkout") && sent.hasSuffix("Question: q\n"), "prompt goes to stdin")

                let (failed, _) = try run("cat > /dev/null\necho 'Not logged in · Please run /login' >&2\nexit 1\n")
                check(failed.failure == .notLoggedIn, "login failure from stderr: \(failed)")
                let (slow, _) = try run("cat > /dev/null\nsleep 30\n", idle: 1)
                check(slow.failure == .timedOut(seconds: 1), "idle timeout: \(slow)")
                let (stopped, _) = try run("cat > /dev/null\nsleep 30\n", cancelAfter: 0.4)
                check(stopped.cancelled && stopped.failure == nil, "stop: \(stopped)")
            }
        },
        CheckCase(name: "strata ask prints the digest without sending, and streams a fake claude") {
            try askDirectory { root in
                guard let checkout = StrataResources.url("Examples/checkout.yaml") else { check(false, "missing checkout"); return }
                let home = root.appendingPathComponent("home")
                try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
                let digest = try askCLI(["ask", checkout.path, "who writes orders.status?", "--digest"], home: home, cwd: root)
                check(digest.status == 0 && digest.stdout.hasPrefix("<map-digest>\nMAP checkout")
                      && digest.stdout.hasSuffix("Question: who writes orders.status?\n") && digest.stderr.contains("tier 0, nothing cut"),
                      "digest: \(digest.status) \(digest.stderr)")
                let focused = try askCLI(["ask", checkout.path, "q", "--digest", "--path", "orders", "--node", "relay", "--budget", "9000"],
                                         home: home, cwd: root)
                check(focused.status == 0 && focused.stdout.contains("with node relay \"Outbox relay\" [worker] selected")
                      && focused.stderr.contains("cut:"), "focused digest: \(focused.stderr)")
                let badNode = try askCLI(["ask", checkout.path, "q", "--node", "nope"], home: home, cwd: root)
                check(badNode.status == 1 && badNode.stderr.contains("no node 'nope'"), "bad node: \(badNode.stderr)")

                try Data("ask: { enabled: false }\n".utf8).write(to: home.appendingPathComponent("config.yaml"))
                let off = try askCLI(["ask", checkout.path, "q"], home: home, cwd: root)
                check(off.status == 1 && off.stderr.contains("Ask is off"), "disabled: \(off.stderr)")

                let stream = root.appendingPathComponent("success.jsonl")
                try Data(AskFixtures.success().joined(separator: "\n").utf8).write(to: stream)
                let fake = root.appendingPathComponent("fake-claude")
                try Data("#!/bin/sh\ncat > /dev/null\ncat '\(stream.path)'\n".utf8).write(to: fake)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
                try Data("ask: { claude: \(fake.path) }\n".utf8).write(to: home.appendingPathComponent("config.yaml"))
                let answered = try askCLI(["ask", checkout.path, AskFixtures.question], home: home, cwd: root)
                check(answered.status == 0 && answered.stdout == AskFixtures.answer + "\n" && answered.stderr.contains("· Searching for “kill db”"),
                      "fake answer: \(answered.status) \(answered.stdout) \(answered.stderr)")
            }
        },
    ]
}

private func askExample(_ id: String) throws -> Manifest {
    guard let url = StrataResources.url("Examples/\(id).yaml") else { throw CocoaError(.fileNoSuchFile) }
    let (manifest, diagnostics) = ManifestParser.parse(try String(contentsOf: url, encoding: .utf8), source: .bundled(url))
    guard let manifest else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "\(diagnostics)"]) }
    return manifest
}

private func askDirectory(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("strata-ask-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

private final class AskCheckBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [AskEvent] = []
    private var _outcome: AskOutcome?
    var events: [AskEvent] { lock.lock(); defer { lock.unlock() }; return _events }
    var outcome: AskOutcome? {
        get { lock.lock(); defer { lock.unlock() }; return _outcome }
        set { lock.lock(); _outcome = newValue; lock.unlock() }
    }
    func add(_ event: AskEvent) { lock.lock(); _events.append(event); lock.unlock() }
}

private func askCLI(_ args: [String], home: URL, cwd: URL) throws -> (status: Int32, stdout: String, stderr: String) {
    let cli = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("strata")
    let process = Process()
    process.executableURL = cli
    process.arguments = args
    process.currentDirectoryURL = cwd
    var environment = ProcessInfo.processInfo.environment
    environment["STRATA_HOME"] = home.path
    process.environment = environment
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: watchdog)
    let stdout = out.fileHandleForReading.readDataToEndOfFile()
    let stderr = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    watchdog.cancel()
    return (process.terminationStatus, String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self))
}
