import Foundation
import StrataCore

// How it works and Formulas (docs/manifest.md): decoding, validation, playback with TTL expiry,
// the bundled roster lesson, and `strata how`.

private let howSource = ManifestSource.file(URL(fileURLWithPath: "/checks/how.yaml"))
private let howHeader = "strata: 1\nid: how\ntitle: How check\n"

/// Wraps the How it works and Formulas reference fences in a manifest: the node they describe and the
/// store the roster's participants link to. nil for any other fence.
func howSpecFence(_ text: String) -> String? {
    func indent(_ text: String) -> String { text.components(separatedBy: "\n").map { "  " + $0 }.joined(separator: "\n") }
    if text.hasPrefix("- id: scheduler"), text.contains("\n  how:") {
        return howHeader + "nodes:\n" + indent(text) + "\n  - {id: valkey, kind: cache}"
    }
    if text.hasPrefix("- id: ranker"), text.contains("\n  formula:") {
        return howHeader + "nodes:\n" + indent(text)
    }
    return nil
}

private func parse(_ body: String) -> (Manifest?, [Diagnostic]) {
    ManifestParser.parse(howHeader + body, source: howSource)
}

private func specFence(containing marker: String) throws -> String {
    guard let fence = try referenceFences().first(where: { $0.contains(marker) }), let wrapped = howSpecFence(fence) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return wrapped
}

@MainActor func howChecks() -> [CheckCase] {
    [
        CheckCase(name: "how reference fences decode cleanly") {
            let (manifest, diagnostics) = ManifestParser.parse(try specFence(containing: "\n  how:"), source: howSource)
            check(manifest != nil && diagnostics.isEmpty, "how fence: \(diagnostics)")
            guard let roster = manifest?.root.node("scheduler")?.how.first else { check(false, "no mechanism"); return }
            check(roster.id == "roster" && roster.title == "Roster membership with heartbeats", "mechanism header")
            check(roster.participants.map(\.id) == ["a", "b", "v"] && roster.participants[2].node == "valkey", "participants")
            check(roster.initial == [StateEntry(key: "roster:members", value: "{}")], "initial: \(roster.initial)")
            check(roster.steps.map(\.id) == ["join", "hb1", "hb2"], "step ids")
            check(roster.steps.map(\.at) == [0, 5, 10], "step times")
            check(roster.steps[0].command == "SET roster:inst:a 1 NX PX 15000" && roster.steps[0].reply == "OK", "command and reply")
            check(roster.steps[0].state == [StateEntry(key: "roster:inst:a", value: "1", ttl: 15)], "state with ttl")
            check(roster.steps[2].note?.contains("Two heartbeats") == true, "note")
            check(roster.code == ["internal/roster/roster.go:40"], "code")
            let crash = roster.branches.first
            check(crash?.id == "crash" && crash?.after == "hb1" && crash?.steps.map(\.id) == ["expire", "take"], "branch")
            check(crash?.steps[0].state == [StateEntry(key: "roster:inst:a", value: nil)], "value: null deletes")
            check(crash?.steps[1].at == nil && crash?.steps[1].command == "SCAN 0 MATCH roster:inst:*", "branch step")

            let (ranked, findings) = ManifestParser.parse(try specFence(containing: "\n  formula:"), source: howSource)
            check(ranked != nil && findings.isEmpty, "formula fence: \(findings)")
            let formula = ranked?.root.node("ranker")?.formula
            check(formula?.expr == "score = w_r · e^(−age / τ) + w_c · ctr − p · spam", "expr")
            check(formula?.vars.map(\.name) == ["w_r", "τ", "ctr", "p"], "where keys keep their order: \(formula?.vars.map(\.name) ?? [])")
            check(formula?.example?.hasPrefix("age 3 h") == true && formula?.code == ["internal/rank/score.go:22"], "example and code")
        },
        CheckCase(name: "how decodes default ids, durations, op mechanisms and formulas") {
            let (manifest, diagnostics) = parse("""
                nodes:
                  - id: svc
                    kind: service
                    ops:
                      - id: lock
                        kind: cache
                        target: kv
                        label: Take the lock
                        formula: { expr: "wait = n · t", where: { n: holders ahead, t: hold time } }
                        how:
                          - id: lock
                            title: Lock
                            participants: [{ id: c, label: client }, { id: kv, kind: redis }]
                            steps:
                              - { from: c, to: kv, command: "SET lock 1 NX PX 250", reply: OK, at: 250ms, state: [{ key: lock, value: 1, ttl: 250ms }] }
                              - { from: kv, to: kv, label: expires, at: 500ms, state: [{ key: lock, value: null }] }
                            branches:
                              - { id: early, label: Released early, steps: [{ from: c, to: kv, label: release, state: [{ key: lock, value: { owner: c } }] }] }
                  - { id: kv, kind: cache }
                edges: [{ from: svc, to: kv }]
                """)
            check(manifest != nil && diagnostics.isEmpty, "unexpected findings: \(diagnostics)")
            guard let op = manifest?.root.node("svc")?.ops.first, let mechanism = op.how.first else { check(false, "no op mechanism"); return }
            check(mechanism.steps.map(\.id) == ["s1", "s2"], "default step ids: \(mechanism.steps.map(\.id))")
            check(mechanism.steps[0].label == "SET lock 1 NX PX 250", "label defaults to the command")
            check(mechanism.steps.map(\.at) == [0.25, 0.5], "millisecond times")
            check(mechanism.steps[0].state.first?.ttl == 0.25 && mechanism.steps[0].state.first?.value == "1", "numeric value and ttl")
            check(mechanism.participants[1].kind == .cache && mechanism.participants[1].label == "kv", "participant kind and label")
            check(mechanism.branches.first?.after == nil && mechanism.branches.first?.steps.first?.id == "early-s1", "branch default ids")
            check(mechanism.branches.first?.steps.first?.state.first?.value == "{ \"owner\": \"c\" }", "mapping values become JSON")
            check(op.formula?.vars.map(\.name) == ["n", "t"], "op formula")
            check(mechanism.play(branch: "early")?.frames.map(\.step.id) == ["early-s1"], "a branch without after starts at the beginning")
        },
        CheckCase(name: "how validation errors and warnings") {
            let (manifest, diagnostics) = parse("""
                nodes:
                  - id: svc
                    kind: service
                    formula: { expr: "y = a · x", where: { a: slope, b: unused, x: input } }
                    how:
                      - id: m
                        title: M
                        participants: [{ id: a }, { id: a }, { id: s, node: stor }]
                        steps:
                          - { id: one, from: a, to: s, at: 5s }
                          - { id: one, from: a, to: q, at: 2s }
                        branches:
                          - { id: br, label: B, after: on, steps: [{ from: x, to: a }] }
                          - { id: br, label: C, after: one, steps: [{ from: a, to: a, at: 4s }] }
                  - { id: store, kind: cache }
                """)
            check(manifest == nil, "errors should reject the manifest")
            func has(_ severity: Diagnostic.Severity, _ path: String, _ text: String) {
                check(diagnostics.contains { $0.severity == severity && $0.path == path && $0.message.contains(text) },
                      "expected \(severity) at \(path) containing '\(text)', got \(diagnostics)")
            }
            has(.error, "nodes.svc.how.m.participants.a.id", "duplicate participant 'a'")
            has(.error, "nodes.svc.how.m.participants.s.node", "unknown node 'stor'; did you mean 'store'?")
            has(.error, "nodes.svc.how.m.steps.one.id", "duplicate step 'one'")
            has(.error, "nodes.svc.how.m.steps.one.to", "unknown participant 'q'")
            has(.warning, "nodes.svc.how.m.steps.one.at", "goes back in time")
            has(.error, "nodes.svc.how.m.branches.br.after", "unknown step 'on'; after names a step of the main sequence; did you mean 'one'?")
            has(.error, "nodes.svc.how.m.branches.br.steps[0].from", "unknown participant 'x'")
            has(.error, "nodes.svc.how.m.branches.br.id", "duplicate branch 'br'")
            has(.warning, "nodes.svc.how.m.branches.br.steps[0].at", "at 4s goes back in time; the step before it is at 5s")
            has(.warning, "nodes.svc.formula.where.b", "'b' does not appear in expr")
            check(!diagnostics.contains { $0.path == "nodes.svc.formula.where.a" || $0.path == "nodes.svc.formula.where.x" }, "used keys flagged")

            let (_, missing) = parse("""
                nodes:
                  - id: svc
                    kind: service
                    how: [{ id: m, title: M, participants: [{ id: a }], steps: [{ from: a, to: a, state: [{ key: k }] }] }]
                """)
            check(missing.contains { $0.severity == .error && $0.message.contains("write value: null to delete") }, "value is required: \(missing)")
        },
        CheckCase(name: "how formula mentions match whole symbols") {
            let formula = Formula(expr: "score = w_r · e^(−age / τ) + w_c · ctr − p · spam")
            for name in ["score", "w_r", "τ", "ctr", "p", "spam", "age", "w", "e"] {
                check(formula.mentions(name), "'\(name)' should appear")
            }
            for name in ["r", "c", "s", "pa", "sp", "core", ""] {
                check(!formula.mentions(name), "'\(name)' should not appear")
            }
            check(Formula(expr: "owner(s) = argmax_(m ∈ M) h(m, s)").mentions("M"), "subscript groups")
        },
        CheckCase(name: "how playback ages TTLs and expires keys") {
            let (manifest, _) = ManifestParser.parse(try specFence(containing: "\n  how:"), source: howSource)
            guard let roster = manifest?.root.node("scheduler")?.how.first, let main = roster.play() else { check(false, "no roster"); return }
            check(main.timed && main.branchStart == nil && main.frames.map(\.time) == [0, 5, 10], "main times")
            check(main.initial == [MechKey(key: "roster:members", value: "{}")], "initial state")
            check(main.frames[0].changes == [MechChange(key: "roster:inst:a", kind: .set)], "register sets")
            check(main.frames[1].changes == [MechChange(key: "roster:inst:a", kind: .renew)], "heartbeat renews: \(main.frames[1].changes)")
            check(main.frames[1].state.last == MechKey(key: "roster:inst:a", value: "1", ttl: 15, span: 15), "renewed to the full ttl")
            check(main.frames[2].state.last?.ttl == 10, "no renewal at hb2 leaves 10 s: \(main.frames[2].state)")
            let aged = main.state(after: 1, at: 17)
            check(aged.keys.last?.ttl == 3 && aged.keys.last?.remaining == 0.2 && aged.expired.isEmpty, "aged mid-gap: \(aged)")
            check(main.state(after: 1, at: 20).expired == ["roster:inst:a"], "expires at its deadline")
            check(main.state(after: -1, at: 3).keys == main.initial, "the initial state has no ttl to age")

            guard let crash = roster.play(branch: "crash") else { check(false, "no crash branch"); return }
            check(crash.frames.map(\.step.id) == ["join", "hb1", "expire", "take"] && crash.branchStart == 2, "crash path")
            check(crash.frames.map(\.branch) == [nil, nil, "crash", "crash"], "branch tags")
            check(crash.frames[2].time == 20 && crash.frames[3].time == 20, "a step without at keeps the time before it")
            check(crash.frames[2].changes == [MechChange(key: "roster:inst:a", kind: .expire)], "the TTL ran out: \(crash.frames[2].changes)")
            check(!crash.frames[2].state.contains { $0.key == "roster:inst:a" }, "expired key is gone")
            check(roster.play(branch: "nope") == nil && roster.path(branch: "nope") == nil, "unknown branch")
        },
        CheckCase(name: "how playback keeps time monotonic and applies deletes and renames in order") {
            var mechanism = Mechanism(id: "m", title: "M")
            mechanism.participants = [Participant(id: "a")]
            var first = MechStep(id: "one", from: "a", to: "a", label: "one")
            first.at = 4
            first.state = [StateEntry(key: "k", value: "1", ttl: 2), StateEntry(key: "j", value: "x")]
            var second = MechStep(id: "two", from: "a", to: "a", label: "two")
            second.at = 1
            second.state = [StateEntry(key: "j", value: nil), StateEntry(key: "gone", value: nil)]
            var third = MechStep(id: "three", from: "a", to: "a", label: "three")
            third.at = 7
            mechanism.steps = [first, second, third]
            guard let playback = mechanism.play() else { check(false, "no playback"); return }
            check(playback.frames.map(\.time) == [4, 4, 7], "an earlier at plays at the time before it: \(playback.frames.map(\.time))")
            check(playback.frames[1].changes == [MechChange(key: "j", kind: .delete)], "deleting a missing key changes nothing")
            check(playback.frames[2].changes == [MechChange(key: "k", kind: .expire)] && playback.frames[2].state.isEmpty, "k expired at 6 s")
            check(playback.duration == 7, "duration")
        },
        CheckCase(name: "how bundled roster lesson plays every branch") {
            let library = Library(builtIn: try requiredResource("Examples"), dirs: [])
            guard let entry = library.entry("valkey-roster"), let manifest = entry.manifest else { check(false, "missing valkey-roster"); return }
            check(entry.diagnostics.isEmpty && manifest.category == "distributed", "roster diagnostics: \(entry.diagnostics)")
            let sites = manifest.mechanisms()
            check(sites.map(\.owner) == ["scheduler", "scheduler/fenced-write"], "mechanism sites: \(sites.map(\.owner))")
            let fence = sites.last?.mechanism
            check(fence?.timed == false && fence?.play(branch: "stale")?.branchStart == 0, "an untimed branch from the start")
            check(fence?.play(branch: "stale")?.frames.last?.state.first { $0.key == "shard:7:cursor" }?.value == "job-4410",
                  "a refused write leaves the cursor alone")
            check(manifest.root.node("scheduler")?.formula != nil, "scheduler formula")
            check(manifest.root.node("scheduler")?.ops.first { $0.id == "heartbeat" }?.formula != nil, "heartbeat formula")
            guard let roster = sites.first?.mechanism else { return }
            check(roster.branches.map(\.id) == ["crash", "partition", "leave"], "branches")
            let main = roster.play()
            check(main?.frames.filter { $0.step.label.hasPrefix("heartbeat") }.map(\.time) == [5, 10, 15], "heartbeat rhythm")
            let crash = roster.play(branch: "crash")
            let expiry = crash?.frames.first { $0.changes.contains(MechChange(key: "roster:inst:a", kind: .expire)) }
            check(expiry?.time == 20 && expiry?.step.id == "expire", "A's key expires 15 s after heartbeat 1")
            check(crash?.frames.last?.state.first { $0.key == "shard:7:epoch" }?.value == "4", "B takes shard 7 with epoch 4")
            let partition = roster.play(branch: "partition")
            check(partition?.frames.first { $0.step.id == "expire" }?.time == 25, "partition expiry")
            check(partition?.frames.first { $0.step.id == "fenced" }?.step.reply?.contains("STALE") == true, "fencing rejects epoch 3")
            check(partition?.frames.last?.state.first { $0.key == "roster:inst:a" }?.ttl == 15, "A rejoins with a fresh key")
            let leave = roster.play(branch: "leave")
            check(leave?.frames.first { $0.step.id == "release" }?.changes == [MechChange(key: "roster:inst:a", kind: .delete)], "graceful delete")
            for playback in [main, crash, partition, leave] {
                let times = playback?.frames.map(\.time) ?? []
                check(zip(times, times.dropFirst()).allSatisfy { $0 <= $1 }, "time goes backwards: \(times)")
            }
            let checkout = library.manifest("checkout")
            check(checkout?.mechanisms().map(\.owner) == ["relay"], "checkout relay mechanism: \(checkout?.mechanisms().map(\.owner) ?? [])")
            check(checkout?.root.node("orders")?.ops.contains { $0.formula != nil } == true, "checkout price formula")
        },
        CheckCase(name: "how cli prints a numbered transcript") {
            let cli = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
                .deletingLastPathComponent().appendingPathComponent("strata")
            let examples = try requiredResource("Examples").appendingPathComponent("valkey-roster.yaml")
            let full = try runCLI(cli, ["how", examples.path])
            check(full.status == 0, "how failed: \(full.output)")
            check(full.output.contains("scheduler · roster: Roster membership with heartbeats"), "header: \(full.output.prefix(200))")
            check(full.output.contains("  1  t=0s   instance A → Valkey      A registers"), "numbered step: \(full.output.prefix(800))")
            check(full.output.contains("SET roster:inst:a 10.0.1.7:7070 NX PX 15000  →  OK"), "command and reply")
            check(full.output.contains("roster:inst:a = 10.0.1.7:7070 (ttl 15s, renewed)"), "renewed state")
            check(full.output.contains("branch crash: A crashes after heartbeat 1 (after step 6 hb1)"), "branch header")
            check(full.output.contains("roster:inst:a expired"), "expiry in the transcript")
            let branch = try runCLI(cli, ["how", examples.path, "--mechanism", "roster", "--branch", "partition"])
            check(branch.status == 0 && branch.output.contains("branch partition:") && !branch.output.contains("main sequence"),
                  "branch path: \(branch.output.prefix(400))")
            check(branch.output.contains("(error) STALE epoch 3, current 4"), "fenced write in the branch")
            let unknown = try runCLI(cli, ["how", examples.path, "--branch", "nope"])
            check(unknown.status == 1 && unknown.output.contains("unknown branch 'nope'; choose crash, partition, leave, stale"), "unknown branch: \(unknown.output)")
            let help = try runCLI(cli, ["--help"])
            check(help.output.contains("how <file|id> [--mechanism id] [--branch id]"), "help lists how")
        },
    ]
}

private func runCLI(_ executable: URL, _ args: [String]) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = executable
    process.arguments = args
    var environment = ProcessInfo.processInfo.environment
    environment["STRATA_HOME"] = FileManager.default.temporaryDirectory.appendingPathComponent("strata-how-checks").path
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}
