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

private func op(_ id: String, _ kind: OpKind, target: String? = nil) -> StrataCore.Operation {
    var op = StrataCore.Operation(id: id, kind: kind, direction: target == nil || kind == .consume ? .inbound : .outbound)
    op.target = target
    return op
}

private func named(_ op: String, _ step: Step) -> Step {
    var step = step
    step.op = op
    return step
}

private func measure(_ format: String, _ values: CVarArg...) {
    print(String(format: format, arguments: values))
}

@MainActor func engineChecks() -> [CheckCase] {
    opEngineChecks() + [
        CheckCase(name: "engine runtime clamps allocating counts") {
            let sim = sim([node("worker", .worker)], [])
            sim.perform([.scale("worker", Int.max, relative: true)])
            check(sim.effective("worker").replicas == 64, "overflowing relative scale missed the replica cap")
            for (param, limit) in [("replicas", 64), ("concurrency", 100000), ("queue", 1000000),
                                   ("capacity", 1000000), ("prefetch", 100000)] {
                let binding = Binding(.node("worker"), param)
                sim.perform([.set(binding, .number(Double(limit + 1)))])
                check(sim.value(binding) == .number(Double(limit)), "set exceeded the \(param) cap")
                check(sim.log.contains { $0.text.contains("Clamped worker.\(param)") && $0.text.contains(String(limit)) },
                      "the \(param) clamp was silent")
            }
            let direct = Simulation(manifest: manifest([node("large", .worker) { $0.replicas = Int.max }], []))
            check(direct.effective("large").replicas == 64 && direct.log.contains { $0.text.contains("Clamped large.replicas") },
                  "programmatic construction allocated the unchecked replica count")
        },
        CheckCase(name: "engine tick pauses on zero-time message loops") {
            let edges = [("client", "queue"), ("queue", "worker"), ("worker", "queue")].map { from, to in
                var edge = Edge(from: from, to: to)
                edge.latency = .fixed(0)
                return edge
            }
            var loop = consumer("loop", "queue", "worker")
            loop.steps = [Step(.publish(target: "queue"))]
            let sim = sim([node("queue", .queue) { $0.latency = .fixed(0) },
                           node("worker", .worker) { $0.latency = .fixed(0) }],
                          [source(.manual, [Step(.publish(target: "queue"))]), loop], edges: edges)
            sim.send("requests")
            sim.tick(0.01)
            check(!sim.playing && sim.now == 0 && sim.log.contains {
                $0.text.contains("Paused: zero-time loop") && $0.text.contains("queue") && $0.text.contains("worker")
            }, "zero-time loop did not pause with a diagnostic at its timestamp")
            sim.perform([.cut("queue", "worker")])
            sim.playing = true
            sim.tick(0.01)
            check(sim.playing && sim.now == 0.01, "time did not advance after breaking the cycle")
        },
        CheckCase(name: "engine tick pauses when the event budget is exhausted") {
            let flows = (0..<24).map { index in
                var flow = Flow(id: "source-\(index)")
                flow.from = "client"
                flow.rate = .perSecond(10000)
                return flow
            }
            let sim = sim([], flows)
            sim.tick(0.1)
            check(!sim.playing && sim.now > 0 && sim.now < 0.1 && sim.log.contains { $0.text.contains("event budget") },
                  "positive-time event load did not pause within the tick")
        },
        CheckCase(name: "engine runtime caps sends and inherited flow rates") {
            let manual = sim([], [source(.manual, [])])
            manual.send("requests", count: Int.max)
            check(manual.metrics(flow: "requests").totalOK == 10000 &&
                  manual.log.contains { $0.text.contains("Clamped send on requests to 10000") },
                  "direct send exceeded the burst cap")

            let inherited = Simulation(manifest: manifest([], [source(.parent, [])]), parentRate: 1e12)
            check(inherited.value(Binding(.flow("requests"), "rate")) == .number(10000),
                  "parent rate bypassed the per-flow cap")
        },
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
        CheckCase(name: "engine topic poison messages unblock the group") {
            let sim = sim([node("topic", .topic) { $0.dlq = "dlq" }, node("dlq", .queue),
                           node("worker", .worker) {
                               $0.concurrency = 1; $0.errors = 1; $0.onError = .retry; $0.maxDeliveries = 2
                           }, node("healthy", .worker)],
                          [source(.manual, [Step(.publish(target: "topic"))]),
                           consumer("consume", "topic", "worker"), consumer("healthy", "topic", "healthy")])
            sim.send("requests", count: 2)
            sim.run(seconds: 2)
            check(sim.metrics(flow: "consume").totalFailed == 4 && state(sim, "topic").groupLag["consume"] == 0 &&
                  state(sim, "dlq").depth == 2, "poison messages exceeded two attempts or kept the group blocked")
            check(sim.metrics(flow: "healthy").totalOK == 2, "poison handling disturbed the other group")
        },
        CheckCase(name: "engine topic retry limit drops a killed handler without a DLQ") {
            let sim = sim([node("topic", .topic), node("worker", .worker) {
                $0.maxDeliveries = 1; $0.concurrency = 1; $0.latency = .fixed(0.1)
            }], [source(.manual, [Step(.publish(target: "topic"))]), consumer("consume", "topic", "worker")])
            sim.send("requests", count: 2)
            sim.run(seconds: 0.02)
            check(state(sim, "worker").busy == 1, "fixture had no active handler")
            sim.perform([.kill("worker"), .restore("worker")])
            sim.run(seconds: 0.5)
            check(sim.metrics(flow: "consume").totalFailed == 1 && sim.metrics(flow: "consume").totalOK == 1 &&
                  state(sim, "topic").groupLag["consume"] == 0 && state(sim, "topic").lost == 1,
                  "the killed handler retried after its final delivery or was missing from loss accounting")
        },
        CheckCase(name: "engine TTL expires prefetched messages before handling") {
            let nodes = [node("queue", .queue) { $0.ttl = 0.01; $0.dlq = "dlq" }, node("dlq", .queue),
                         node("worker", .worker) {
                             $0.concurrency = 1; $0.prefetch = 2; $0.latency = .fixed(0.1)
                         }]
            let flows = [source(.manual, [Step(.publish(target: "queue"))]), consumer("consume", "queue", "worker")]
            let inbox = sim(nodes, flows)
            inbox.send("requests", count: 2)
            inbox.run(seconds: 0.05)
            check(state(inbox, "queue").unacked == 1 && state(inbox, "worker").queued == 0 &&
                  state(inbox, "dlq").depth == 1, "expired inbox entry kept its reservation or missed the DLQ")
            inbox.run(seconds: 0.5)
            check(inbox.metrics(flow: "consume").totalOK == 1 && inbox.metrics(flow: "consume").inFlight == 0 &&
                  state(inbox, "queue").unacked == 0, "expiry allowed queued work to start or interrupted the active handler")

            var slowEdge = Edge(from: "queue", to: "worker")
            slowEdge.latency = .fixed(0.02)
            let transit = sim(nodes, flows, edges: [slowEdge])
            transit.send("requests")
            transit.run(seconds: 0.5)
            check(state(transit, "queue").unacked == 0 && state(transit, "dlq").depth == 1 &&
                  transit.metrics(flow: "consume").totalOK == 0, "expired delivery survived the trip to the worker")
        },
        CheckCase(name: "engine explicit topic rejection and default retention") {
            for overflow in [Overflow.reject, nil] {
                let sim = sim([node("topic", .topic) { $0.capacity = 1; $0.overflow = overflow }],
                              [source(.manual, [Step(.publish(target: "topic"))])])
                sim.send("requests", count: 2)
                sim.run(seconds: 0.01)
                let expectedFailures = overflow == .reject ? 1 : 0
                let metrics = sim.metrics(flow: "requests")
                check(metrics.totalFailed == expectedFailures && metrics.totalOK == 2 - expectedFailures &&
                      state(sim, "topic").depth == 1, "topic did not honor overflow mode \(String(describing: overflow))")
            }
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
        CheckCase(name: "engine open breaker rejects immediately without retries") {
            let sim = sim([node("db", .database) { $0.latency = .fixed(0); $0.errors = 1 }],
                          [source(.manual, [call("db") {
                              $0.breaker = Breaker(failures: 1, cooldown: 1)
                              $0.backoff = 0.1
                              $0.retries = 1
                          }])])
            sim.send("requests")
            sim.run(seconds: 0.01)
            check(sim.frame().edges["client->db"]?.breakerOpen == true, "fixture did not open the breaker")
            let before = sim.metrics(flow: "requests").totalFailed
            sim.send("requests")
            let metrics = sim.metrics(flow: "requests")
            check(metrics.totalFailed == before + 1 && metrics.inFlight == 1 && metrics.retries == 0,
                  "open circuit did not immediately fail the fresh request")
            sim.run(seconds: 0.2)
            check(sim.metrics(flow: "requests").totalFailed == 2 && sim.metrics(flow: "requests").retries == 0,
                  "open circuit left pending retry work")
        },
        CheckCase(name: "engine delay applies only to the named edge") {
            let sim = sim([node("db", .database) { $0.latency = .fixed(0) }], [source(.manual, [call("db")])],
                          edges: [Edge(from: "client", to: "db"), Edge(from: "db", to: "client")])
            sim.perform([.delay("client", "db", 0.2), .delay("db", "client", 0.03), .delay("db", "client", 0)])
            @MainActor func edges() -> (EdgeState?, EdgeState?) {
                let frame = sim.frame()
                return (frame.edges["client->db"], frame.edges["db->client"])
            }
            check(edges().0?.extraLatency == 0.2 && edges().1?.extraLatency == 0, "reversing or clearing delay disturbed the forward edge")
            sim.send("requests")
            sim.run(seconds: 0.5)
            check(abs((sim.metrics(flow: "requests").p50 ?? 0) - 0.402) < 1e-9, "reply did not use the request edge")
            sim.perform([.cut("client", "db")])
            check(edges().0?.cut == true && edges().1?.cut == true, "cut did not partition both directions")
            sim.perform([.heal("db", "client")])
            check(edges().0?.cut == false && edges().1?.cut == false, "heal did not restore both directions")
        },
        CheckCase(name: "engine buffer slow and error faults affect ingress") {
            for kind in [NodeKind.queue, .topic] {
                let sim = sim([node("buffer", kind) { $0.latency = .fixed(0.1) }],
                              [source(.manual, [Step(.publish(target: "buffer"))])])
                sim.perform([.slow("buffer", 10), .fail("buffer", 1)])
                sim.send("requests")
                sim.run(seconds: 0.99)
                check(sim.metrics(flow: "requests").inFlight == 1 && state(sim, "buffer").depth == 0,
                      "\(kind) accepted or rejected before the slowed ingest finished")
                sim.run(seconds: 0.02)
                check(sim.metrics(flow: "requests").totalFailed == 1 && state(sim, "buffer").depth == 0 &&
                      state(sim, "buffer").errors > 0, "\(kind) ignored its ingress error probability")
                check(abs((state(sim, "buffer").p99 ?? 0) - 1) < 1e-9, "\(kind) did not measure its slowed ingress latency")
                sim.perform([.restore("buffer")])
                sim.send("requests")
                sim.run(seconds: 0.11)
                check(sim.metrics(flow: "requests").totalOK == 1 && state(sim, "buffer").depth == 1,
                      "\(kind) did not resume successful ingress after restore")
                sim.send("requests")
                sim.run(seconds: 0.02)
                sim.perform([.kill("buffer"), .restore("buffer")])
                sim.run(seconds: 0.11)
                check(sim.metrics(flow: "requests").totalFailed == 2 && state(sim, "buffer").depth == 1,
                      "\(kind) stored a publish interrupted by a restart")
            }
            let normal = sim([node("queue", .queue)], [source(.manual, [Step(.publish(target: "queue"))])])
            normal.perform([.slow("queue", 10)])
            normal.send("requests")
            normal.run(seconds: 0.002)
            check(normal.metrics(flow: "requests").inFlight == 1, "default ingest latency was too short to slow")
            normal.run(seconds: 0.002)
            check(normal.metrics(flow: "requests").totalOK == 1, "default ingest latency did not complete")
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

@MainActor private func opEngineChecks() -> [CheckCase] {
    [
        CheckCase(name: "engine op metrics follow the steps that name them") {
            var api = node("api", .service)
            api.ops = [op("serve", .http), op("read", .sql, target: "db"), op("unused", .cache, target: "db")]
            let db = node("db", .database) { $0.latency = .fixed(0.005) }
            let flow = source(.perSecond(10), [named("serve", call("api", [named("read", call("db"))]))])
            let sim = sim([api, db], [flow], seed: 3)
            sim.run(seconds: 30)
            let serve = sim.opMetrics(node: "api", op: "serve")
            let read = sim.opMetrics(node: "api", op: "read")
            let unused = sim.opMetrics(node: "api", op: "unused")
            measure("Op at 10/s: serve %.2f/s p50 %.2f ms, read %.2f/s p50 %.2f ms p99 %.2f ms, %d total",
                    serve.rate, (serve.p50 ?? 0) * 1000, read.rate, (read.p50 ?? 0) * 1000, (read.p99 ?? 0) * 1000, read.total)
            check(serve.referenced && read.referenced && (8...12).contains(serve.rate) && (8...12).contains(read.rate),
                  "a 10/s flow should report about 10/s on its ops: serve \(serve.rate), read \(read.rate)")
            check((250...350).contains(read.total) && read.total == serve.total && read.errors == 0 && serve.errors == 0,
                  "op totals or errors: read \(read.total), serve \(serve.total)")
            check(abs((read.p50 ?? 0) - 0.007) < 0.0005 && (serve.p50 ?? 0) > (read.p50 ?? 0),
                  "op latency should run from step start to its result: read p50 \(read.p50 ?? -1)")
            check(!unused.referenced && unused.rate == 0 && unused.total == 0 && unused.p50 == nil, "an unreferenced op reported numbers")
            check(!sim.opMetrics(node: "api", op: "missing").referenced && !sim.opMetrics(node: "db", op: "read").referenced,
                  "a missing op reported numbers")
            let rates = sim.opSeries(node: "api", op: "read", metric: "rate")
            check(rates.count == 120 && (8...12).contains(rates.last ?? 0) && (sim.opSeries(node: "api", op: "read", metric: "p99").last ?? 0) > 0,
                  "op series should hold one sample per 0.25 s: \(rates.count)")
            check(sim.opSeries(node: "api", op: "serve", metric: "errors").allSatisfy { $0 == 0 } &&
                  sim.opSeries(node: "api", op: "read", metric: "p50").count == 120, "errors or p50 series")
            check(sim.opSeries(node: "api", op: "unused", metric: "rate").isEmpty &&
                  sim.opSeries(node: "api", op: "read", metric: "throughput").isEmpty, "unreferenced op or unknown metric has a series")
            let report = sim.report()
            check(report.contains("Op     Node  rate/s  err/s  p50 ms  p99 ms") && report.contains("\nread   ") && !report.contains("unused"),
                  "report has no ops table:\n\(report)")
            sim.reset()
            check(sim.opMetrics(node: "api", op: "read").total == 0 && sim.opSeries(node: "api", op: "read", metric: "rate").isEmpty,
                  "reset kept op numbers")
            check(!Simulation(manifest: manifest([node("db", .database)], [source(.perSecond(10), [call("db")])])).report().contains("Op"),
                  "a report without referenced ops shows an ops table")
        },
        CheckCase(name: "engine op errors count failed steps") {
            var api = node("api", .service)
            api.ops = [op("serve", .http), op("read", .sql, target: "db")]
            let db = node("db", .database) { $0.errors = 0.5 }
            let sim = sim([api, db], [source(.perSecond(10), [named("serve", call("api", [named("read", call("db"))]))])], seed: 9)
            sim.run(seconds: 30)
            let read = sim.opMetrics(node: "api", op: "read")
            let serve = sim.opMetrics(node: "api", op: "serve")
            measure("Op errors at 50%%: read %.2f/s of %.2f/s, serve %.2f/s", read.errors, read.rate, serve.errors)
            check((0.3...0.7).contains(read.errors / max(read.rate, 1)), "op errors should track the 50% failure rate: \(read.errors) of \(read.rate)")
            check(abs(serve.errors - read.errors) < 1e-9, "a failed nested step should fail the calling op too")
            sim.perform([.kill("db")])
            sim.run(seconds: 6)
            let down = sim.opMetrics(node: "api", op: "read")
            check(down.rate > 7 && abs(down.errors - down.rate) < 1e-9, "refused calls must count as op errors: \(down.errors) of \(down.rate)")
        },
        CheckCase(name: "engine op attribution for work, parallel, consumer and cache steps") {
            var api = node("api", .service) { $0.latency = .fixed(0.001) }
            api.ops = [op("think", .call), op("fanout", .call), op("lookup", .cache, target: "cache"), op("emit", .publish, target: "queue")]
            var worker = node("worker", .worker) { $0.concurrency = 4 }
            worker.ops = [op("handle", .consume, target: "queue")]
            let steps = [
                named("think", Step(.work(.fixed(0.02)))),
                named("fanout", Step(.parallel([Step(.work(.fixed(0.01))), Step(.work(.fixed(0.03)))]))),
                named("lookup", call("cache")),
                named("emit", Step(.publish(target: "queue"))),
            ]
            var jobs = consumer("jobs", "queue", "worker")
            jobs.steps = [named("handle", Step(.work(.fixed(0.005))))]
            let sim = sim([api, node("cache", .cache), node("queue", .queue), worker],
                          [source(.every(0.1), [call("api", steps)]), jobs], seed: 5)
            sim.run(seconds: 10)
            let metrics = ["think", "fanout", "lookup", "emit"].map { sim.opMetrics(node: "api", op: $0) }
            let handle = sim.opMetrics(node: "worker", op: "handle")
            check(metrics.allSatisfy { $0.referenced && abs($0.rate - 10) < 0.5 && $0.errors == 0 } && abs(handle.rate - 10) < 0.5,
                  "every step kind should count: \(metrics.map(\.rate)), handle \(handle.rate)")
            check(abs((metrics[0].p50 ?? 0) - 0.02) < 0.0005 && abs((metrics[1].p50 ?? 0) - 0.03) < 0.0005 &&
                  abs((handle.p50 ?? 0) - 0.005) < 0.0002, "work or parallel op latency: \(metrics.map { $0.p50 ?? -1 })")
            sim.perform([.kill("cache")])
            sim.run(seconds: 6)
            let lookup = sim.opMetrics(node: "api", op: "lookup")
            check(lookup.rate > 9 && abs(lookup.errors - lookup.rate) < 1e-9 && sim.metrics(flow: "requests").failed == 0,
                  "a down cache should fail its op while the step falls back to a miss: \(lookup.errors) of \(lookup.rate)")
        },
        CheckCase(name: "engine flow ops count every finished run, including handler failures") {
            var worker = node("worker", .worker) { $0.concurrency = 8; $0.latency = .fixed(0.01); $0.errors = 0.5; $0.onError = .drop }
            worker.ops = [op("handle", .consume, target: "queue")]
            var web = Node(id: "client", kind: .client)
            web.ops = [op("submit", .publish, target: "queue")]
            var jobs = consumer("jobs", "queue", "worker")
            jobs.op = "handle"
            var requests = source(.every(0.1), [Step(.publish(target: "queue"))])
            requests.op = "client/submit"
            var level = Level()
            level.nodes = [web, node("queue", .queue) { $0.capacity = 100_000 }, worker]
            level.flows = [requests, jobs]
            let sim = Simulation(manifest: Manifest(id: "flow-ops", title: "Flow ops", root: level,
                                                    source: .inline(note: "Checks", index: 0)), seed: 21)
            sim.run(seconds: 20)
            let handle = sim.opMetrics(node: "worker", op: "handle")
            let submit = sim.opMetrics(node: "client", op: "submit")
            let flow = sim.metrics(flow: "jobs")
            measure("Consumer flow op: %.2f/s, %.2f errors/s, p50 %.2f ms", handle.rate, handle.errors, (handle.p50 ?? 0) * 1000)
            check(handle.referenced && abs(handle.rate - 10) < 0.5 && submit.referenced && abs(submit.rate - 10) < 0.5,
                  "flow ops should count every run: handle \(handle.rate), submit \(submit.rate)")
            check(handle.total == flow.totalOK + flow.totalFailed && abs(handle.errors - flow.failed) < 1e-9 && handle.errors > 2,
                  "handler failures must count on the consumer's op: \(handle.errors) vs flow \(flow.failed)")
            check(abs((handle.p50 ?? 0) - (flow.p50 ?? -1)) < 1e-9, "a flow op should time the whole run")
        },
        CheckCase(name: "engine op attribution stays within the performance budget") {
            var nodes = (1...5).map { hop in node("hop\(hop)", .service) { $0.concurrency = 128; $0.latency = .fixed(0.002) } }
            for index in nodes.indices { nodes[index].ops = [op("serve", .rpc)] }
            // Nested hops share the op id, so name each one as node/op (a bare id resolves on the caller first).
            let pipeline = nodes.reversed().reduce([Step]()) { [named("\($1.id)/serve", call($1.id, $0))] }
            let sim = sim(nodes, [source(.perSecond(1000), pipeline)], seed: 14)
            let clock = ContinuousClock()
            let start = clock.now
            sim.run(seconds: 10)
            let elapsed = start.duration(to: clock.now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18
            let tail = sim.opMetrics(node: "hop5", op: "serve")
            measure("Five hops with ops, 10 s simulated in %.3f s, hop5 op %.1f/s, p50 %.2f ms", seconds, tail.rate, (tail.p50 ?? 0) * 1000)
            check(tail.rate > 950 && tail.total > 9000, "op attribution skipped work: \(tail.rate)/s")
            check(seconds < 1, "10 s headless with ops took \(seconds) s")
        },
    ]
}
