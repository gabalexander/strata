import Foundation

/// A demo manifest built in code, for snapshots and checks before the parser exists. It exercises
/// every node role, a deep dive, a consumer flow, a control with insights and a scenario.
public enum Fixtures {
    public static var checkout: Manifest {
        func node(_ id: String, _ kind: NodeKind, _ label: String, _ x: Double, _ y: Double, tech: String? = nil,
                  group: String? = nil, _ edit: (inout Node) -> Void = { _ in }) -> Node {
            var n = Node(id: id, kind: kind, label: label)
            n.at = GridPoint(x, y); n.tech = tech; n.group = group
            edit(&n)
            return n
        }
        func edge(_ a: String, _ b: String, _ proto: String? = nil, label: String? = nil) -> Edge {
            var e = Edge(from: a, to: b); e.protocol = proto; e.label = label; return e
        }
        func call(_ t: String, _ label: String? = nil, _ steps: [Step] = [], miss: [Step] = []) -> Step {
            var s = Step(.call(target: t, steps: steps, miss: miss)); s.label = label; return s
        }

        var inside = Level()
        inside.narration = "Inside **orders-svc**: the handler validates, writes the order and an outbox row in one transaction, and a relay publishes the outbox."
        inside.nodes = [
            node("in", .port, "from api-gateway", 0, 1),
            node("handler", .service, "HTTP handler", 1, 1, tech: "Go") { $0.params.latency = .jitter(0.002) },
            node("validate", .service, "validator", 2, 0) { $0.params.latency = .jitter(0.001) },
            node("tx", .database, "orders + outbox tx", 2, 2, tech: "postgres"),
            node("relay", .worker, "outbox relay", 3, 2),
        ]
        inside.edges = [edge("in", "handler"), edge("handler", "validate"), edge("handler", "tx", "sql"), edge("relay", "tx", "sql")]
        var req = Flow(id: "requests", label: "Requests")
        req.from = "in"; req.rate = .parent
        req.steps = [call("handler", "POST /orders", [call("validate"), call("tx", "INSERT order + outbox")])]
        inside.flows = [req]

        var root = Level()
        root.narration = "A web checkout: synchronous calls down to **Postgres**, an event to **Kafka**, and an email worker that consumes it."
        root.groups = [Group(id: "backend", label: "Backend (EKS)")]
        root.groups[0].kind = .cluster
        root.nodes = [
            node("web", .client, "Web app", 0, 1, tech: "React"),
            node("api", .gateway, "API gateway", 1, 1, tech: "Envoy", group: "backend"),
            node("orders", .service, "orders-svc", 2, 1, tech: "Go", group: "backend") {
                $0.params.latency = .jitter(0.03); $0.params.concurrency = 8; $0.params.replicas = 2
                $0.inside = inside
                $0.doc = "Owns the order lifecycle. Writes to Postgres, reads prices from Redis, emits `OrderPlaced`."
                $0.term = "grpc"
            },
            node("cache", .cache, "prices", 3, 0, tech: "redis", group: "backend") { $0.params.hitRate = 0.9 },
            node("db", .database, "orders db", 3, 1, tech: "postgres", group: "backend"),
            node("events", .topic, "order-events", 3, 2, tech: "kafka", group: "backend"),
            node("mailer", .worker, "mailer", 4, 2, group: "backend"),
            node("smtp", .external, "SendGrid", 5, 2),
            node("hint", .note, "Note", 0, 2.4) { $0.doc = "Right-click any node to break it." },
        ]
        root.edges = [
            edge("web", "api", "https"), edge("api", "orders", "grpc", label: "gRPC"), edge("orders", "cache", "redis"),
            edge("orders", "db", "sql"), edge("orders", "events", "kafka"), edge("events", "mailer"), edge("mailer", "smtp", "https"),
        ]
        var place = Flow(id: "place-order", label: "Place order")
        place.from = "web"; place.rate = .perSecond(5); place.color = 1
        var publish = Step(.publish(target: "events")); publish.label = "OrderPlaced"
        place.steps = [call("api", nil, [call("orders", "POST /orders", [
            call("cache", "GET price", miss: [call("db", "SELECT price")]),
            call("db", "INSERT order"), publish,
        ])])]
        var email = Flow(id: "email", label: "Confirmation email")
        email.on = "events"; email.by = "mailer"; email.color = 3
        email.steps = [call("smtp", "send")]
        root.flows = [place, email]

        var rateControl = Control(id: "rate", label: "Checkout traffic", bind: Binding(.flow("place-order"), "rate"),
                                  input: .range(min: 0, max: 200, step: 5))
        rateControl.unit = "/s"
        var hit = Control(id: "hit", label: "Price cache hit rate", bind: Binding(.node("cache"), "hitRate"),
                          input: .options([.number(0), .number(0.5), .number(0.9), .number(0.99)]))
        var low = InsightRule(text: "Most reads miss and fall through to Postgres, so database load tracks traffic one to one.")
        low.when = .lt(0.5)
        low.effects = [EffectSpec(metric: "db load", dir: .up, good: false), EffectSpec(metric: "p99", dir: .up, good: false)]
        var high = InsightRule(text: "The cache absorbs almost every read; Postgres only sees writes and the occasional miss.")
        high.effects = [EffectSpec(metric: "db load", dir: .down, good: true)]
        hit.insights = [low, high]
        root.controls = [rateControl, hit]

        var outage = Scenario(id: "db-outage", label: "Postgres goes down")
        outage.goal = "What happens to checkout when the database disappears for five seconds?"
        outage.setup = [.rate("place-order", .perSecond(20))]
        var s1 = ScenarioStep(at: 2); s1.commands = [.kill("db")]; s1.say = "Postgres is gone. Watch orders-svc fill up."
        var s2 = ScenarioStep(at: 7); s2.commands = [.restore("db")]; s2.say = "Back. How long until the backlog drains?"
        outage.steps = [s1, s2]
        outage.watch = ["orders.inflight", "place-order.errors"]
        root.scenarios = [outage]

        var m = Manifest(id: "checkout", title: "Checkout platform", root: root, source: .bundled(URL(fileURLWithPath: "/fixtures/checkout.yaml")))
        m.kind = .architecture
        m.category = "company"
        m.summary = "How an order travels from the web app to the email inbox."
        m.tags = ["demo"]
        var t = Term(id: "grpc", term: "gRPC", short: "An RPC framework over HTTP/2 with protobuf messages.")
        t.detail = "Calls are multiplexed as streams on one long-lived connection."
        t.match = ["gRPC"]
        m.terms = [t]
        return m
    }
}
