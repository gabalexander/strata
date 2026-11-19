import Foundation
import StrataCore

// The How it works player's text helpers (StepText.swift): reading a step's command, fitting keys and
// labels into their room, and spacing the sequence diagram's rows and columns. Synthetic keys only.

@MainActor func howTextChecks() -> [CheckCase] {
    // One point per character: lengths stand in for widths.
    let chars: (String) -> Double = { Double($0.count) }
    let lockKey = "app:billing-jobs:locks:sweep:nightly-invoice-run"
    return [
        CheckCase(name: "how text: a step's command reads as SQL, Valkey or anything else") {
            check(StepCommand.kind("SET roster:inst:a 10.0.1.7:7070 NX PX 15000") == .redis, "SET with a key")
            check(StepCommand.kind("SELECT id FROM jobs WHERE state = ?") == .sql, "SELECT")
            check(StepCommand.kind("SELECT 1") == .sql, "SELECT 1 is a SQL ping, not a database switch")
            check(StepCommand.kind("SET LOCAL lock_timeout = '1s'") == .sql, "SET LOCAL is SQL")
            check(StepCommand.kind("SET search_path TO app") == .sql, "SET … TO is SQL")
            check(StepCommand.kind("BEGIN;\nUPDATE jobs SET state = ? WHERE id = ?;\nCOMMIT;") == .sql, "a transaction")
            check(StepCommand.kind("hincrby counts:jobs done 1") == .redis, "lowercase Valkey commands")
            check(StepCommand.kind("basic.publish exchange=jobs routing_key=done") == .other, "AMQP")
            check(StepCommand.kind("JobService/Claim{worker: \"w1\"}") == .other, "gRPC")
            check(StepCommand.kind("POST /v1/jobs") == .other, "HTTP")
            check(StepCommand.kind("redis.call('GET', KEYS[1])") == .other, "a line of Lua")
            check(StepCommand.redis("GET a\nGET b") == nil, "two commands on two lines are not one command")
        },
        CheckCase(name: "how text: a Valkey command splits into verb, keys and arguments") {
            check(StepCommand.redis("SET \(lockKey) 1801 NX PX 15000") == .init(verb: "SET", keys: [lockKey], args: ["1801", "NX", "PX", "15000"]),
                  "SET: \(String(describing: StepCommand.redis("SET \(lockKey) 1801 NX PX 15000")))")
            check(StepCommand.redis("GETDEL job:7") == .init(verb: "GETDEL", keys: ["job:7"]), "one key, no arguments")
            check(StepCommand.redis("EVALSHA d23e6359f2 2 roster:z roster:epoch w1 40000")
                  == .init(verb: "EVALSHA", script: "d23e6359f2", keys: ["roster:z", "roster:epoch"], args: ["w1", "40000"]), "EVALSHA: numkeys keys")
            check(StepCommand.redis("FCALL fenced_set 2 shard:7:epoch shard:7:cursor 3 job-4411")?.script == "fenced_set", "FCALL names its function")
            check(StepCommand.redis("DEL a b c") == .init(verb: "DEL", keys: ["a", "b", "c"]), "DEL: every argument is a key")
            check(StepCommand.redis("MSET a 1 b 2") == .init(verb: "MSET", keys: ["a", "b"], args: ["1", "2"]), "MSET: keys and values alternate")
            check(StepCommand.redis("XREADGROUP GROUP g c COUNT 10 STREAMS jobs events > >")?.keys == ["jobs", "events"], "XREADGROUP: keys after STREAMS")
            check(StepCommand.redis("SCAN 0 MATCH roster:inst:* COUNT 100") == .init(verb: "SCAN", args: ["0", "MATCH", "roster:inst:*", "COUNT", "100"]),
                  "SCAN has no key")
            check(StepCommand.redis("CLIENT SETNAME worker-1") == .init(verb: "CLIENT SETNAME", args: ["worker-1"]), "a subcommand")
            check(StepCommand.redis("SET greeting \"hello there\" EX 60")?.args == ["\"hello there\"", "EX", "60"], "a quoted argument stays whole")
            check(StepCommand.tokens("SET a \"open") == nil, "an unclosed quote")
        },
        CheckCase(name: "how text: a long key is cut in the middle between its segments") {
            check(TextFit.middle("roster:inst:a", limit: 20) == "roster:inst:a", "short keys stay whole")
            check(TextFit.middle(lockKey, limit: 26) == "app:…:nightly-invoice-run", "first and last segment: \(TextFit.middle(lockKey, limit: 26))")
            check(TextFit.middle(lockKey, limit: 32) == "app:…:sweep:nightly-invoice-run", "more of the end: \(TextFit.middle(lockKey, limit: 32))")
            for limit in [5, 12, 22, 36, 50, 60] {
                check(TextFit.middle(lockKey, limit: limit).count <= limit, "fits \(limit): \(TextFit.middle(lockKey, limit: limit))")
            }
            check(TextFit.middle(lockKey, limit: 12) == "app:…ice-run", "too short for whole segments: cut between characters, \(TextFit.middle(lockKey, limit: 12))")
            check(TextFit.middle("abcdefghijklmnopqrstuvwxyz", limit: 11) == "abcd…uvwxyz", "no separators: \(TextFit.middle("abcdefghijklmnopqrstuvwxyz", limit: 11))")
            check(TextFit.middle("abc", limit: 1) == "…" && TextFit.middle("abc", limit: 0) == "", "tiny limits")
            check(TextFit.unbroken(TextFit.softBreaks(lockKey)) == lockKey && TextFit.softBreaks("a:b") == "a:\u{200B}b",
                  "soft breaks after separators, removed again for copying")
        },
        CheckCase(name: "how text: labels wrap onto two lines and end in an ellipsis") {
            let one = TextFit.wrap("A takes the lock", width: 40, maxLines: 2, measure: chars)
            check(one.lines == ["A takes the lock"] && !one.truncated, "fits on one line: \(one)")
            let two = TextFit.wrap("A reads the lock module's epoch", width: 18, maxLines: 2, measure: chars)
            check(two.lines == ["A reads the lock", "module's epoch"] && !two.truncated, "two lines: \(two)")
            let cut = TextFit.wrap("list undispatched attempts on a slow pass", width: 14, maxLines: 2, measure: chars)
            check(cut.lines.count == 2 && cut.truncated && cut.lines[1].hasSuffix("…") && cut.lines.allSatisfy { $0.count <= 14 },
                  "cut on the last line: \(cut)")
            let word = TextFit.wrap("supercalifragilistic", width: 8, maxLines: 2, measure: chars)
            check(word.lines.count == 2 && word.lines[0] == "supercal" && word.lines.allSatisfy { $0.count <= 8 } && word.truncated, "a word wider than the line breaks: \(word)")
            let whole = TextFit.wrap("sweeper pod A", width: 5, maxLines: 2, breakWords: false, measure: chars)
            check(whole.lines == ["swee…", "pod A"] && whole.truncated, "words kept whole, each line cut short: \(whole)")
            check(TextFit.ellipsize("heartbeat 2", width: 8, measure: chars) == "heartbe…", "ellipsize: \(TextFit.ellipsize("heartbeat 2", width: 8, measure: chars))")
        },
        CheckCase(name: "how text: diagram chips keep the reply and cut keys in the middle") {
            let set = "SET \(lockKey) 1801234500000 NX PX 15000"
            let one = StepCommand.lines(command: "GET roster:epoch", reply: "\"3\"", chars: 60)
            check(one.count == 1 && one[0].text == "GET roster:epoch\u{0}\"3\"" && !one[0].cut, "command and reply on one line: \(one)")
            let two = StepCommand.lines(command: set, reply: "OK", chars: 48)
            check(two.count == 2 && two[1].text == "\u{0}OK" && !two[1].cut, "the reply on its own line: \(two)")
            check(two[0].text.hasPrefix("SET app:") && two[0].text.hasSuffix(" 1801234500000 NX PX 15000") && two[0].text.contains("…") && two[0].cut,
                  "verb and arguments kept, key cut: \(two[0].text)")
            check(two[0].text.count <= 48, "fits: \(two[0].text.count)")
            let sql = StepCommand.lines(command: "SELECT id,\n  state\nFROM jobs\nWHERE state = ?", reply: nil, chars: 80)
            check(sql.count == 1 && sql[0].text == "SELECT id, state FROM jobs WHERE state = ?" && !sql[0].cut, "SQL on one line: \(sql)")
            let long = StepCommand.shortened("SELECT id, state, owner, created_at FROM jobs WHERE state = ? ORDER BY created_at", chars: 30)
            check(long.text.count == 30 && long.text.hasSuffix("…") && long.cut, "cut at the end: \(long)")
            let script = StepCommand.shortened("EVALSHA d23e6359f2a8c1b0e9 2 roster:z roster:epoch w1 40000", chars: 50)
            check(script.text.hasPrefix("EVALSHA d23e6359… 2 roster:z"), "a script hash shortened first: \(script.text)")
            check(StepCommand.lines(command: nil, reply: "(nil)", chars: 20).map(\.text) == ["\u{0}(nil)"], "a reply alone")
            check(StepCommand.lines(command: nil, reply: nil, chars: 20).isEmpty, "nothing to show")
        },
        CheckCase(name: "how text: rows grow to fit their text, plus their time gap") {
            typealias Row = SequenceGeometry.RowExtent
            // The player's single-line rows: 22 above the arrow, 24 below, 16 apart.
            let flat = SequenceGeometry.rows([Row(above: 22, below: 24), Row(above: 22, below: 24), Row(above: 22, below: 24)],
                                             top: 14, spacing: 16, minPitch: 46)
            check(flat == [36, 98, 160], "single lines keep a 62 pt pitch: \(flat)")
            let tall = SequenceGeometry.rows([Row(above: 22, below: 46), Row(above: 37, below: 24)], top: 14, spacing: 16, minPitch: 46)
            check(tall == [36, 135], "a two-line reply and a two-line label push the next row down: \(tall)")
            let timed = SequenceGeometry.rows([Row(above: 22, below: 24, gap: 6), Row(above: 22, below: 24, gap: 30)], top: 14, spacing: 16, minPitch: 46)
            check(timed == [42, 134], "time gaps add room: \(timed)")
            let bare = SequenceGeometry.rows([Row(above: 10, below: 8), Row(above: 10, below: 8)], top: 0, spacing: 16, minPitch: 46)
            check(bare == [10, 56], "never closer than the minimum pitch: \(bare)")
        },
        CheckCase(name: "how text: participant columns spread out, then alternate tiers, then truncate") {
            let roomy = SequenceGeometry.columns(widths: [100, 80, 90], left: 0, right: 600, gap: 10)
            check(roomy.tiers == 1 && roomy.caps == [100, 80, 90] && roomy.xs.first == 50 && roomy.xs.last == 555, "one tier: \(roomy)")
            let tight = SequenceGeometry.columns(widths: [120, 120, 120, 120, 120, 120], left: 0, right: 600, gap: 10)
            check(tight.tiers == 2 && tight.caps.allSatisfy { $0 == 120 }, "neighbours too close: two tiers, \(tight)")
            let steps = zip(tight.xs, tight.xs.dropFirst(2)).map { $1 - $0 }
            check(steps.allSatisfy { $0 >= 130 }, "every other box clears its neighbour: \(tight.xs)")
            let cramped = SequenceGeometry.columns(widths: [150, 150, 150, 150, 150, 150], left: 0, right: 400, gap: 10)
            check(cramped.tiers == 2 && cramped.caps.allSatisfy { $0 < 150 }, "even two tiers too tight: boxes truncate, \(cramped)")
            let capSteps = zip(cramped.xs, cramped.xs.dropFirst(2)).map { $1 - $0 }
            check(zip(capSteps, cramped.caps).allSatisfy { $0 + 1 >= $1 + 10 }, "and still never overlap: \(cramped)")
            check(cramped.xs[0] - cramped.caps[0] / 2 >= -0.5 && cramped.xs[5] + cramped.caps[5] / 2 <= 400.5, "nor leave the diagram: \(cramped)")
            check(SequenceGeometry.columns(widths: [90], left: 0, right: 300, gap: 10).xs == [150], "one participant sits in the middle")
        },
        CheckCase(name: "how text: path chips fit two lines, the rest behind +N more") {
            let more: (Int) -> Double = { _ in 20 }
            check(SequenceGeometry.fitChips([30, 30, 30], lineWidth: 100, maxLines: 2, spacing: 5, more: more) == [0, 1, 2], "all fit")
            let some = SequenceGeometry.fitChips([40, 40, 40, 40, 40, 40], lineWidth: 100, maxLines: 2, spacing: 5, more: more)
            check(some == [0, 1, 2], "as many as fit with the more chip on the last line: \(some)")
            let kept = SequenceGeometry.fitChips([40, 40, 40, 40, 40, 40], lineWidth: 100, maxLines: 2, spacing: 5, more: more, keep: 5)
            check(kept == [0, 1, 5], "the selected chip always shows: \(kept)")
        },
        CheckCase(name: "how text: a step's code decodes") {
            let source = """
            strata: 1
            id: how-code
            title: How code
            nodes:
              - id: worker
                kind: service
                how:
                  - id: claim
                    title: Claim a job
                    participants: [ { id: w, label: worker }, { id: v, label: Valkey } ]
                    steps:
                      - { from: w, to: v, command: "SET job:7:owner w NX PX 30000", reply: OK, code: internal/claim.go:42 }
                      - { from: w, to: v, command: "GET job:7:owner", code: [internal/claim.go:60, internal/owner.go:12] }
            """
            let (manifest, diagnostics) = ManifestParser.parse(source, source: .file(URL(fileURLWithPath: "/checks/how-code.yaml")))
            check(diagnostics.isEmpty, "diagnostics: \(diagnostics)")
            let steps = manifest?.root.node("worker")?.how.first?.steps ?? []
            check(steps.map(\.code) == [["internal/claim.go:42"], ["internal/claim.go:60", "internal/owner.go:12"]], "code: \(steps.map(\.code))")
        },
    ]
}
