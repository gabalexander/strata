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

public extension Fixtures {
    /// `checkoutWithOps` with data (docs/manifest.md, Data): the orders database's tables with columns,
    /// keys, notes, indexes, volumes and sample rows whose ids really join (users → orders → order_items
    /// and payments, the outbox, a price history keyed on a composite key, NULLs), and the Order and
    /// Price entities orders-svc assembles from them. payments-svc writes `payments`, so tables have
    /// different owners, and both orders-svc and reporting write `orders`.
    static var checkoutWithData: Manifest {
        var m = checkoutWithOps
        m.id = "checkout-data"
        func column(_ name: String, _ type: String, pk: Bool = false, ref: String? = nil, unique: Bool = false,
                    nullable: Bool? = nil, note: String? = nil) -> Column {
            var c = Column(name: name)
            c.type = type; c.pk = pk; c.ref = ref; c.unique = unique; c.nullable = nullable; c.note = note
            return c
        }
        func table(_ name: String, rows: Double?, growth: Double? = nil, _ edit: (inout TableSchema) -> Void) -> TableSchema {
            var t = TableSchema(name: name)
            var volume = TableVolume()
            volume.rows = rows; volume.growthPerDay = growth
            t.volume = volume
            edit(&t)
            return t
        }

        let users = table("users", rows: 2_400_000, growth: 3_000) {
            $0.doc = "Accounts, written by the accounts service (not on this map)."
            $0.columns = [
                column("id", "uuid", pk: true),
                column("email", "text", unique: true),
                column("name", "text"),
                column("created_at", "timestamptz"),
                column("deleted_at", "timestamptz", nullable: true, note: "soft delete; NULL while active"),
            ]
            $0.indexes = ["users_pkey (id)", "users_email_key (email)"]
            $0.rows = [
                ["u-42", "ada@example.com", "Ada Lovelace", "2025-03-02 10:20", nil],
                ["u-77", "grace@example.com", "Grace Hopper", "2025-06-18 08:05", nil],
                ["u-90", "alan@example.com", "Alan Turing", "2024-11-09 17:44", "2026-11-02 09:00"],
            ]
        }
        let orders = table("orders", rows: 12_000_000, growth: 40_000) {
            $0.doc = "One row per checkout."
            $0.columns = [
                column("id", "uuid", pk: true),
                column("user_id", "uuid", ref: "users.id"),
                column("status", "text", note: "pending | paid | shipped | cancelled"),
                column("total_cents", "bigint", note: "sum of the order's items"),
                column("currency", "char(3)"),
                column("created_at", "timestamptz"),
                column("paid_at", "timestamptz", nullable: true, note: "NULL until the payment is captured"),
            ]
            $0.indexes = ["orders_pkey (id)", "orders_user_id_idx (user_id)", "orders_status_created_idx (status, created_at)"]
            $0.rows = [
                ["o-9f1c", "u-42", "paid", "4200", "EUR", "2026-11-18 09:14", "2026-11-18 09:14"],
                ["o-77ab", "u-42", "pending", "1999", "EUR", "2026-11-18 11:02", nil],
                ["o-3c2d", "u-77", "shipped", "12850", "EUR", "2026-11-17 16:40", "2026-11-17 16:41"],
                ["o-5e10", "u-90", "cancelled", "1000", "EUR", "2026-10-30 21:15", nil],
            ]
        }
        let items = table("order_items", rows: 31_000_000, growth: 100_000) {
            $0.doc = "The lines of an order, keyed by order and line number."
            $0.columns = [
                column("order_id", "uuid", pk: true, ref: "orders.id"),
                column("line_no", "int", pk: true),
                column("sku", "text", ref: "prices.sku"),
                column("qty", "int"),
                column("unit_cents", "bigint", note: "the price when the order was placed"),
            ]
            $0.indexes = ["order_items_pkey (order_id, line_no)"]
            $0.rows = [
                ["o-9f1c", "1", "A-1", "2", "1600"],
                ["o-9f1c", "2", "B-7", "1", "1000"],
                ["o-77ab", "1", "C-3", "1", "1999"],
                ["o-3c2d", "1", "A-1", "5", "1600"],
                ["o-3c2d", "2", "D-9", "1", "4850"],
                ["o-5e10", "1", "B-7", "1", "1000"],
            ]
        }
        let payments = table("payments", rows: 11_000_000, growth: 38_000) {
            $0.doc = "One payment per order; a retry updates the row."
            $0.owner = "payments"
            $0.columns = [
                column("id", "uuid", pk: true),
                column("order_id", "uuid", ref: "orders.id", unique: true),
                column("provider", "text"),
                column("status", "text", note: "authorized | captured | declined | refunded"),
                column("amount_cents", "bigint"),
                column("provider_ref", "text", nullable: true, note: "the acquirer's charge id"),
                column("captured_at", "timestamptz", nullable: true),
            ]
            $0.indexes = ["payments_pkey (id)", "payments_order_id_key (order_id)"]
            $0.rows = [
                ["pay-1a", "o-9f1c", "stripe", "captured", "4200", "ch_3PqX1", "2026-11-18 09:14"],
                ["pay-2b", "o-3c2d", "stripe", "captured", "12850", "ch_3PrA7", "2026-11-17 16:41"],
                ["pay-3c", "o-5e10", "stripe", "declined", "1000", nil, nil],
            ]
        }
        let prices = table("prices", rows: 18_000) {
            $0.doc = "Price history per SKU. The current price is the row with no `valid_to`; Redis caches it."
            $0.columns = [
                column("sku", "text", pk: true),
                column("valid_from", "date", pk: true),
                column("amount_cents", "bigint"),
                column("currency", "char(3)"),
                column("valid_to", "date", nullable: true, note: "NULL for the current price"),
            ]
            $0.indexes = ["prices_pkey (sku, valid_from)", "prices_sku_key (sku) WHERE valid_to IS NULL"]
            $0.rows = [
                ["A-1", "2026-06-01", "1450", "EUR", "2026-10-01"],
                ["A-1", "2026-10-01", "1600", "EUR", nil],
                ["B-7", "2026-09-15", "1000", "EUR", nil],
                ["C-3", "2026-11-01", "1999", "EUR", nil],
                ["D-9", "2026-08-20", "4850", "EUR", nil],
            ]
        }
        let outbox = table("outbox", rows: 4_000, growth: 40_000) {
            $0.doc = "Events written in the order's transaction; the relay publishes them and prunes the published rows hourly."
            $0.columns = [
                column("id", "bigserial", pk: true),
                column("aggregate_id", "uuid", ref: "orders.id"),
                column("topic", "text"),
                column("payload", "jsonb"),
                column("published_at", "timestamptz", nullable: true, note: "NULL until the relay publishes it"),
            ]
            $0.indexes = ["outbox_pkey (id)", "outbox_unpublished_idx (id) WHERE published_at IS NULL"]
            $0.rows = [
                ["98121", "o-3c2d", "order-events", #"{"type":"OrderPlaced","order_id":"o-3c2d","total":12850}"#, "2026-11-17 16:40"],
                ["98122", "o-9f1c", "order-events", #"{"type":"OrderPlaced","order_id":"o-9f1c","total":4200}"#, "2026-11-18 09:14"],
                ["98123", "o-77ab", "order-events", #"{"type":"OrderPlaced","order_id":"o-77ab","total":1999}"#, nil],
            ]
        }

        var order = Entity(name: "Order", root: "orders")
        order.source = "db"
        order.includes = ["order_items", "users", "payments"]
        order.doc = "The aggregate orders-svc loads and saves as one unit: the order, its lines, the buyer and the payment."
        order.code = ["services/orders/domain/order.go:14"]
        var price = Entity(name: "Price", root: "prices")
        price.source = "db"
        price.doc = "A SKU's price for a period. Read through the Redis cache; a miss loads the row with no `valid_to`."
        price.code = ["services/orders/pricing.go:27"]

        var root = m.root
        root.edges.append(Edge(from: "payments", to: "db"))
        root.edges[root.edges.count - 1].protocol = "sql"
        for index in root.nodes.indices {
            switch root.nodes[index].id {
            case "db":
                root.nodes[index].schema = [users, orders, items, payments, prices, outbox]
            case "orders":
                root.nodes[index].entities = [order, price]
                for o in root.nodes[index].ops.indices where root.nodes[index].ops[o].id == "insert-order" {
                    root.nodes[index].ops[o].tables = ["orders", "order_items", "outbox"]
                }
                var load = Operation(id: "load-order", kind: .sql, label: "SELECT order aggregate")
                load.target = "db"; load.access = .read
                load.tables = ["orders", "order_items", "users", "payments"]
                load.indexes = ["orders_pkey", "order_items_pkey", "payments_order_id_key"]
                load.query = """
                SELECT o.*, i.*, u.email, p.status AS payment_status
                FROM orders o
                JOIN users u ON u.id = o.user_id
                JOIN order_items i ON i.order_id = o.id
                LEFT JOIN payments p ON p.order_id = o.id
                WHERE o.id = $1;
                """
                load.doc = "Loads the **Order** aggregate in one round trip."
                load.code = ["services/orders/repo/load.go:22"]
                root.nodes[index].ops.insert(load, at: 4)
            case "payments":
                var record = Operation(id: "record-payment", kind: .sql, label: "UPSERT payment")
                record.target = "db"; record.access = .write; record.tables = ["payments"]
                record.query = """
                INSERT INTO payments (id, order_id, provider, status, amount_cents)
                VALUES ($1, $2, 'stripe', $3, $4)
                ON CONFLICT (order_id) DO UPDATE SET status = EXCLUDED.status;
                """
                record.code = ["services/payments/store.go:61"]
                root.nodes[index].ops.append(record)
            default: break
            }
        }
        m.root = root
        return m
    }
}
