import Foundation
import StrataCore

private func node(_ id: String, _ kind: NodeKind, _ configure: (inout NodeParams) -> Void = { _ in }) -> Node {
    var node = Node(id: id, kind: kind)
    configure(&node.params)
    return node
}

private func source(_ rate: Rate, _ steps: [Step], deadline: Double? = nil) -> Flow {
    var flow = Flow(id: "requests")
    flow.from = "client"
    flow.rate = rate
    flow.deadline = deadline
    flow.steps = steps
    return flow
}

private func consumer(_ id: String, _ buffer: String, _ worker: String) -> Flow {
    var flow = Flow(id: id)
    flow.on = buffer
    flow.by = worker
    return flow
}

private func call(_ target: String, _ steps: [Step] = [], miss: [Step] = [],
                  _ configure: (inout Step) -> Void = { _ in }) -> Step {
    var step = Step(.call(target: target, steps: steps, miss: miss))
    configure(&step)
    return step
}

private func manifest(_ nodes: [Node], _ flows: [Flow], edges: [Edge] = [], scenarios: [Scenario] = []) -> Manifest {
    var level = Level()
    level.nodes = [Node(id: "client", kind: .client)] + nodes
    level.edges = edges
    level.flows = flows
    level.scenarios = scenarios
    return Manifest(id: "checks", title: "Engine checks", root: level, source: .inline(note: "Checks", index: 0))
}

@MainActor private func sim(_ nodes: [Node], _ flows: [Flow], edges: [Edge] = [], seed: UInt64 = 1) -> Simulation {
    Simulation(manifest: manifest(nodes, flows, edges: edges), seed: seed)
}

@MainActor private func state(_ sim: Simulation, _ id: String) -> NodeState {
    sim.frame().nodes[id]!
}

private func measure(_ format: String, _ values: CVarArg...) {
    print(String(format: format, arguments: values))
}

@MainActor func engineChecks() -> [CheckCase] {
    [
        CheckCase(name: "engine determinism and reset") {
            let a = Simulation(manifest: Fixtures.checkout, seed: 42)
            let b = Simulation(manifest: Fixtures.checkout, seed: 42)
            a.run(seconds: 20)
            for _ in 0..<200 { b.run(seconds: 0.1) }
            let first = a.metrics(flow: "place-order")
            let other = b.metrics(flow: "place-order")
            check(first.totalOK == other.totalOK && first.totalFailed == other.totalFailed && first.totalOK > 0,
                  "the same seed varied with the size of each advance")
            let expected = a.report()
            a.reset()
            a.run(seconds: 20)
            check(a.report() == expected, "reset did not replay the same traffic")
        },
        CheckCase(name: "engine M/M/c utilization") {
            let sim = sim([node("server", .service) { $0.latency = .exponential(0.02); $0.concurrency = 4 }],
                          [source(.perSecond(120), [call("server")])], seed: 5)
            sim.run(seconds: 60)
            let utilization = sim.series(.node("server", .util)).reduce(0, +) / 240
            measure("M/M/4 utilization %.3f (expected 0.600)", utilization)
            check(abs(utilization - 0.6) <= 0.06, "utilization was \(utilization)")
        },
        CheckCase(name: "engine overload queue and 503") {
            let sim = sim([node("server", .service) {
                $0.latency = .fixed(0.03); $0.concurrency = 1; $0.queue = 12
            }], [source(.every(0.1), [call("server")])])
            sim.run(seconds: 10)
            let baseline = sim.metrics(flow: "requests").p99 ?? 0
            sim.perform([.rate("requests", .every(0.004))])
            sim.run(seconds: 12)
            let server = state(sim, "server")
            let flow = sim.metrics(flow: "requests")
            measure("Overload queue %d/12, errors %.1f/s, p99 %.1f → %.1f ms",
                    server.queued, server.errors, baseline * 1000, (flow.p99 ?? 0) * 1000)
            check(server.queued >= 11 && server.utilization == 1, "waiting room did not saturate")
            check(server.errors > 150 && sim.log.contains { $0.text.contains("503") }, "overload should return 503")
            check(flow.p99 ?? 0 > baseline * 8, "waiting room added no tail latency")
        },
        CheckCase(name: "engine retry amplification") {
            let sim = sim([node("db", .database) { $0.errors = 1 }],
                          [source(.every(0.04), [call("db") { $0.retries = 2; $0.backoff = 0.01 }])])
            sim.run(seconds: 12)
            let source = sim.metrics(flow: "requests")
            let factor = state(sim, "db").arrivals / source.started
            measure("Retry amplification %.2f×, retries %.1f/s", factor, source.retries)
            check(abs(factor - 3) < 0.1 && source.totalFailed > 250 && source.totalOK == 0,
                  "retries did not translate to three real arrivals")
        },
        CheckCase(name: "engine cut, fast refusal and silent loss") {
            let cut = sim([node("db", .database)], [source(.manual, [call("db") { $0.timeout = 0.5 }])])
            cut.perform([.cut("client", "db"), .send("requests", 5)])
            cut.run(seconds: 0.25)
            check(cut.metrics(flow: "requests").inFlight == 5 && state(cut, "db").arrivals == 0,
                  "cut link failed fast or reached the database")
            cut.run(seconds: 0.3)
            check(cut.metrics(flow: "requests").totalFailed == 5 && cut.metrics(flow: "requests").timeouts > 0,
                  "cut requests did not time out")
            check(cut.log.contains { $0.text.contains("timeout after 0.5s at client → db") }, "timeout omitted the link")
            cut.run(seconds: 0.5)
            let timeoutLog = cut.log.filter { $0.text.contains("timeout") || $0.text.contains("timed out") }
            check(timeoutLog.count == 1 && timeoutLog[0].text.contains("5 requests timed out"),
                  "a timeout flood should keep one log line with an accurate count")
            let infinite = sim([node("db", .database)], [source(.manual, [call("db")])])
            infinite.perform([.cut("client", "db"), .send("requests", 5), .heal("client", "db")])
            infinite.run(seconds: 5)
            check(infinite.metrics(flow: "requests").inFlight == 5, "healing revived packets that had been dropped")
            infinite.perform([.kill("db"), .send("requests", 1)])
            infinite.run(seconds: 0.02)
            check(infinite.metrics(flow: "requests").totalFailed == 1, "a down target did not refuse immediately")
            infinite.setValue(.number(1), for: Binding(.edge(from: "client", to: "db"), "loss"))
            infinite.send("requests")
            infinite.run(seconds: 5)
            check(infinite.metrics(flow: "requests").inFlight == 6, "100% loss did not silently drop the request")
        },
        CheckCase(name: "engine kill in-flight and queued work, then restore") {
            let sim = sim([node("db", .database) {
                $0.latency = .fixed(0.5); $0.concurrency = 1; $0.queue = 8
            }], [source(.manual, [call("db")])])
            sim.send("requests", count: 4)
            sim.run(seconds: 0.1)
            check(state(sim, "db").busy == 1 && state(sim, "db").queued == 3, "expected running and queued jobs")
            sim.perform([.kill("db"), .send("requests", 2)])
            sim.run(seconds: 0.02)
            let down = state(sim, "db")
            check(down.health == .down && down.busy == 0 && down.queued == 0, "kill left occupied slots or queued work")
            check(sim.metrics(flow: "requests").totalFailed == 6, "kill did not reset every pending request")
            check(sim.log.contains { $0.text.contains("connection reset") }, "kill did not explain connection resets")
            sim.perform([.slow("db", 10), .fail("db", 1), .restore("db"), .send("requests", 2)])
            sim.run(seconds: 1.1)
            check(sim.metrics(flow: "requests").totalOK == 2, "restore did not clear injected latency and errors")
        },
        CheckCase(name: "engine slow dependency holds sync slots and releases async slots") {
            @MainActor func make(_ async: Bool) -> Simulation {
                sim([node("api", .service) { $0.concurrency = 4; $0.latency = .fixed(0.004); $0.async = async },
                     node("db", .database) { $0.concurrency = 256; $0.latency = .fixed(0.05) }],
                    [source(.every(0.025), [call("api", [Step(.parallel([call("db"), Step(.work(.fixed(0.01)))]))])])])
            }
            let sync = make(false)
            let async = make(true)
            for sim in [sync, async] {
                sim.perform([.slow("db", 10)])
                sim.run(seconds: 5)
            }
            let a = state(sync, "api")
            let b = state(async, "api")
            measure("Slow DB, sync API %d busy/%d queued, async API %d busy/%d queued", a.busy, a.queued, b.busy, b.queued)
            check(a.busy == 4 && a.queued == 100 && b.busy < 4 && b.queued == 0,
                  "async changed slot accounting incorrectly")
            check(async.metrics(flow: "requests").totalOK > sync.metrics(flow: "requests").totalOK * 3,
                  "async traffic did not complete")
        },
        CheckCase(name: "engine cache miss and down cache fallback") {
            let sim = sim([node("cache", .cache), node("db", .database)],
                          [source(.every(0.005), [call("cache", miss: [call("db")])])], seed: 13)
            sim.run(seconds: 10)
            let fraction = state(sim, "db").arrivals / state(sim, "cache").arrivals
            measure("Cache miss fraction %.3f", fraction)
            check((0.075...0.125).contains(fraction), "expected approximately 10% misses")
            sim.perform([.kill("cache")])
            sim.run(seconds: 6)
            check((195...205).contains(state(sim, "db").arrivals), "a down cache should send every read to db")
            check(sim.metrics(flow: "requests").totalFailed == 0, "a down cache should be a miss")
        },
        CheckCase(name: "engine queue crash and replica prefetch") {
            @MainActor func make(_ prefetch: Int, _ ack: AckMode) -> Simulation {
                sim([node("queue", .queue), node("worker", .worker) {
                    $0.concurrency = 1; $0.replicas = 2; $0.prefetch = prefetch; $0.ack = ack; $0.latency = .fixed(0.5)
                }], [source(.manual, [Step(.publish(target: "queue"))]), consumer("consume", "queue", "worker")])
            }
            let shallow = make(1, .manual)
            let deep = make(50, .manual)
            let auto = make(1, .auto)
            for sim in [shallow, deep, auto] {
                sim.send("requests", count: 14)
                sim.run(seconds: 0.1)
                check(state(sim, "worker").busy == 2, "round robin should use both worker replicas")
            }
            let a = state(shallow, "queue")
            let b = state(deep, "queue")
            measure("Two replicas, unacked with prefetch 1 vs 50: %d vs %d", a.unacked, b.unacked)
            check(a.unacked == 2 && a.depth == 12, "prefetch 1 should reserve one message on each replica")
            check(b.unacked == 14 && b.depth == 0 && state(deep, "worker").queued == 12,
                  "prefetch 50 should place the backlog with the consumers")
            for sim in [deep, auto] {
                sim.perform([.kill("worker")])
                sim.run(seconds: 0.1)
            }
            measure("Worker kill, manual requeued %d and lost %d, auto lost %d",
                    state(deep, "queue").depth, state(deep, "queue").lost, state(auto, "queue").lost)
            check(state(deep, "queue").depth == 14 && state(deep, "queue").lost == 0, "manual crash lost messages")
            check(state(auto, "queue").depth == 0 && state(auto, "queue").lost == 14, "auto crash should lose its buffer")
            let autoFlow = auto.metrics(flow: "consume")
            check(autoFlow.totalFailed == 14 && autoFlow.inFlight == 0, "auto crash left delivered messages in flight")
            deep.perform([.restore("worker")])
            deep.run(seconds: 4)
            check(deep.metrics(flow: "consume").totalOK == 14, "restored worker did not process every requeued message")
        },
        CheckCase(name: "engine queue TTL and poison messages reach the DLQ") {
            let ttl = sim([node("queue", .queue) { $0.ttl = 0.1; $0.dlq = "dlq" }, node("dlq", .queue)],
                          [source(.manual, [Step(.publish(target: "queue"))])])
            ttl.send("requests", count: 3)
            ttl.run(seconds: 0.2)
            check(state(ttl, "queue").depth == 0 && state(ttl, "dlq").depth == 3, "TTL did not route into the DLQ")
            let poison = sim([node("queue", .queue) { $0.dlq = "dlq" }, node("dlq", .queue),
                              node("worker", .worker) { $0.errors = 1; $0.maxDeliveries = 3 }],
                             [source(.manual, [Step(.publish(target: "queue"))]), consumer("consume", "queue", "worker")])
            poison.send("requests", count: 2)
            poison.run(seconds: 1)
            let failures = poison.metrics(flow: "consume").totalFailed
            measure("DLQ retained %d expired and %d poison messages, across %d failed handler attempts",
                    state(ttl, "dlq").depth, state(poison, "dlq").depth, failures)
            check(failures == 6 && state(poison, "dlq").depth == 2 && state(poison, "queue").unacked == 0,
                  "maxDeliveries did not stop requeueing")
        },
        CheckCase(name: "engine topics deliver every message per group and retain finite history") {
            let sim = sim([node("topic", .topic), node("fast", .worker) { $0.latency = .fixed(0.01) },
                           node("slow", .worker) { $0.latency = .fixed(0.2); $0.concurrency = 1 }],
                          [source(.manual, [Step(.publish(target: "topic"))]),
                           consumer("first", "topic", "fast"), consumer("second", "topic", "slow")])
            sim.send("requests", count: 20)
            sim.run(seconds: 0.5)
            let lag = state(sim, "topic").lag
            measure("Topic lag after 0.5 s, fast %d, slow %d", lag["fast"] ?? -1, lag["slow"] ?? -1)
            check(lag["fast"] == 0 && (lag["slow"] ?? 0) >= 17, "the slow group should have independent lag")
            sim.run(seconds: 4)
            check(sim.metrics(flow: "first").totalOK == 20 && sim.metrics(flow: "second").totalOK == 20,
                  "both groups should receive every record")
            sim.perform([.kill("slow"), .set(Binding(.node("topic"), "capacity"), .number(10))])
            sim.send("requests", count: 15)
            sim.run(seconds: 0.5)
            let retained = state(sim, "topic")
            check(retained.depth == 10 && (retained.lag["slow"] ?? 0) == 10 && retained.lost >= 5,
                  "retention should drop unread offsets and count losses")
        },
        CheckCase(name: "engine breaker opens, trials retry and recover") {
            let sim = sim([node("db", .database) { $0.errors = 1 }],
                          [source(.manual, [call("db") { $0.breaker = Breaker(failures: 2, cooldown: 0.5) }])])
            for _ in 0..<2 { sim.send("requests"); sim.run(seconds: 0.03) }
            check(sim.frame().edges["client->db"]?.breakerOpen == true, "breaker did not open")
            sim.send("requests", count: 5)
            sim.run(seconds: 0.1)
            check(abs(state(sim, "db").arrivals * sim.now - 2) < 0.01, "open breaker leaked traffic")
            sim.run(seconds: 0.5)
            sim.send("requests", count: 3)
            sim.run(seconds: 0.1)
            check(sim.frame().edges["client->db"]?.breakerOpen == true, "a failed trial should reopen the breaker")
            check(abs(state(sim, "db").arrivals * sim.now - 3) < 0.01, "half-open breaker let more than one trial through")
            sim.perform([.fail("db", 0)])
            sim.run(seconds: 0.5)
            sim.send("requests")
            sim.run(seconds: 0.03)
            check(sim.frame().edges["client->db"]?.breakerOpen == false && sim.metrics(flow: "requests").totalOK == 1,
                  "a successful trial should close the breaker")
        },
        CheckCase(name: "engine redirect and parallel wait") {
            let parallel = Step(.parallel([call("primary"), call("fast")]))
            let sim = sim([node("primary", .service) { $0.latency = .fixed(0.8) },
                           node("replica", .service) { $0.latency = .fixed(0.3) },
                           node("fast", .service) { $0.latency = .fixed(0.1) }],
                          [source(.manual, [parallel])])
            sim.perform([.redirect("primary", "replica"), .send("requests", 1)])
            sim.run(seconds: 0.2)
            check(sim.metrics(flow: "requests").inFlight == 1 && state(sim, "fast").busy == 0,
                  "parallel should wait for the slow branch")
            sim.run(seconds: 0.15)
            let latency = sim.metrics(flow: "requests").p50 ?? 0
            measure("Redirected parallel latency %.1f ms", latency * 1000)
            check(abs(latency - 0.302) < 1e-8 && state(sim, "primary").arrivals == 0 && state(sim, "replica").arrivals > 0,
                  "parallel latency should equal the redirected slow branch")
            sim.perform([.unredirect("primary"), .send("requests", 1)])
            sim.run(seconds: 1)
            check(state(sim, "primary").arrivals > 0 && sim.metrics(flow: "requests").totalOK == 2, "unredirect did not restore original routing")
        },
        CheckCase(name: "engine tokens: sampling, easing, response direction and orphaning") {
            var edge = Edge(from: "client", to: "db")
            edge.latency = .fixed(0.035)
            let sim = sim([node("db", .database) { $0.concurrency = 128; $0.latency = .fixed(0.005) }],
                          [source(.every(0.002), [call("db")])], edges: [edge])
            var ids = Set<Int>()
            var reverse = false
            for _ in 0..<1000 {
                sim.run(seconds: 0.001)
                for token in sim.frame().tokens {
                    if token.kind == .request { ids.insert(token.id) }
                    if token.kind == .response { reverse = reverse || token.reverse }
                    check((0...1).contains(token.progress), "token progress outside edge")
                }
            }
            measure("Visible request tokens in 1 s at 500/s: %d", ids.count)
            check((10...12).contains(ids.count) && reverse, "sampling or response direction was incorrect")
            let orphan = orphanResponse(edge)
            check(orphan.kind == .orphan && orphan.reverse, "response after deadline should travel as an orphan")
            let flows = (0..<805).map { index in
                var flow = source(.manual, [call("db")])
                flow.id = "traffic-\(index)"
                return flow
            }
            let capped = Simulation(manifest: manifest([node("db", .database)], flows, edges: [edge]))
            for flow in flows { capped.send(flow.id) }
            check(capped.frame().tokens.count == 800, "the global token ceiling did not apply across flows")
        },
        CheckCase(name: "engine topic groups sharing a worker each make progress") {
            let sim = sim([node("topic", .topic), node("worker", .worker) {
                $0.concurrency = 1
                $0.latency = .fixed(0.05)
            }], [source(.manual, [Step(.publish(target: "topic"))]),
                 consumer("first", "topic", "worker"), consumer("second", "topic", "worker")])
            sim.send("requests", count: 10)
            sim.run(seconds: 0.12)
            let topic = state(sim, "topic")
            check(topic.groupLag == ["first": 9, "second": 9] && topic.lag["worker"] == 18,
                  "each group should progress independently on the shared worker")
            sim.run(seconds: 1)
            check(sim.metrics(flow: "first").totalOK == 10 && sim.metrics(flow: "second").totalOK == 10,
                  "shared worker did not process every offset for both groups")
        },
        CheckCase(name: "engine optional failures, skipped steps and parent rate") {
            let optional = call("bad") { $0.optional = true }
            let skipped = call("skipped") { $0.p = 0 }
            let parallel = Step(.parallel([optional, skipped, Step(.work(.fixed(0.04)))]))
            let m = manifest([node("bad", .service) { $0.errors = 1 }, node("skipped", .service)],
                             [source(.parent, [parallel])])
            let sim = Simulation(manifest: m, parentRate: 30, seed: 57)
            let openedDirectly = Simulation(manifest: m)
            let bind = Binding(.flow("requests"), "rate")
            check(sim.value(bind) == .number(30) && openedDirectly.value(bind) == .number(5),
                  "parent rate did not follow its caller or the standalone default")
            sim.run(seconds: 10)
            let flow = sim.metrics(flow: "requests")
            check(flow.totalOK > 240 && flow.totalFailed == 0 && abs((flow.p50 ?? 0) - 0.04) < 1e-8,
                  "optional failure should allow the parent to finish after local work")
            check(state(sim, "bad").errors > 0 && state(sim, "skipped").arrivals == 0,
                  "optional work must run and a zero-probability step must not run")
        },
        CheckCase(name: "engine performance at 1000/s across five hops") {
            let nodes = (1...5).map { hop in node("hop\(hop)", .service) {
                $0.concurrency = 128; $0.latency = .fixed(0.002)
            } }
            let pipeline = nodes.reversed().reduce([Step]()) { [call($1.id, $0)] }
            let sim = sim(nodes, [source(.perSecond(1000), pipeline)], seed: 14)
            let clock = ContinuousClock()
            let start = clock.now
            sim.run(seconds: 10)
            let elapsed = start.duration(to: clock.now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18
            let completed = sim.metrics(flow: "requests")
            let tail = state(sim, "hop5").arrivals
            measure("Five hops, 10 s simulated in %.3f s, %d completed, %d failed, tail %.1f arrivals/s",
                    seconds, completed.totalOK, completed.totalFailed, tail)
            let started = completed.totalOK + completed.totalFailed + completed.inFlight
            check((9500...10500).contains(started) && completed.totalFailed == 0 && completed.inFlight < 50 && tail > 950,
                  "performance run skipped real work")
            check(seconds < 1, "10 s headless took \(seconds) s")

            sim.run(seconds: 2)
            var frames: [Double] = []
            for _ in 0..<625 {
                let start = clock.now
                sim.tick(0.016)
                let frame = sim.frame()
                let duration = start.duration(to: clock.now).components
                frames.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) * 1e-15)
                check(frame.nodes.count == 6 && frame.edges.count == 5, "frame omitted pipeline state")
            }
            frames.sort()
            let p50 = frames[frames.count / 2]
            let p99 = frames[frames.count * 99 / 100]
            measure("Tick + frame, 625 samples: p50 %.3f ms, p99 %.3f ms", p50, p99)
            check(p99 < 2, "engine frame budget exceeded at p99 (\(p99) ms)")
        },
        CheckCase(name: "engine commands, controls, scenarios and metric windows") {
            var step = ScenarioStep(at: 0.2)
            step.commands = [.slow("db", 2), .scale("db", 2, relative: true), .delay("client", "db", 0.005)]
            step.say = "Scenario narration"
            var scenario = Scenario(id: "test", label: "Test scenario")
            scenario.setup = [.rate("requests", .every(0.04))]
            scenario.steps = [step]
            let model = manifest([node("db", .database)], [source(.manual, [call("db") { $0.say = "First hop" }])],
                                 scenarios: [scenario])
            let sim = Simulation(manifest: model)
            let revision = sim.revision
            sim.start(scenario: "test")
            sim.tick(1)
            check(abs(sim.now - 0.1) < 1e-9 && sim.narration == "First hop", "tick clamp or step narration failed")
            sim.perform([.pause])
            sim.tick(1)
            check(abs(sim.now - 0.1) < 1e-9, "paused tick advanced time")
            sim.step()
            check(sim.narration == "Scenario narration" && sim.scenario == "test" && sim.revision > revision,
                  "timed scenario narration failed")
            check(sim.effective("db").replicas == 3 && sim.frame().edges["client->db"]?.extraLatency == 0.005,
                  "scenario scale or delay did not apply")
            let values: [(String, Value)] = [
                ("latency", .number(0.03)), ("queue", .number(2)), ("concurrency", .number(8)),
                ("errors", .number(0.1)), ("timeout", .number(0.4)), ("retries", .number(2)), ("backoff", .number(0.1)),
                ("async", .bool(true)), ("capacity", .number(9)), ("overflow", .string("drop-oldest")),
                ("ttl", .number(3)), ("dlq", .string("")), ("prefetch", .number(3)), ("ack", .string("auto")),
                ("onError", .string("drop")), ("maxDeliveries", .number(3)), ("hitRate", .number(0.8)),
            ]
            for (param, value) in values {
                let binding = Binding(.node("db"), param)
                sim.setValue(value, for: binding)
                check(sim.value(binding) == value, "binding did not round-trip \(param)")
            }
            sim.run(seconds: 11)
            check(sim.scenario == nil && sim.series(.node("db", .throughput)).count == 44, "scenario end or samples drifted")
            sim.perform([.rate("requests", .manual)])
            sim.run(seconds: 61)
            let after = sim.metrics(flow: "requests")
            check(after.started == 0 && after.p99 == nil && sim.series(.flow("requests", .rate)).count == 240,
                  "window did not expire old activity or retain exactly 240 samples")
        },
        CheckCase(name: "engine scenario commands apply durations and percentages") {
            let model = manifest([node("api", .service), node("cache", .cache)], [])
            let sim = Simulation(manifest: model)
            sim.perform(try ["set api.timeout 250ms", "set api.backoff 500ms", "set cache.hitRate 50%"]
                .map { try ManifestParser.parseCommand($0).get() })
            check(sim.effective("api").timeout == 0.25, "timeout command did not set 250 ms")
            check(sim.effective("api").backoff == 0.5, "backoff command did not set 500 ms")
            check(sim.effective("cache").hitRate == 0.5, "hit rate command did not set 50%")
        },
        CheckCase(name: "engine queue overflow, purge and topic retry") {
            let queue = sim([node("queue", .queue) { $0.capacity = 2 }],
                            [source(.manual, [Step(.publish(target: "queue"))])])
            queue.send("requests", count: 3)
            queue.run(seconds: 0.01)
            check(queue.metrics(flow: "requests").totalFailed == 1 && state(queue, "queue").depth == 2,
                  "reject overflow did not apply backpressure")
            queue.perform([.set(Binding(.node("queue"), "overflow"), .string("drop-oldest")), .send("requests", 3)])
            queue.run(seconds: 0.01)
            check(queue.metrics(flow: "requests").totalOK == 5 && state(queue, "queue").depth == 2,
                  "drop-oldest failed to replace ready messages")
            queue.perform([.purge("queue"), .kill("queue"), .send("requests", 1)])
            queue.run(seconds: 0.01)
            check(state(queue, "queue").depth == 0 && queue.metrics(flow: "requests").totalFailed == 2,
                  "purge or down-buffer refusal failed")

            let topic = sim([node("topic", .topic),
                             node("worker", .worker) { $0.concurrency = 1; $0.latency = .fixed(0.01); $0.backoff = 0.1; $0.errors = 1 }],
                            [source(.manual, [Step(.publish(target: "topic"))]), consumer("consume", "topic", "worker")])
            topic.send("requests", count: 3)
            topic.run(seconds: 0.05)
            check(topic.metrics(flow: "consume").totalFailed == 1 && state(topic, "topic").lag["worker"] == 3,
                  "topic retry did not block the next offset")
            topic.perform([.fail("worker", 0)])
            topic.run(seconds: 0.5)
            check(topic.metrics(flow: "consume").totalOK == 3 && state(topic, "topic").lag["worker"] == 0,
                  "topic retry did not continue from the failed offset")
        },
    ]
}

@MainActor private func orphanResponse(_ edge: Edge) -> TokenView {
    let sim = sim([node("db", .database) { $0.latency = .fixed(0.05) }],
                  [source(.manual, [call("db")], deadline: 0.1)], edges: [edge])
    sim.send("requests")
    sim.run(seconds: 0.105)
    let tokens = sim.frame().tokens
    check(tokens.count == 1, "deadline removed the downstream response")
    check(sim.metrics(flow: "requests").totalFailed == 1 && state(sim, "db").throughput > 0,
          "the caller should already have failed while the work still completed")
    return tokens.first ?? TokenView(id: -1, edge: "", progress: 0, reverse: false, kind: .request, color: 1, flow: "")
}
