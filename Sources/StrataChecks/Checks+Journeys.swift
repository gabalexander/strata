import Foundation
import StrataCore

// Journeys (docs/manifest.md, Journeys): decoding, validation with line numbers and suggestions, binds
// filled into queries, the row state replayed per step with each step's changes and status moves, the
// time line, the draft's order on a synthetic map, the bundled checkout journey and `strata journey`.

private let journeySource = ManifestSource.file(URL(fileURLWithPath: "/checks/journeys.yaml"))

/// The map a journey check runs on: an orders service with a database, a topic and an order-status enum.
private let journeyMap = """
    strata: 1
    id: shop
    title: Shop
    enums:
      - id: order-status
        values:
          - { value: pending, name: pending }
          - { value: paid, name: paid }
          - { value: shipped, name: shipped, terminal: true }
        transitions:
          - { from: pending, to: paid, by: orders/capture }
          - { from: paid, to: shipped }
    nodes:
      - { id: web, kind: client }
      - id: orders
        kind: service
        ops:
          - { id: create-order, kind: http, label: POST /orders, method: POST, path: /orders, request: '{ "sku": "B-7" }' }
          - id: insert-order
            kind: sql
            target: db
            label: INSERT order and payment
            access: write
            tables: [orders, payments]
            query: |
              INSERT INTO orders (id, user_id, status, total_cents) VALUES ($1, $2, 'pending', $3);
              INSERT INTO payments (id, order_id, status) VALUES ($4, $1, 'authorized');
          - { id: order-placed, kind: publish, target: events, label: OrderPlaced, topic: order-events, payload: '{ "order_id": "o-1" }' }
          - id: capture
            kind: sql
            target: db
            label: Capture
            access: write
            tables: [orders, payments]
            query: |
              UPDATE payments
              SET status = 'captured'
              WHERE order_id = @id;
              UPDATE orders
              SET status = 'paid'
              WHERE id = @id
                AND status = 'pending';
          - { id: get-price, kind: cache, target: cache, label: GET price, command: GET, key: "price:{sku}" }
        how:
          - id: capture-lock
            title: Capture under a row lock
            participants: [{ id: o, node: orders }, { id: d, node: db }]
            steps: [{ from: o, to: d, label: lock, command: "SELECT 1 FROM orders WHERE id = 'o-77ab' FOR UPDATE" }]
      - { id: cache, kind: cache }
      - id: db
        kind: database
        schema:
          - table: users
            columns: [{ name: id, pk: true }, { name: email }]
            rows: [[u-42, ada@example.com]]
          - table: orders
            columns:
              - { name: id, pk: true }
              - { name: user_id, ref: users.id }
              - { name: status, enum: order-status }
              - { name: total_cents }
            rows: [[o-1, u-42, paid, 500]]
          - table: payments
            columns:
              - { name: id, pk: true }
              - { name: order_id, ref: orders.id }
              - { name: status }
            rows: [[p-1, o-1, captured]]
      - { id: events, kind: topic }
      - { id: mailer, kind: worker, ops: [{ id: on-placed, kind: consume, label: OrderPlaced consumer, topic: order-events }] }
    edges:
      - { from: web, to: orders }
      - { from: orders, to: db }
      - { from: orders, to: cache }
      - { from: orders, to: events }
      - { from: events, to: mailer }
    flows:
      - id: place
        from: web
        rate: 1/s
        steps:
          - call: orders
            op: create-order
            steps:
              - { call: db, op: insert-order }
              - { publish: events, op: order-placed }
      - { id: mail, on: events, by: mailer, op: on-placed, steps: [{ work: 1ms }] }

    """

/// The manifest reference's journeys fence on the map it describes.
func journeySpecManifest(_ fence: String) -> String {
    journeyMap.replacingOccurrences(of: "id: shop", with: "id: spec") + fence
}

private func parse(_ journeys: String) -> (Manifest?, [Diagnostic]) {
    ManifestParser.parse(journeyMap + journeys, source: journeySource)
}

/// The line of a journey file's text that contains `marker` (1-based), counting the map above it.
private func line(of marker: String, in journeys: String) -> Int? {
    let lines = (journeyMap + journeys).components(separatedBy: "\n")
    return lines.firstIndex { $0.contains(marker) }.map { $0 + 1 }
}

private let goodJourney = """
    journeys:
      - id: order-paid
        title: An order from placed to paid
        brief: Order o-77ab is placed and paid.
        entity: { table: orders, id: o-77ab, label: order }
        related:
          - { table: payments, id: p-31, label: payment }
        steps:
          - id: place
            at: "10:02:00.000"
            label: The customer places the order
            op: orders/create-order
            message: { payload: { sku: A-1, qty: 2 } }
          - id: price
            at: +1ms
            label: Read the price
            op: orders/get-price
            binds: { sku: A-1 }
          - id: insert
            at: +12ms
            label: Insert the order and its payment
            op: orders/insert-order
            binds: [o-77ab, u-42, 1999, p-31]
            rows:
              - insert: orders
                values: { id: o-77ab, user_id: u-42, status: pending, total_cents: 1999 }
              - insert: payments
                values: { id: p-31, order_id: o-77ab, status: authorized }
          - id: event
            at: +3ms
            label: Publish OrderPlaced
            op: orders/order-placed
            message: { to: events, key: o-77ab, payload: { order_id: o-77ab, status: pending } }
          - id: mail
            at: +20ms
            label: The mailer reads it
            op: mailer/on-placed
          - id: capture
            at: "10:02:41.300"
            label: Paid
            op: orders/capture
            binds: { id: o-77ab }
            status: { enum: order-status, from: pending, to: paid }
            rows:
              - update: payments
                id: p-31
                set: { status: captured }
            how: orders/capture-lock

    """

@MainActor func journeyChecks() -> [CheckCase] {
    [
        CheckCase(name: "journey reference fence decodes cleanly") {
            guard let fence = try referenceFences().first(where: { $0.hasPrefix("journeys:") }) else { check(false, "no journeys fence"); return }
            let (manifest, diagnostics) = ManifestParser.parse(journeySpecManifest(fence), source: journeySource)
            check(manifest != nil && diagnostics.isEmpty, "journeys fence: \(diagnostics)")
            check(manifest?.journeys.first?.steps.count == 4, "fence steps: \(manifest?.journeys.first?.steps.count ?? 0)")
        },
        CheckCase(name: "journey decodes entity, steps, binds, rows, status, message and times") {
            let (manifest, diagnostics) = parse(goodJourney)
            check(manifest != nil && diagnostics.isEmpty, "clean journey: \(diagnostics)")
            guard let journey = manifest?.journeys.first else { check(false, "no journey"); return }
            check(journey.id == "order-paid" && journey.title == "An order from placed to paid" && journey.brief == "Order o-77ab is placed and paid.", "header")
            check(journey.entity.table == "orders" && journey.entity.key?.id == "o-77ab" && journey.entity.label == "order", "entity")
            check(journey.related.map(\.table) == ["payments"] && journey.related.first?.key?.id == "p-31", "related")
            check(journey.steps.map(\.id) == ["place", "price", "insert", "event", "mail", "capture"], "step ids")
            let insert = journey.steps[2]
            check(insert.binds == [JourneyBind(value: "o-77ab"), JourneyBind(value: "u-42"), JourneyBind(value: "1999"), JourneyBind(value: "p-31")], "positional binds")
            check(journey.steps[1].binds == [JourneyBind(name: "sku", value: "A-1")], "named binds")
            check(insert.rows.map(\.kind) == [.insert, .insert] && insert.rows[0].values.first == JourneyCell(column: "id", value: "o-77ab"), "insert rows")
            let capture = journey.steps[5]
            check(capture.rows.first?.kind == .update && capture.rows.first?.key?.id == "p-31" && capture.rows.first?.values == [JourneyCell(column: "status", value: "captured")], "update row")
            check(capture.status == [JourneyStatus(enumID: "order-status", from: "pending", to: "paid")].map { var s = $0; s.line = capture.status.first?.line; return s }, "status")
            check(capture.how == "orders/capture-lock", "how")
            check(journey.steps[3].message?.to == "events" && journey.steps[3].message?.key == "o-77ab"
                  && journey.steps[3].message?.payload == #"{ "order_id": "o-77ab", "status": "pending" }"#, "message")
            check(journey.steps[0].at == "10:02:00.000" && journey.steps[1].at == "+1ms", "at as written")
            // Steps default to s1, s2 …, and status takes a list.
            let (other, findings) = parse("""
                journeys:
                  - id: j
                    title: J
                    entity: { table: orders, id: o-1 }
                    steps:
                      - { label: ship, op: orders/capture, status: [{ enum: order-status, from: paid, to: shipped }] }
                """)
            check(other?.journeys.first?.steps.first?.id == "s1" && other?.journeys.first?.steps.first?.status.count == 1, "defaults: \(findings)")
        },
        CheckCase(name: "journey validation names bad tables, columns, ops, enums and rows with lines") {
            let bad = """
                journeys:
                  - id: j
                    title: J
                    entity: { table: ordrs, id: o-1 }
                    steps:
                      - { label: a, op: orders/captur }
                  - id: k
                    title: K
                    entity: { table: orders, id: o-2 }
                    steps:
                      - label: b
                        op: orders/capture
                        rows:
                          - { update: orders, id: o-1, set: { stauts: paid } }
                          - { update: orders, id: o-9, set: { status: paid } }
                          - { insert: orders, values: { id: o-1, status: pending } }
                        status: { enum: order-status, from: pending, to: Paid }
                      - { label: c, node: orders, message: { to: db }, how: orders/nope }
                      - { label: e, node: orders, path: [ordrs] }
                      - { label: d, op: orders/capture, status: { enum: order-stat, to: paid } }
                """
            let (manifest, diagnostics) = parse(bad)
            check(manifest == nil, "a bad journey is an error")
            func has(_ text: String, at marker: String, _ severity: Diagnostic.Severity = .error) {
                let expected = line(of: marker, in: bad)
                check(diagnostics.contains { $0.message.contains(text) && $0.severity == severity && $0.line == expected },
                      "missing '\(text)' on line \(expected ?? 0): \(diagnostics.map(\.description))")
            }
            has("unknown table 'ordrs'; did you mean 'orders'?", at: "table: ordrs")
            has("unknown op 'orders/captur'; did you mean 'orders/capture'?", at: "op: orders/captur }")
            has("orders o-2 is not a sample row and no step inserts it; did you mean o-1?", at: "id: o-2")
            has("unknown column 'stauts' in 'orders'; did you mean 'status'?", at: "stauts")
            has("orders o-9 doesn't exist before this step", at: "id: o-9")
            has("orders o-1 already exists at this step", at: "insert: orders")
            has("unknown value Paid in 'order-status'", at: "to: Paid")
            has("'db' must be a queue or topic; it is a database", at: "message: { to: db }")
            has("'orders' has no mechanism 'nope'", at: "orders/nope")
            has("unknown deep-dive path 'ordrs'; did you mean 'orders'?", at: "path: [ordrs]")
            has("unknown enum 'order-stat'; did you mean 'order-status'?", at: "order-stat,")
            check(diagnostics.allSatisfy { $0.path?.hasPrefix("journeys.") == true }, "paths: \(diagnostics.compactMap(\.path))")
        },
        CheckCase(name: "journey validation warns about transitions, binds, notes and time") {
            let warned = """
                journeys:
                  - id: w
                    title: W
                    entity: { table: orders, id: o-1 }
                    steps:
                      - id: back
                        at: 5ms
                        label: shipped back to pending
                        op: orders/insert-order
                        binds: [o-1, u-42]
                        rows: [{ update: orders, id: o-1, set: { status: pending } }]
                        note: "one\\ntwo\\nthree"
                      - id: again
                        at: 1ms
                        label: paid by the wrong op
                        op: orders/insert-order
                        status: { enum: order-status, from: pending, to: paid }
                      - id: same
                        label: no change
                        op: orders/capture
                        binds: { idd: o-1 }
                        rows: [{ update: orders, id: o-1, set: { status: paid } }]
                      - id: ship
                        label: shipped, then out of terminal
                        node: orders
                        rows: [{ update: orders, id: o-1, set: { status: shipped } }, { update: users, id: u-42, set: { email: x } }]
                      - id: out
                        label: out of terminal
                        node: orders
                        status: { enum: order-status, from: shipped, to: paid }
                """
            let (manifest, diagnostics) = parse(warned)
            check(manifest != nil, "warnings keep the manifest: \(diagnostics.filter { $0.severity == .error })")
            func has(_ text: String, at marker: String) {
                let expected = line(of: marker, in: warned)
                check(diagnostics.contains { $0.message.contains(text) && $0.severity == .warning && $0.line == expected },
                      "missing warning '\(text)' on line \(expected ?? 0): \(diagnostics.map(\.description))")
            }
            has("'order-status' has no transition paid → pending; from paid it moves to shipped", at: "set: { status: pending }")
            has("no bind for $3, $4 in orders/insert-order", at: "binds: [o-1, u-42]")
            has("keep a step's note to two lines", at: "note:")
            has("at goes back in time: 1 ms is before 5 ms", at: "at: 1ms")
            has("pending → paid in 'order-status' is made by orders/capture, not orders/insert-order", at: "status: { enum: order-status, from: pending, to: paid }")
            has("this update changes nothing", at: "set: { status: paid }")
            has("bind idd fills no placeholder of orders/capture; it has @id", at: "idd")
            has("shipped is terminal in 'order-status'", at: "from: shipped, to: paid")
        },
        CheckCase(name: "journey binds fill ?, $n, named placeholders and keys as literals") {
            let question = JourneyFill.sql("SELECT * FROM t WHERE a = ? AND b = ? AND c = '?' -- ?\nAND d = ?",
                                           binds: [JourneyBind(value: "5"), JourneyBind(value: "x'y"), JourneyBind(value: nil)])
            check(question.text == "SELECT * FROM t WHERE a = 5 AND b = 'x''y' AND c = '?' -- ?\nAND d = NULL", "question marks: \(question.text)")
            check(question.placeholders == ["?", "?", "?"] && question.unfilled.isEmpty && question.unused.isEmpty, "question marks list")
            let numbered = JourneyFill.sql("UPDATE t SET s = $2 WHERE id = $1 AND s = $2", binds: [JourneyBind(value: "o-1"), JourneyBind(value: "now()")])
            check(numbered.text == "UPDATE t SET s = now() WHERE id = 'o-1' AND s = now()", "numbered: \(numbered.text)")
            let named = JourneyFill.sql("SELECT x::text FROM t WHERE id = @id AND k = :key AND z = sqlc.arg(zone) AND j @> '{}'",
                                        binds: [JourneyBind(name: "id", value: "7"), JourneyBind(name: "key", value: "7", quoted: true),
                                                JourneyBind(name: "zone", value: "true")])
            check(named.text == "SELECT x::text FROM t WHERE id = 7 AND k = '7' AND z = TRUE AND j @> '{}'", "named: \(named.text)")
            check(named.placeholders == ["@id", ":key", "sqlc.arg(zone)"], "named list: \(named.placeholders)")
            let missing = JourneyFill.sql("SELECT 1 WHERE a = @a AND b = @b", binds: [JourneyBind(name: "a", value: "1"), JourneyBind(name: "c", value: "2")])
            check(missing.unfilled == ["@b"] && missing.unused == ["c"], "unfilled and unused: \(missing.unfilled) \(missing.unused)")
            let key = JourneyFill.braces("app:{tenant}:lock:{sid}", binds: [JourneyBind(name: "sid", value: "90002"), JourneyBind(name: "tenant", value: "acme")])
            check(key.text == "app:acme:lock:90002", "braces: \(key.text)")
            let positionalKey = JourneyFill.braces("price:{sku}", binds: [JourneyBind(value: "A-1")])
            check(positionalKey.text == "price:A-1", "positional braces: \(positionalKey.text)")
        },
        CheckCase(name: "journey replays rows per step with before and after and status moves") {
            guard let manifest = parse(goodJourney).0, let journey = manifest.journeys.first else { check(false, "no journey"); return }
            let playback = manifest.replay(journey)
            check(playback.issues.isEmpty, "issues: \(playback.issues.map(\.message))")
            let order = JourneyRowID(path: [], node: "db", table: "orders", key: "o-77ab")
            let payment = JourneyRowID(path: [], node: "db", table: "payments", key: "p-31")
            check(playback.entity == order && playback.related == [payment], "entity and related")
            check(playback.initial.map(\.id) == [order, payment] && playback.initial.allSatisfy { !$0.exists }, "absent before their insert")
            check(playback.insertion(of: order) == 2 && playback.title(order) == "orders o-77ab" && playback.role(payment) == "payment", "insertion, title, role")
            // Before the insert the rows are absent; after it they hold the inserted values.
            check(playback.rows(after: 1).first { $0.id == order }?.exists == false, "absent at step 2")
            let inserted = playback.frames[2]
            check(inserted.row(order)?.value("status") == "pending" && inserted.row(order)?.value("total_cents") == "1999", "inserted values")
            check(inserted.diff(order)?.kind == .insert && inserted.diff(order)?.cells.count == 4, "insert diff: \(String(describing: inserted.diff(order)))")
            check(inserted.moves.map { "\($0.enumID):\($0.from ?? "-")>\($0.to)" } == ["order-status:->pending"], "entered move: \(inserted.moves)")
            check(inserted.command?.kind == .sql && inserted.command?.text.contains("VALUES ('o-77ab', 'u-42', 'pending', 1999)") == true, "filled query")
            check(playback.frames[1].command?.text == "GET price:A-1", "filled key: \(playback.frames[1].command?.text ?? "")")
            check(playback.frames[0].command?.text == #"{ "sku": "A-1", "qty": 2 }"# && playback.frames[0].command?.title == "POST /orders", "request from message")
            check(playback.frames[4].command?.text == #"{ "order_id": "o-77ab", "status": "pending" }"# && playback.frames[4].target == "events", "consumer receives the payload")
            // The status applies to the order row (it holds pending); the update moves the payment.
            let paid = playback.frames[5]
            check(paid.diff(order)?.cells == [JourneyCellChange(column: "status", before: "pending", after: "paid")], "status applied: \(String(describing: paid.diff(order)))")
            check(paid.diff(payment)?.cells == [JourneyCellChange(column: "status", before: "authorized", after: "captured")], "update diff")
            check(paid.moves.count == 1 && paid.moves[0].transition?.by == "orders/capture" && paid.moves[0].row == order, "move follows its transition")
            check(paid.row(order)?.value("status") == "paid" && playback.frames[4].row(order)?.value("status") == "pending", "state before and after")
            check(paid.command?.text.contains("WHERE id = 'o-77ab'") == true && paid.node == "orders" && paid.target == "db", "capture step")
            // Times: a clock, then offsets from the step before.
            check(playback.frames.map { $0.instant.map(JourneyClock.format) ?? "" }
                  == ["10:02:00", "10:02:00.001", "10:02:00.013", "10:02:00.016", "10:02:00.036", "10:02:41.300"], "times")
            check(JourneyClock.delta(paid.instant, after: playback.frames[4].instant) == "+41.26 s", "delta")
        },
        CheckCase(name: "journey keys: composite primary keys and a scalar id for the first column") {
            let composite = journeyMap.replacingOccurrences(of: "\n  - { id: events, kind: topic }", with: """

                  - id: legacy
                    kind: database
                    schema:
                      - table: items
                        columns: [{ name: order_id, pk: true }, { name: sku, pk: true }, { name: qty }]
                        rows: [[o-1, A-1, 2], [o-1, B-7, 1]]
                  - { id: events, kind: topic }
                """)
            let (manifest, diagnostics) = ManifestParser.parse(composite + """
                journeys:
                  - id: c
                    title: C
                    entity: { table: items, key: { order_id: o-1, sku: B-7 } }
                    steps:
                      - label: more
                        node: orders
                        rows:
                          - { update: items, key: { order_id: o-1, sku: B-7 }, set: { qty: 3 } }
                          - { insert: items, values: { order_id: o-1, sku: C-3, qty: 1 } }
                """, source: journeySource)
            check(manifest != nil && diagnostics.isEmpty, "composite keys: \(diagnostics)")
            guard let manifest, let journey = manifest.journeys.first else { return }
            let playback = manifest.replay(journey)
            let item = JourneyRowID(path: [], node: "legacy", table: "items", key: "o-1,B-7")
            check(playback.entity == item && playback.keyLabel(item) == "o-1 · B-7", "composite entity: \(String(describing: playback.entity))")
            check(playback.frames[0].diff(item)?.cells == [JourneyCellChange(column: "qty", before: "1", after: "3")], "composite update")
            check(playback.frames[0].rows.contains { $0.id.key == "o-1,C-3" && $0.exists }, "composite insert")
        },
        CheckCase(name: "journey draft follows flows and transitions in order on a synthetic map") {
            guard let manifest = parse("").0 else { check(false, "map"); return }
            // A new order: the flow that inserts it, then the queue it publishes to, then the lifecycle.
            let fresh = try manifest.draftJourney(table: "orders", id: "o-9")
            check(fresh.inserted && fresh.entityID == "o-9", "new row")
            check(fresh.steps.map(\.op) == ["orders/create-order", "orders/insert-order", "orders/order-placed", "mailer/on-placed", "orders/capture"],
                  "draft order: \(fresh.steps.map { $0.op ?? $0.id })")
            let insert = fresh.steps.first { $0.op == "orders/insert-order" }
            check(insert?.rows.map(\.table) == ["orders", "payments"], "inserts: \(insert?.rows.map(\.table) ?? [])")
            check(insert?.rows.first?.values.contains(JourneyCell(column: "status", value: "pending")) == true, "enters the start value")
            check(insert?.rows.last?.values.contains(JourneyCell(column: "id", value: "p-2")) == true
                  && insert?.rows.last?.values.contains(JourneyCell(column: "order_id", value: "o-9")) == true, "fresh related id and link")
            check(fresh.related.map(\.id) == ["p-2"], "related: \(fresh.related.map(\.id))")
            check(fresh.steps.last?.status == [JourneyStatus(enumID: "order-status", from: "pending", to: "paid")], "lifecycle status")
            check(fresh.steps.last?.comments.contains { $0.contains("paid → shipped") && $0.contains("no op makes it") } == true, "the move nobody makes")
            check(fresh.steps.last?.binds == [JourneyBind(name: "id", value: "o-9")], "named bind from the row: \(fresh.steps.last?.binds ?? [])")
            // The draft validates once pasted under the map.
            let pasted = ManifestParser.parse(journeyMap + fresh.yaml.split(separator: "\n").filter { !$0.hasPrefix("#") }.joined(separator: "\n"), source: journeySource)
            check(pasted.0 != nil && pasted.1.filter({ $0.severity == .error }).isEmpty, "draft validates: \(pasted.1)\n\(fresh.yaml)")
            // A sample row already paid has nothing left that an op makes.
            let sample = try manifest.draftJourney(table: "orders")
            check(!sample.inserted && sample.entityID == "o-1" && sample.steps.isEmpty, "sample row draft: \(sample.steps.map(\.id))")
            do { _ = try manifest.draftJourney(table: "ordrs"); check(false, "unknown table drafts") }
            catch let error as JourneyDraftError { check(error.message.contains("did you mean 'orders'"), error.message) }
        },
        CheckCase(name: "journey time parsing: offsets, clocks, timestamps") {
            check((try? JourneyTime.parse("40ms")) == JourneyTime(kind: .offset, seconds: 0.04), "offset")
            check((try? JourneyTime.parse("+1.5s")) == JourneyTime(kind: .offset, seconds: 1.5, relative: true), "relative")
            check((try? JourneyTime.parse("14:31:17.020"))?.kind == .clock && abs(((try? JourneyTime.parse("14:31:17.020"))?.seconds ?? 0) - 52277.02) < 1e-6, "clock")
            check((try? JourneyTime.parse("2026-11-19T14:31:17Z"))?.seconds == 1_795_098_677, "timestamp: \(String(describing: try? JourneyTime.parse("2026-11-19T14:31:17Z")))")
            check((try? JourneyTime.parse("2026-11-19T16:31:17+02:00"))?.seconds == 1_795_098_677, "timestamp with zone")
            check((try? JourneyTime.parse("soon")) == nil && (try? JourneyTime.parse("25:00")) == nil, "invalid times")
            check(JourneyClock.duration(0.002) == "2 ms" && JourneyClock.duration(0.0005) == "0.5 ms" && JourneyClock.duration(31.4) == "31.4 s"
                  && JourneyClock.duration(125) == "2 m 05 s", "durations")
        },
        CheckCase(name: "journey bundled checkout order replays clean") {
            let library = Library(builtIn: try requiredResource("Examples"), dirs: [])
            guard let checkout = library.manifest("checkout"), let journey = checkout.journey("order-to-paid") else { check(false, "no checkout journey"); return }
            let playback = checkout.replay(journey)
            check(playback.issues.isEmpty, "issues: \(playback.issues.map(\.message))")
            check(playback.frames.count == 11, "steps: \(playback.frames.count)")
            let claim = playback.frames.first { $0.step.id == "claim" }
            check(claim?.path == ["orders"] && claim?.node == "relay" && claim?.op?.reference == "relay/poll-outbox", "deep-dive step")
            check(checkout.resolveJourneyHow("relay/relay-cycle")?.path == ["orders"], "how in a deep dive")
            let codes = playback.moves.map { "\($0.row?.table ?? ""):\($0.to)" }
            check(codes == ["orders:10", "payments:authorized", "payments:captured", "orders:20"], "status timeline: \(codes)")
        },
        CheckCase(name: "journey cli prints a timeline and drafts") {
            let cli = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
                .deletingLastPathComponent().appendingPathComponent("strata")
            let examples = try requiredResource("Examples").appendingPathComponent("checkout.yaml")
            let timeline = try journeyCLI(cli, ["journey", examples.path])
            check(timeline.status == 0, "journey failed: \(timeline.output)")
            check(timeline.output.contains("checkout › order-to-paid: An order from cart to paid"), "header: \(timeline.output.prefix(200))")
            check(timeline.output.contains(" 5  commit  10:24:03.148 +9 ms  orders → db  orders/insert-order"), "step line: \(timeline.output)")
            check(timeline.output.contains("SQL  INSERT INTO orders (id, user_id, status, total_cents, currency, idempotency_key) VALUES ('o_9k8', 'u_34', 10, 2149"), "filled first statement")
            check(timeline.output.contains("~ orders o_9k8: status 10 placed → 20 paid"), "row change")
            check(timeline.output.contains("status order-status on orders o_9k8.status: 10 placed → 20 paid (payment captured, by orders/capture-payment)"), "status move")
            check(timeline.output.contains("orders o_9k8.status (order-status): 10 placed → 20 paid"), "status timeline")
            let draft = try journeyCLI(cli, ["journey", "draft", examples.path, "--entity", "orders", "--id", "o_9k9"])
            check(draft.status == 0 && draft.output.contains("journeys:") && draft.output.contains("op: orders/insert-order")
                  && draft.output.contains("- insert: orders"), "draft: \(draft.output.prefix(600))")
            let unknown = try journeyCLI(cli, ["journey", examples.path, "--journey", "nope"])
            check(unknown.status == 1 && unknown.output.contains("unknown journey 'nope'; choose order-to-paid"), "unknown: \(unknown.output)")
            let help = try journeyCLI(cli, ["--help"])
            check(help.output.contains("journey draft <file|id> --entity <table>"), "help lists journey draft")
        },
    ]
}

private func journeyCLI(_ executable: URL, _ args: [String]) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = executable
    process.arguments = args
    var environment = ProcessInfo.processInfo.environment
    environment["STRATA_HOME"] = FileManager.default.temporaryDirectory.appendingPathComponent("strata-journey-checks").path
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}
