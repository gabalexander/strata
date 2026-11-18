import Foundation
import StrataCore

// Pressure analysis: known answers for the static capacity model, the scale plan, pressure, the
// blast radius and live culprits, and a cross-check of the model against the engine.

private func node(_ id: String, _ kind: NodeKind, _ configure: (inout NodeParams) -> Void = { _ in }) -> Node {
    var node = Node(id: id, kind: kind)
    configure(&node.params)
    return node
}

private func call(_ target: String, _ steps: [Step] = [], miss: [Step] = [], _ configure: (inout Step) -> Void = { _ in }) -> Step {
    var step = Step(.call(target: target, steps: steps, miss: miss))
    configure(&step)
    return step
}

private func source(_ rate: Double, _ steps: [Step], id: String = "requests", _ configure: (inout Flow) -> Void = { _ in }) -> Flow {
    var flow = Flow(id: id)
    flow.from = "client"
    flow.rate = .perSecond(rate)
    flow.steps = steps
    configure(&flow)
    return flow
}

private func consumer(_ id: String, on buffer: String, by worker: String, _ steps: [Step] = []) -> Flow {
    var flow = Flow(id: id)
    flow.on = buffer
    flow.by = worker
    flow.steps = steps
    return flow
}

private func level(_ nodes: [Node], _ flows: [Flow]) -> Level {
    var level = Level()
    level.nodes = [Node(id: "client", kind: .client)] + nodes
    level.flows = flows
    return level
}

private func manifest(_ level: Level, id: String = "analysis") -> Manifest {
    Manifest(id: id, title: "Analysis checks", root: level, source: .inline(note: "Checks", index: 0))
}

private func bundled(_ id: String) throws -> Manifest {
    guard let url = StrataResources.url("Examples/\(id).yaml") else { throw CocoaError(.fileNoSuchFile) }
    let (manifest, diagnostics) = ManifestParser.parse(try String(contentsOf: url, encoding: .utf8), source: .bundled(url))
    guard let manifest else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "\(diagnostics)"]) }
    return manifest
}

private func near(_ value: Double?, _ expected: Double, _ tolerance: Double) -> Bool {
    guard let value else { return false }
    return abs(value - expected) <= tolerance
}

private extension CapacityReport {
    func node(_ id: String) -> NodeCapacity? { nodes.first { $0.node == id } }
    func flow(_ id: String) -> FlowCapacity? { flows.first { $0.flow == id } }
}

@MainActor func analysisChecks() -> [CheckCase] {
    [
        CheckCase(name: "analysis bottleneck law for a single service") {
            let model = level([node("svc", .service) { $0.concurrency = 8; $0.replicas = 2; $0.latency = .fixed(0.02) },
                               node("db", .database)],
                              [source(100, [call("svc")]), source(10, [call("db")], id: "reads")])
            let report = Analysis.capacity(of: model)
            let svc = report.node("svc"), flow = report.flow("requests")
            check(svc?.slots == 16 && near(svc?.holdTime, 0.02, 1e-12) && near(svc?.utilization, 0.125, 1e-9) &&
                  near(svc?.visits["requests"], 1, 1e-12) && near(svc?.arrivals, 100, 1e-9),
                  "svc capacity: \(String(describing: svc))")
            check(near(flow?.maxRate, 800, 0.05) && flow?.bottleneck == "svc", "max rate \(String(describing: flow?.maxRate)) on \(String(describing: flow?.bottleneck))")
            check(near(flow?.daily, 8_640_000, 1e-6) && near(flow?.latency, 0.022, 1e-9), "daily or latency: \(String(describing: flow))")
            // Kind defaults come from the engine's resolver: a database is 20 connections of 5 ms.
            let db = report.node("db")
            check(db?.slots == 20 && near(db?.holdTime, 0.005, 1e-12) && near(report.flow("reads")?.maxRate, 4000, 0.5),
                  "database defaults: \(String(describing: db))")
            check(report.node("client")?.slots == nil, "a source has no slots")
            let doubled = Analysis.capacity(of: model, rates: ["requests": 400], params: ["svc": { var p = NodeParams(); p.replicas = 4; return p }()])
            check(near(doubled.node("svc")?.utilization, 0.25, 1e-9) && near(doubled.flow("requests")?.maxRate, 1600, 0.1),
                  "rates and params overrides: \(String(describing: doubled.node("svc")))")
        },
        CheckCase(name: "analysis sync caller holds its slots while waiting on a slow database") {
            func chain(async: Bool) -> CapacityReport {
                Analysis.capacity(of: level([node("svc", .service) { $0.concurrency = 4; $0.latency = .fixed(0.01); $0.async = async },
                                             node("db", .database) { $0.latency = .fixed(0.1); $0.concurrency = 20 }],
                                            [source(10, [call("svc", [call("db")])])]))
            }
            let sync = chain(async: false)
            check(near(sync.node("svc")?.holdTime, 0.112, 1e-9) && near(sync.node("svc")?.utilization, 0.28, 1e-9),
                  "the caller's hold must include the db round trip: \(String(describing: sync.node("svc")))")
            check(near(sync.flow("requests")?.maxRate, 4 / 0.112, 0.01) && sync.flow("requests")?.bottleneck == "svc",
                  "sync max rate \(String(describing: sync.flow("requests")?.maxRate)) on \(String(describing: sync.flow("requests")?.bottleneck))")
            let async = chain(async: true)
            check(near(async.node("svc")?.holdTime, 0.01, 1e-9), "async must release the slot while waiting: \(String(describing: async.node("svc")))")
            check(near(async.flow("requests")?.maxRate, 200, 0.05) && async.flow("requests")?.bottleneck == "db",
                  "async max rate \(String(describing: async.flow("requests")?.maxRate)) on \(String(describing: async.flow("requests")?.bottleneck))")
        },
        CheckCase(name: "analysis queueing near saturation and blame on the callee") {
            func callee(_ rate: Double) -> CapacityReport {
                Analysis.capacity(of: level([node("svc", .service) { $0.concurrency = 1000; $0.latency = .fixed(0.001) },
                                             node("db", .database) { $0.concurrency = 1; $0.latency = .fixed(0.01) }],
                                            [source(rate, [call("svc", [call("db")])])]))
            }
            // M/M/1 at 90%: the wait is ρ / (1 − ρ) × S = 90 ms; below 70% it is taken as 0.
            check(near(callee(90).node("svc")?.holdTime, 0.001 + 0.002 + 0.09 + 0.01, 1e-6) && near(callee(90).node("db")?.queueWait, 0.09, 1e-6),
                  "M/M/1 wait: \(String(describing: callee(90).node("svc")))")
            check(near(callee(60).node("svc")?.holdTime, 0.013, 1e-9), "no wait below 70%: \(String(describing: callee(60).node("svc")))")
            // A big caller pool fills from the callee's queue just before the callee hits 100%; blame the callee.
            let root = Analysis.capacity(of: level([node("svc", .service) { $0.concurrency = 100; $0.latency = .fixed(0.02) },
                                                    node("db", .database) { $0.concurrency = 2; $0.latency = .fixed(0.05) }],
                                                   [source(10, [call("svc", [call("db")])])]))
            let flow = root.flow("requests")
            check(flow?.bottleneck == "db" && (flow?.maxRate ?? 0) > 38 && (flow?.maxRate ?? 99) <= 40,
                  "the saturated callee is the bottleneck: \(String(describing: flow?.maxRate)) on \(String(describing: flow?.bottleneck))")
        },
        CheckCase(name: "analysis cache misses, retries and probabilities") {
            let cached = Analysis.capacity(of: level([node("svc", .service), node("cache", .cache) { $0.hitRate = 0.9 }, node("db", .database)],
                                                     [source(10, [call("svc", [call("cache", miss: [call("db")])])])]))
            check(near(cached.node("db")?.visits["requests"], 0.1, 1e-12) && near(cached.node("cache")?.visits["requests"], 1, 1e-12),
                  "a 90% hit rate sends 0.1 visits to the db: \(String(describing: cached.node("db")?.visits))")
            let retried = Analysis.capacity(of: level([node("svc", .service), node("api", .service) { $0.errors = 0.5 }],
                                                      [source(10, [call("svc", [call("api") { $0.retries = 2 }])])]))
            check(near(retried.node("api")?.visits["requests"], 1.75, 1e-12), "errors 0.5 and retries 2: \(String(describing: retried.node("api")?.visits))")
            let defaults = Analysis.capacity(of: level([node("svc", .service) { $0.retries = 2 }, node("api", .service) { $0.errors = 0.5 }],
                                                       [source(10, [call("svc", [call("api")])])]))
            check(near(defaults.node("api")?.visits["requests"], 1.75, 1e-12), "the caller's retries apply: \(String(describing: defaults.node("api")?.visits))")
            let branches = Analysis.capacity(of: level([node("a", .service), node("b", .service), node("c", .service)],
                                                       [source(10, [Step(.parallel([call("a"), call("b") { $0.p = 0.3 }])), call("c") { $0.p = 0.5 }])]))
            check(near(branches.node("a")?.visits["requests"], 1, 1e-12) && near(branches.node("b")?.visits["requests"], 0.3, 1e-12) &&
                  near(branches.node("c")?.visits["requests"], 0.5, 1e-12), "parallel branches and p")
        },
        CheckCase(name: "analysis consumer flows follow their buffer and report a backlog") {
            var publish = Step(.publish(target: "jobs"))
            publish.p = 0.5
            let model = level([node("svc", .service), node("jobs", .queue), node("worker", .worker) { $0.concurrency = 2; $0.latency = .fixed(0.1) },
                               node("events", .topic), node("audit", .worker), node("mail", .worker)],
                              [source(60, [call("svc", [publish, Step(.publish(target: "events"))])]),
                               consumer("work", on: "jobs", by: "worker"),
                               consumer("audit-log", on: "events", by: "audit"), consumer("mailing", on: "events", by: "mail")])
            let report = Analysis.capacity(of: model)
            let work = report.flow("work")
            check(near(work?.offered, 30, 1e-9) && near(work?.maxRate, 20, 0.01) && near(work?.rate, 20, 0.01) && work?.bottleneck == "worker",
                  "a capped consumer: \(String(describing: work))")
            check(report.notes.contains { $0.contains("can't keep up") && $0.contains("grows 10/s") }, "backlog note: \(report.notes)")
            check(near(report.node("worker")?.utilization, 1.5, 1e-9), "demand counts what arrives: \(String(describing: report.node("worker")))")
            check(near(report.flow("audit-log")?.rate, 60, 1e-9) && near(report.flow("mailing")?.rate, 60, 1e-9),
                  "every topic consumer group gets every message")
            check(near(report.node("events")?.visits["requests"], 1, 1e-12) && report.node("events")?.slots == nil, "publishes count at the buffer")

            let competing = Analysis.capacity(of: level([node("jobs", .queue), node("small", .worker), node("large", .worker) { $0.replicas = 3 }],
                                                        [source(40, [Step(.publish(target: "jobs"))]),
                                                         consumer("first", on: "jobs", by: "small"), consumer("second", on: "jobs", by: "large")]))
            check(near(competing.flow("first")?.rate, 10, 1e-9) && near(competing.flow("second")?.rate, 30, 1e-9),
                  "competing consumers split a queue by replicas: \(competing.flows.map { "\($0.flow) \($0.rate)" })")
        },
        CheckCase(name: "analysis scale plan moves the bottleneck to the next node") {
            let model = level([node("svc", .service) { $0.concurrency = 8; $0.latency = .fixed(0.02) },
                               node("db", .database) { $0.concurrency = 20; $0.latency = .fixed(0.005) }],
                              [source(100, [call("svc", [call("db")])])])
            let report = Analysis.capacity(of: model)
            let plan = report.scalePlan
            check(plan.first?.node == "svc" && plan.first?.nextBottleneck == "db" && (plan.first?.replicas ?? 0) > 1 &&
                  (plan.first?.newMaxRate ?? 0) > (report.flow("requests")?.maxRate ?? .infinity) && plan.first?.flow == "requests",
                  "first step: \(String(describing: plan.first))")
            check(plan.count >= 2 && plan[1].node == "db" && plan.first?.reason.contains("svc saturates first") == true,
                  "second step: \(plan.map { "\($0.node)→\($0.replicas)" })")
            let idle = Analysis.capacity(of: model, rates: ["requests": 0.5])
            check(idle.scalePlan.isEmpty, "nothing saturates within 100× of 0.5/s")
            var peak = FlowTraffic()
            peak.peak = 400
            var declared = model
            declared.flows[0].traffic = peak
            let atPeak = Analysis.capacity(of: declared)
            check(near(atPeak.flow("requests")?.rate, 100, 1e-9) && atPeak.scalePlan.first?.reason.contains("over capacity at peak") == true,
                  "the plan uses traffic.peak: \(String(describing: atPeak.scalePlan.first?.reason))")
        },
        CheckCase(name: "analysis pressure shares sum to one per node") {
            let checkout = try bundled("checkout")
            let report = Analysis.capacity(of: checkout.root)
            check(!report.pressure.isEmpty, "no pressure reported")
            for (id, sources) in report.pressure {
                let total = sources.reduce(0) { $0 + $1.busyShare }
                check(abs(total - 1) < 1e-9, "\(id) shares sum to \(total)")
            }
            let db = report.pressure["db"] ?? []
            check(db.first?.op == "insert-order" && db.first?.access == .write && db.first?.tables == ["orders", "order_items", "outbox"] &&
                  near(db.first?.rate, 12, 1e-9) && (db.first?.busyShare ?? 0) > 0.85, "db top source: \(String(describing: db.first))")
            check(db.contains { $0.op == "read-price" && $0.access == .read && near($0.rate, 1.2, 1e-9) && near($0.daily, 103_680, 1e-6) },
                  "price reads on a miss: \(db)")
            check(report.pressure["orders"]?.first?.op == "forward-place-order" && report.pressure["api"]?.first?.op == "submit-order",
                  "an endpoint named on the step maps to the caller's client op")
        },
        CheckCase(name: "analysis blast radius stops at a topic") {
            var feed = source(5, [call("producer", [Step(.publish(target: "topic"))])], id: "feed")
            feed.from = "client"
            let model = level([node("api", .service), node("svc", .service), node("db", .database), node("producer", .service),
                               node("topic", .topic), node("worker", .worker)],
                              [source(10, [call("api", [call("svc", [call("db")])])]), feed,
                               consumer("consume", on: "topic", by: "worker", [call("db")])])
            let db = Analysis.blastRadius(of: "db", in: model)
            check(db.upstream == ["svc", "worker", "api", "client"], "upstream nearest first: \(db.upstream)")
            check(db.absorbers == ["topic"] && db.lagging == ["worker"] && db.flows == ["requests", "consume"], "absorbers, lagging, flows: \(db)")
            check(Set(db.edges) == ["svc->db", "worker->db", "api->svc", "client->api", "topic->worker"], "edges: \(db.edges)")
            let topic = Analysis.blastRadius(of: "topic", in: model)
            check(topic.upstream == ["producer", "client"] && topic.lagging == ["worker"] && topic.absorbers.isEmpty &&
                  topic.flows == ["feed", "consume"], "a full or down buffer fails its publishers: \(topic)")
            let worker = Analysis.blastRadius(of: "worker", in: model)
            check(worker.upstream.isEmpty && worker.absorbers == ["topic"] && worker.lagging == ["worker"] && worker.flows == ["consume"],
                  "a slow consumer turns into lag: \(worker)")
        },
        CheckCase(name: "analysis capacity report follows the running sim") {
            let model = level([node("svc", .service) { $0.concurrency = 4; $0.latency = .fixed(0.01) },
                               node("db", .database) { $0.latency = .fixed(0.01) }],
                              [source(10, [call("svc", [call("db")])])])
            let sim = Simulation(manifest: manifest(model))
            sim.perform([.rate("requests", .perSecond(50)), .scale("svc", 3, relative: false), .slow("db", 2)])
            let report = sim.capacityReport()
            check(near(report.flow("requests")?.rate, 50, 1e-9) && report.node("svc")?.slots == 12 &&
                  near(report.node("db")?.holdTime, 0.02, 1e-9) && near(report.node("svc")?.holdTime, 0.032, 1e-9),
                  "runtime rate, replicas and slow: \(String(describing: report.node("svc"))) \(String(describing: report.node("db")))")
            sim.perform([.kill("db")])
            let down = sim.capacityReport()
            check(down.node("db")?.slots == 0 && down.node("db")?.utilization == 1 && down.flow("requests")?.maxRate == 0 &&
                  down.flow("requests")?.bottleneck == "db" && down.notes.contains { $0.contains("db is down") },
                  "a down node has no slots: \(String(describing: down.node("db"))) \(down.notes)")

            let checkout = Simulation(manifest: try bundled("checkout"))
            checkout.perform([.kill("mailer"), .scale("orders", 4, relative: false)])
            let stopped = checkout.capacityReport()
            let email = stopped.flow("email")
            check(stopped.node("mailer")?.slots == 0 && stopped.node("mailer")?.utilization == 1 && email?.rate == 0 &&
                  near(email?.offered, 12, 1e-9) && email?.maxRate == 0 && email?.bottleneck == "mailer" &&
                  stopped.notes.contains { $0.contains("Mailer is down") && $0.contains("grows 12/s") } &&
                  !stopped.notes.contains { $0.contains("calls to it fail fast") } &&
                  stopped.node("orders")?.slots == 16, "a down consumer: \(String(describing: email)) \(stopped.notes)")
        },
        CheckCase(name: "analysis culprits for a dead database, scaling and SLOs") {
            let outage = Simulation(manifest: manifest(level(
                [node("svc", .service) { $0.concurrency = 4; $0.latency = .fixed(0.01); $0.retries = 3; $0.backoff = 0.1 },
                 node("db", .database)],
                [source(20, [call("svc", [call("db")])])])))
            outage.run(seconds: 5)
            check(outage.culprits().isEmpty, "a healthy sim has culprits: \(outage.culprits().map(\.message))")
            outage.perform([.kill("db")])
            outage.run(seconds: 3)
            let dead = outage.culprits()
            check(dead.first?.id == "down:db" && dead.first?.severity == .critical, "down first: \(dead.map(\.id))")
            check(dead.contains { $0.id == "saturated:svc" } && dead.contains { $0.id == "errors:requests" },
                  "retries saturate the caller and the flow fails: \(dead.map(\.message))")
            outage.perform([.restore("db")])
            outage.run(seconds: 8)
            check(outage.culprits().isEmpty, "a restored database clears: \(outage.culprits().map(\.message))")

            let overload = Simulation(manifest: manifest(level([node("svc", .service) { $0.concurrency = 2; $0.latency = .fixed(0.05) }],
                                                                [source(60, [call("svc")])])))
            overload.run(seconds: 4)
            let hot = overload.culprits()
            let saturated = hot.first { $0.id == "saturated:svc" }
            check(saturated?.severity == .critical && saturated?.message.hasPrefix("svc: 2/2 slots busy") == true &&
                  hot.contains { $0.id == "queueing:svc" }, "overload: \(hot.map(\.message))")
            overload.perform([.scale("svc", 4, relative: false)])
            overload.run(seconds: 5)
            check(!overload.culprits().contains { $0.subject == "svc" }, "scaling up clears it: \(overload.culprits().map(\.message))")

            var slo = SLO()
            slo.p99 = 0.05
            slo.errors = 0.01
            let slow = Simulation(manifest: manifest(level([node("svc", .service) { $0.latency = .fixed(0.1); $0.errors = 0.2 }],
                                                           [source(20, [call("svc")]) { $0.slo = slo }])))
            slow.run(seconds: 5)
            let breach = slow.culprits().first { $0.kind == .sloBreach }
            check(breach?.subject == "requests" && breach?.severity == .critical &&
                  breach?.message.contains("requests p99 1") == true && breach?.message.contains("> SLO 50 ms") == true &&
                  breach?.message.contains("> SLO 1%") == true, "SLO breach: \(String(describing: breach?.message))")
        },
        CheckCase(name: "analysis culprits on the checkout map agree with the static model") {
            let checkout = try bundled("checkout")
            let outage = Simulation(manifest: checkout)
            outage.start(scenario: "db-outage")
            outage.run(seconds: 12)
            let dead = outage.culprits()
            check(dead.first?.id == "down:db" && dead.contains { $0.id == "errors:place-order" }, "db outage: \(dead.map(\.message))")
            let healthy = Simulation(manifest: checkout)
            healthy.run(seconds: 15)
            check(healthy.culprits().isEmpty, "checkout at 12/s is healthy: \(healthy.culprits().map(\.message))")
            let busy = Simulation(manifest: checkout)
            busy.perform([.rate("place-order", .perSecond(35))])
            busy.run(seconds: 15)
            let behind = busy.culprits()
            let lag = behind.first { $0.id == "lagging:events" }
            check(behind.first?.id == "saturated:mailer" && lag?.message.contains("Mailer is") == true,
                  "35 orders/s overrun the mailer: \(behind.map(\.message))")
            check(busy.capacityReport().notes.contains { $0.contains("Mailer can't keep up") && $0.contains("grows 11.5/s") },
                  "the static model predicts the backlog: \(busy.capacityReport().notes)")
        },
        CheckCase(name: "analysis culprits stay cheap") {
            let checkout = try bundled("checkout")
            let sim = Simulation(manifest: checkout)
            sim.perform([.kill("db"), .slow("cache", 50)])
            sim.run(seconds: 10)
            let clock = ContinuousClock()
            let start = clock.now
            for _ in 0..<200 { _ = sim.culprits() }
            let elapsed = start.duration(to: clock.now).components
            let each = (Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18) / 200 * 1000
            print(String(format: "Culprits on checkout: %.3f ms per call", each))
            check(each < 2, "culprits took \(each) ms")
        },
        CheckCase(name: "analysis static utilization matches the engine") {
            for id in ["checkout", "queueing-latency"] {
                let manifest = try bundled(id)
                let report = Analysis.capacity(of: manifest.root)
                let seeds: [UInt64] = [1, 2, 3]
                var measured: [String: Double] = [:]
                for seed in seeds {
                    let sim = Simulation(manifest: manifest, seed: seed)
                    sim.run(seconds: 30)
                    for node in report.nodes {
                        guard let slots = node.slots, slots > 0 else { continue }
                        measured[node.node, default: 0] += sim.busySeconds(node.node) / (30 * Double(slots)) / Double(seeds.count)
                    }
                }
                var compared = 0
                for node in report.nodes where node.slots != nil && node.utilization >= 0.02 {
                    let simulated = measured[node.node] ?? 0
                    let error = abs(node.utilization - simulated) / max(simulated, 1e-9)
                    print(String(format: "Cross-check %@ %@: static %.4f, engine %.4f (%+.1f%%)", id, node.node,
                                 node.utilization, simulated, (node.utilization - simulated) / max(simulated, 1e-9) * 100))
                    check(error <= 0.15, "\(id) \(node.node): static \(node.utilization) vs engine \(simulated)")
                    compared += 1
                }
                check(compared > 0, "\(id): nothing to compare")
            }
        },
    ]
}
