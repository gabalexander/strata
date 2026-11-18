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

    /// `checkout` with operations on every node that does something (docs/manifest.md, Operations):
    /// HTTP and gRPC endpoints linked by `calls:`, SQL in a transaction, Redis reads and writes, a
    /// Kafka publish and two consumers, a second service writing the same table, risks, facts, and
    /// an op with its own `inside:` level. Steps name the ops they perform; the email flow names its consume op.
    public static var checkoutWithOps: Manifest {
        var m = checkout
        m.id = "checkout-ops"
        m.title = "Checkout platform"
        m.repo = "~/code/checkout"
        func op(_ id: String, _ kind: OpKind, _ label: String, _ direction: OpDirection = .outbound,
                target: String? = nil, _ edit: (inout Operation) -> Void = { _ in }) -> Operation {
            var o = Operation(id: id, kind: kind, label: label, direction: direction)
            o.target = target
            edit(&o)
            return o
        }
        func call(_ t: String, _ label: String? = nil, op: String? = nil, _ steps: [Step] = [], miss: [Step] = []) -> Step {
            var s = Step(.call(target: t, steps: steps, miss: miss)); s.label = label; s.op = op; return s
        }
        func node(_ id: String, _ kind: NodeKind, _ label: String, _ x: Double, _ y: Double, tech: String? = nil,
                  group: String? = nil) -> Node {
            var n = Node(id: id, kind: kind, label: label)
            n.at = GridPoint(x, y); n.tech = tech; n.group = group
            return n
        }

        var lock = Level()
        lock.narration = "One INSERT order + outbox inside its transaction: take the row locks, write both heap tuples, then fsync the WAL on COMMIT."
        lock.nodes = [
            node("in", .port, "from orders-svc", 0, 1),
            node("backend", .service, "pg backend", 1, 1, tech: "postgres"),
            node("locks", .database, "row locks", 2, 0),
            node("heap", .store, "orders + outbox heap", 2, 1),
            node("wal", .store, "WAL", 2, 2),
        ]
        lock.nodes[1].params.latency = .jitter(0.0005)
        lock.nodes[2].params.latency = .jitter(0.0003)
        lock.nodes[4].params.latency = .jitter(0.002)
        lock.edges = [Edge(from: "in", to: "backend"), Edge(from: "backend", to: "locks"),
                      Edge(from: "backend", to: "heap"), Edge(from: "backend", to: "wal")]
        var tx = Flow(id: "insert", label: "INSERT order + outbox")
        tx.from = "in"; tx.rate = .parent
        tx.steps = [call("backend", "BEGIN", [call("locks", "lock rows"), call("heap", "write tuples"), call("wal", "fsync on COMMIT")])]
        lock.flows = [tx]

        var root = m.root
        root.nodes.append(node("payments", .service, "payments-svc", 2, 0, tech: "Java", group: "backend"))
        root.nodes.append(node("reporting", .cron, "reporting", 4, 1, tech: "nightly"))
        root.edges.append(Edge(from: "orders", to: "payments"))
        root.edges[root.edges.count - 1].protocol = "grpc"
        root.edges.append(Edge(from: "reporting", to: "db"))
        root.edges[root.edges.count - 1].protocol = "sql"

        for index in root.nodes.indices {
            switch root.nodes[index].id {
            case "api":
                root.nodes[index].ops = [
                    op("forward-create-order", .rpc, "CreateOrder", target: "orders") {
                        $0.method = "orders.v1.Orders/Create"; $0.streaming = "unary"; $0.calls = "orders/create-order"
                        $0.facts = [("deadline", "2s"), ("auth", "JWT, verified at the edge")]
                    },
                    op("forward-get-order", .rpc, "GetOrder", target: "orders") {
                        $0.method = "orders.v1.Orders/Get"; $0.calls = "orders/get-order"
                    },
                ]
            case "orders":
                root.nodes[index].code = ["services/orders"]
                root.nodes[index].ops = [
                    op("create-order", .http, "POST /orders", .inbound) {
                        $0.method = "POST"; $0.path = "/orders"; $0.access = .write
                        $0.request = #"{ "sku": "A-1", "qty": 2, "idempotency_key": "8f2c…" }"#
                        $0.response = #"{ "order_id": "ord_91x", "status": "placed", "total": 4200 }"#
                        $0.status = ["201 created", "409 duplicate idempotency key", "422 invalid cart", "503 overloaded"]
                        $0.doc = "Validates the cart, prices it from the cache, then writes the order and its outbox row in one transaction. The gRPC gateway translates `CreateOrder` into this call."
                        $0.code = ["services/orders/http/create.go:41"]
                        $0.facts = [("auth", "user JWT"), ("idempotency", "Idempotency-Key header, 24 h"), ("rate limit", "20/s per user")]
                    },
                    op("get-order", .rpc, "Orders/Get", .inbound) {
                        $0.method = "orders.v1.Orders/Get"; $0.streaming = "unary"; $0.access = .read
                        $0.request = #"{ "order_id": "ord_91x" }"#
                        $0.code = ["services/orders/grpc/get.go:18"]
                    },
                    op("price", .cache, "GET price", target: "cache") {
                        $0.command = "GET"; $0.key = "price:{sku}"; $0.ttl = 300
                        $0.doc = "Reads the current price; a miss falls through to Postgres and refills the key."
                        $0.code = ["services/orders/pricing.go:27"]
                    },
                    op("set-price", .cache, "SET price on miss", target: "cache") {
                        $0.command = "SET EX 300"; $0.key = "price:{sku}"; $0.ttl = 300
                        $0.risks = ["Concurrent misses on a hot SKU all refill the key: a small stampede"]
                    },
                    op("select-price", .sql, "SELECT price", target: "db") {
                        $0.tables = ["prices"]; $0.indexes = ["prices_sku_key"]
                        $0.query = "SELECT amount, currency FROM prices WHERE sku = $1 AND valid_to IS NULL;"
                        $0.code = ["services/orders/repo/prices.go:12"]
                    },
                    op("insert-order", .sql, "INSERT order + outbox", target: "db") {
                        $0.access = .write; $0.tables = ["orders", "outbox"]; $0.indexes = ["orders_pkey", "orders_user_id_idx"]
                        $0.tx = true; $0.locks = "row"
                        $0.query = """
                        BEGIN;
                        INSERT INTO orders (id, user_id, total, status)
                          VALUES ($1, $2, $3, 'placed');
                        INSERT INTO outbox (topic, key, payload)
                          VALUES ('order-events', $1, $4);
                        COMMIT;
                        """
                        $0.doc = "Writes the order and its **outbox** row atomically, so `OrderPlaced` is published if and only if the order exists."
                        $0.code = ["services/orders/repo.go:88", "services/orders/outbox/relay.go:30"]
                        $0.risks = ["Hot rows for very large customers: concurrent orders queue on the same user row",
                                    "The outbox grows if the relay stalls; nothing alerts on its size"]
                        $0.facts = [("isolation", "read committed"), ("timeout", "statement_timeout 500ms"), ("pool", "pgxpool, 20 conns")]
                        $0.inside = lock
                    },
                    op("charge", .rpc, "Charge card", target: "payments") {
                        $0.method = "payments.v1.Payments/Charge"; $0.streaming = "unary"; $0.calls = "payments/charge"
                        $0.request = #"{ "order_id": "ord_91x", "amount": 4200, "currency": "EUR" }"#
                        $0.status = ["OK", "FAILED_PRECONDITION card declined", "DEADLINE_EXCEEDED"]
                        $0.facts = [("deadline", "800ms"), ("idempotent", "yes, by order id"), ("retries", "2, with backoff")]
                        $0.code = ["services/orders/payments/client.go:54"]
                    },
                    op("order-placed", .publish, "OrderPlaced", target: "events") {
                        $0.topic = "order-events"; $0.key = "order_id"; $0.calls = "mailer/order-placed"
                        $0.payload = #"{"type":"OrderPlaced","order_id":"ord_91x","user_id":"u_17","total":4200,"items":[{"sku":"A-1","qty":2}]}"#
                        $0.doc = "Published by the outbox relay after the transaction commits. Keyed by order id, so events for one order stay in order."
                        $0.code = ["services/orders/outbox/relay.go:52"]
                        $0.facts = [("acks", "all"), ("schema", "orders.v1.OrderPlaced")]
                    },
                ]
            case "payments":
                root.nodes[index].ops = [
                    op("charge", .rpc, "Payments/Charge", .inbound) {
                        $0.method = "payments.v1.Payments/Charge"; $0.streaming = "unary"; $0.access = .write
                        $0.doc = "Authorises and captures a card payment with the acquirer."
                    },
                    op("refund", .rpc, "Payments/Refund", .inbound) {
                        $0.method = "payments.v1.Payments/Refund"; $0.access = .write
                    },
                ]
            case "mailer":
                root.nodes[index].ops = [
                    op("order-placed", .consume, "OrderPlaced", .inbound) {
                        $0.topic = "order-events"; $0.group = "mailer"; $0.key = "order_id"
                        $0.payload = #"{"type":"OrderPlaced","order_id":"ord_91x","user_id":"u_17"}"#
                        $0.code = ["services/mailer/consumer.go:22"]
                    },
                    op("send-email", .http, "Send confirmation", target: "smtp") {
                        $0.method = "POST"; $0.path = "/v3/mail/send"
                        $0.status = ["202 accepted", "429 rate limited"]
                        $0.risks = ["No idempotency key: a redelivered event sends a second email"]
                    },
                ]
            case "reporting":
                root.nodes[index].ops = [
                    op("daily-totals", .sql, "Daily totals", target: "db") {
                        $0.tables = ["orders"]
                        $0.query = "SELECT date_trunc('day', created_at) AS day, sum(total)\nFROM orders\nWHERE created_at >= now() - interval '1 day'\nGROUP BY 1;"
                    },
                    op("backfill-status", .sql, "Backfill status", target: "db") {
                        $0.access = .write; $0.tables = ["orders"]; $0.locks = "row"
                        $0.query = "UPDATE orders SET status = 'settled' WHERE status = 'paid' AND paid_at < $1;"
                        $0.risks = ["Updates the table orders-svc writes, without its outbox: no event for these changes"]
                    },
                    op("settled", .consume, "OrderPlaced (audit)", .inbound) {
                        $0.topic = "order-events"; $0.group = "reporting-audit"
                        $0.payload = #"{"type":"OrderPlaced","order_id":"ord_91x","total":4200}"#
                    },
                ]
            default: break
            }
        }

        var publish = Step(.publish(target: "events")); publish.label = "OrderPlaced"; publish.op = "order-placed"
        var place = root.flows[0]
        place.steps = [call("api", nil, [call("orders", "POST /orders", op: "create-order", [
            call("cache", "GET price", op: "price", miss: [call("db", "SELECT price", op: "select-price")]),
            call("db", "INSERT order", op: "insert-order"),
            call("payments", "Charge", op: "charge"),
            publish,
        ])])]
        var email = root.flows[1]
        email.op = "order-placed"
        email.steps = [call("smtp", "send", op: "send-email")]
        var nightly = Flow(id: "nightly", label: "Nightly report")
        nightly.from = "reporting"; nightly.rate = .every(2); nightly.color = 5
        nightly.steps = [call("db", "Daily totals", op: "daily-totals")]
        root.flows = [place, email, nightly]
        m.root = root
        var outbox = Term(id: "outbox", term: "Transactional outbox",
                          short: "Write the event to an outbox table in the same transaction as the data, and publish it later.")
        outbox.match = ["outbox"]
        m.terms.append(outbox)
        return m
    }
}
