import Foundation
import StrataCore

// A neutral synthetic repo for drift checks, written to a temp dir by each check: a Go module with three
// binaries (one a cobra tool with subcommands), sqlc queries, raw SQL in Go, a Valkey lock, RabbitMQ
// declarations, typed and iota const blocks, a Postgres enum and CHECK, a Procfile, plus vendor/ and
// generated code that drift must skip. `manifest()` maps all of it, so a clean check finds nothing.

final class DriftFixture {
    let root: URL

    init() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("strata-drift-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in Self.files { try write(path, text) }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func edit(_ path: String, _ change: (String) -> String) throws {
        let url = root.appendingPathComponent(path)
        try write(path, change(try String(contentsOf: url, encoding: .utf8)))
    }

    func move(_ from: String, _ to: String) throws {
        let target = root.appendingPathComponent(to)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: root.appendingPathComponent(from), to: target)
    }

    func remove(_ path: String) throws { try FileManager.default.removeItem(at: root.appendingPathComponent(path)) }

    /// The 1-based line of the first line containing `text`.
    func line(_ text: String, in path: String) -> Int {
        let lines = (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8))?.components(separatedBy: "\n") ?? []
        return (lines.firstIndex { $0.contains(text) } ?? -1) + 1
    }

    func manifest(_ text: String? = nil) -> Manifest? {
        let (manifest, diagnostics) = ManifestParser.parse(text ?? manifestText(), source: .file(root.appendingPathComponent("map.yaml")))
        for diagnostic in diagnostics where diagnostic.severity == .error { print("fixture manifest: \(diagnostic)") }
        return manifest
    }

    func check(_ text: String? = nil, kinds: Set<DriftKind> = Set(DriftKind.allCases)) -> DriftReport? {
        manifest(text).map { Drift.check($0, options: DriftOptions(kinds: kinds)) }
    }

    /// A map that covers everything in the fixture, with code lines read from the files.
    func manifestText(extraOps: String = "", extraNodes: String = "") -> String {
        """
        strata: 1
        id: drift-fixture
        title: Drift fixture
        kind: architecture
        repo: \(root.path)
        enums:
          - id: order-status
            label: Order status
            code: internal/orders/status.go:\(line("type Status", in: "internal/orders/status.go") + 2)
            values:
              - { value: 10, name: new }
              - { value: 20, name: paid }
              - { value: 30, name: shipped, terminal: true }
          - id: order-kind
            label: Order kind
            values:
              - { value: retail, name: retail }
              - { value: wholesale, name: wholesale }
          - id: priority
            label: Priority
            values:
              - { value: 0, name: low }
              - { value: 1, name: normal }
              - { value: 2, name: high }
        nodes:
          - { id: web, kind: client }
          - id: orders
            kind: service
            label: orders-svc
            code: cmd
            doc: Takes orders. `Cancel()` closes one; `Acquire()` guards the sweeper.
            ops:
              - id: get-order
                kind: sql
                target: db
                label: GetOrder
                query: |
                  -- name: GetOrder :one
                  SELECT id, customer_id, state
                  FROM orders
                  WHERE id = $1;
                code: internal/store/query.sql:\(line("-- name: GetOrder", in: "internal/store/query.sql"))
              - id: list-orders
                kind: sql
                target: db
                label: ListOrders
                query: |
                  -- name: ListOrders :many
                  select id, state
                  from orders   -- by customer
                  where customer_id = ?
                  order by id desc
                code: internal/store/query.sql:\(line("-- name: ListOrders", in: "internal/store/query.sql"))
              - id: insert-order
                kind: sql
                target: db
                label: insert order
                tx: true
                query: |
                  BEGIN;
                  -- name: InsertOrder :one
                  INSERT INTO orders (customer_id, state) VALUES ($1, 'new') RETURNING id;
                  COMMIT;
                code: internal/store/query.sql:\(line("-- name: InsertOrder", in: "internal/store/query.sql"))
              - id: cancel
                kind: sql
                target: db
                label: cancel
                query: |
                  UPDATE orders
                  SET state = 'closed'
                  WHERE id = :id
                code: internal/orders/repo.go:\(line("func (r *Repo) Cancel", in: "internal/orders/repo.go"))
              - id: count-open
                kind: sql
                target: db
                label: count open
                query: |
                  /* how many are open */
                  SELECT count(*) FROM orders WHERE state = 'open'
                code: internal/orders/repo.go:\(line("func (r *Repo) Count", in: "internal/orders/repo.go") + 3)
              - id: price
                kind: cache
                target: valkey
                label: GET price
                command: GET
                key: "app:price:{sku}"
                code: internal/cache/keys.go:\(line("priceKeyPrefix", in: "internal/cache/keys.go"))
              - id: created
                kind: publish
                target: bus
                label: order.created
                topic: orders
                key: order.created
                code: internal/bus/bus.go:\(line("PublishWithContext", in: "internal/bus/bus.go"))
              - id: on-created
                kind: consume
                label: on order.created
                topic: orders.created
                code: internal/bus/bus.go:\(line("QueueDeclare", in: "internal/bus/bus.go"))
        \(extraOps)
            how:
              - id: sweep-lock
                title: One sweeper at a time
                summary: "`Acquire()` sets the lock with NX PX; `Release()` deletes it."
                code: internal/lock/lock.go:\(line("func (l *Lock) Acquire", in: "internal/lock/lock.go"))
                participants:
                  - { id: s, label: sweeper, node: orders }
                  - { id: v, label: valkey, node: valkey }
                steps:
                  - { id: take, from: s, to: v, label: take, command: "SET app:lock:sweep tok NX PX 15000", reply: OK,
                      code: "internal/lock/lock.go:\(line("Nx().Px", in: "internal/lock/lock.go"))" }
            inside:
              nodes:
                - { id: in, kind: port, label: from web }
                - { id: api, kind: service, binary: cmd/api, code: cmd/api/main.go }
                - { id: worker, kind: worker, binary: ./cmd/worker, code: cmd/worker/main.go }
                - { id: relay, kind: worker, binary: "tool start relay", code: internal/cli/cmds.go }
                - { id: sweeper, kind: cron, binary: "tool start sweeper --once" }
              edges:
                - { from: in, to: api }
        \(extraNodes)
          - { id: db, kind: postgres }
          - { id: valkey, kind: cache }
          - { id: bus, kind: topic, label: orders exchange }
        edges:
          - { from: web, to: orders }
          - { from: orders, to: db }
          - { from: orders, to: valkey }
          - { from: orders, to: bus }

        """
    }

    static let files: [String: String] = [
        "go.mod": "module example.com/shop\n\ngo 1.23\n",
        "cmd/api/main.go": """
            package main

            import "example.com/shop/internal/orders"

            func main() {
            \t_ = orders.Repo{}
            }

            """,
        "cmd/worker/main.go": "package main\n\nfunc main() {}\n",
        "cmd/tool/main.go": "package main\n\nimport \"example.com/shop/internal/cli\"\n\nfunc main() { cli.Execute() }\n",
        "internal/cli/cmds.go": """
            package cli

            import "github.com/spf13/cobra"

            var start = &cobra.Command{Use: "start", Short: "Start a loop"}
            var relay = &cobra.Command{Use: "relay [flags]", Short: "Publish the outbox"}
            var sweeper = &cobra.Command{Use: "sweeper", Short: "Close stale orders"}

            func Execute() { start.AddCommand(relay, sweeper) }

            """,
        "internal/store/query.sql": """
            -- name: GetOrder :one
            SELECT id, customer_id, state
            FROM orders
            WHERE id = $1;

            -- name: ListOrders :many
            SELECT id, state FROM orders
            WHERE customer_id = sqlc.arg(customer_id)
            ORDER BY id DESC;

            -- name: InsertOrder :one
            INSERT INTO orders (customer_id, state) VALUES ($1, 'new') RETURNING id;

            """,
        "internal/store/query.sql.go": """
            // Code generated by sqlc. DO NOT EDIT.

            package store

            const getOrder = `-- name: GetOrder :one
            SELECT id, customer_id, state FROM orders WHERE id = $1
            `

            const strayQuery = `SELECT secret FROM generated_only WHERE id = $1`

            """,
        "internal/store/migrations/001_init.sql": """
            CREATE TYPE order_kind AS ENUM ('retail', 'wholesale');

            CREATE TABLE orders (
                id bigserial PRIMARY KEY,
                customer_id bigint NOT NULL,
                state text NOT NULL CHECK (state IN ('new', 'open', 'closed'))
            );

            INSERT INTO settings (name) VALUES ('seed');

            """,
        "internal/orders/status.go": """
            package orders

            // Status is stored in orders.status.
            type Status int

            const (
            \tStatusNew     Status = 10
            \tStatusPaid    Status = 20
            \tStatusShipped Status = 30
            )

            type Priority int

            const (
            \tPriorityLow Priority = iota
            \tPriorityNormal
            \tPriorityHigh
            )

            """,
        "internal/orders/repo.go": """
            package orders

            import (
            \t"context"
            \t"database/sql"
            \t"errors"
            )

            var errMissing = errors.New("update failed: order not found")
            var hint = "select an option from the list"
            var note = "delete from cache failed"

            type Repo struct{ db *sql.DB }

            // Cancel marks an order closed.
            func (r *Repo) Cancel(ctx context.Context, id int64) error {
            \t_, err := r.db.ExecContext(ctx,
            \t\t"UPDATE orders SET state = 'closed' "+
            \t\t\t"WHERE id = $1", id)
            \treturn err
            }

            // Count counts open orders.
            func (r *Repo) Count(ctx context.Context) (int, error) {
            \tvar n int
            \terr := r.db.QueryRowContext(ctx, `
            \t\tSELECT count(*)
            \t\tFROM orders
            \t\tWHERE state = 'open'`).Scan(&n)
            \treturn n, err
            }

            // Search is built at run time; its fragment isn't a query of its own.
            func (r *Repo) Search(ctx context.Context, cond string) error {
            \t_, err := r.db.ExecContext(ctx, "SELECT id FROM orders WHERE "+cond)
            \treturn err
            }

            """,
        "internal/lock/lock.go": """
            package lock

            import (
            \t"context"
            \t"fmt"
            \t"time"

            \t"github.com/valkey-io/valkey-go"
            )

            type Lock struct {
            \tclient valkey.Client
            \tname   string
            }

            func key(name string) string { return fmt.Sprintf("app:lock:%s", name) }

            // Acquire sets the key with NX PX.
            func (l *Lock) Acquire(ctx context.Context, ttl time.Duration) bool {
            \tcmd := l.client.B().Set().Key(key(l.name)).Value("tok").Nx().Px(ttl).Build()
            \treturn l.client.Do(ctx, cmd).Error() == nil
            }

            // Release deletes the key.
            func (l *Lock) Release(ctx context.Context) {
            \tl.client.Do(ctx, l.client.B().Del().Key(key(l.name)).Build())
            }

            """,
        "internal/cache/keys.go": """
            package cache

            // Prices, one per SKU.
            const priceKeyPrefix = "app:price:"

            const userAgent = "shop/1.0"

            """,
        "internal/bus/bus.go": """
            package bus

            import (
            \t"context"

            \tamqp "github.com/rabbitmq/amqp091-go"
            )

            func Declare(ch *amqp.Channel) error {
            \tif err := ch.ExchangeDeclare("orders", "topic", true, false, false, false, nil); err != nil {
            \t\treturn err
            \t}
            \t_, err := ch.QueueDeclare("orders.created", true, false, false, false, nil)
            \treturn err
            }

            func Publish(ctx context.Context, ch *amqp.Channel, body []byte) error {
            \treturn ch.PublishWithContext(ctx, "orders", "order.created", false, false, amqp.Publishing{Body: body})
            }

            """,
        "Procfile": "web: ./bin/api\nworker: ./bin/worker\n",
        "tools/gen/main.go": "package main\n\nfunc main() {}\n",
        "vendor/example.com/dep/dep.go": "package dep\n\nconst depQueue = \"vendored.queue\"\n\nvar q = `SELECT x FROM vendored WHERE id = $1`\n",
        "node_modules/pkg/q.sql": "-- name: FromNodeModules :one\nSELECT 1;\n",
    ]
}
