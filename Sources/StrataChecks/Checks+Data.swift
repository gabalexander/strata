import Foundation
import StrataCore

// Schemas, sample rows, entities, traffic and SLOs (docs/manifest.md, Data, and Traffic, SLOs and pressure).

private let dataSource = ManifestSource.file(URL(fileURLWithPath: "/checks/data.yaml"))
private let dataHeader = "strata: 1\nid: data\ntitle: Data check\n"

private let defaultSchema = """
    - table: users
      columns: [{name: id, type: text, pk: true}, {name: email, type: text, unique: true}]
      rows: [[u1, a@example.com], [u2, b@example.com]]
    - table: products
      columns: [{name: sku, type: text, pk: true}, {name: title, type: text}]
      rows: [[A-1, Mug], [B-7, Lamp]]
    - table: orders
      columns: [{name: id, type: text, pk: true}, {name: user_id, type: text, ref: users.id}, {name: status, type: text}]
      rows: [[o1, u1, paid], [o2, u1, pending], [o3, u2, paid]]
    - table: order_items
      columns: [{name: order_id, ref: orders.id, pk: true}, {name: sku, ref: products.sku, pk: true}, {name: qty, type: int}]
      rows: [[o1, A-1, 2], [o1, B-7, 1], [o3, A-1, 5]]
    """

private let defaultOps = """
    - {id: read, kind: sql, label: Read, target: db, access: read, tables: [orders]}
    - {id: write, kind: sql, label: Write, target: db, access: write, tables: [orders, order_items]}
    """

/// A level with a database `db` (users, products, orders, order_items), a second database `archive`
/// whose `events` refer to `db.users.id`, a cache, and a service `api` with sql ops on `db`. Another
/// schema replaces the tables, and the ops and refs that name them.
private func dataLevel(schema: String = defaultSchema, ops: String? = nil,
                       archive: String? = nil,
                       entities: String = "", flows: String = "") -> String {
    func indent(_ text: String) -> String {
        text.components(separatedBy: "\n").map { "      " + $0 }.joined(separator: "\n")
    }
    // The default ops name the default tables; another schema gets an op that names none.
    let standard = schema == defaultSchema
    let ops = ops ?? (standard ? defaultOps : "- {id: serve, kind: http, label: Serve}")
    let archive = archive ?? (standard ? "[{table: events, columns: [{name: id, pk: true}, {name: user_id, ref: db.users.id}], rows: [[e1, u1], [e2, u2]]}]"
                                       : "[{table: events, columns: [{name: id, pk: true}], rows: [[e1]]}]")
    var text = """
        nodes:
          - {id: web, kind: client}
          - id: db
            kind: postgres
            schema:
        \(indent(schema))
          - {id: archive, kind: database, schema: \(archive)}
          - {id: cache, kind: cache}
          - id: api
            kind: service
            ops:
        \(indent(ops))

        """
    if !entities.isEmpty { text += "    entities:\n" + indent(entities) + "\n" }
    text += "edges: [{from: web, to: api}, {from: api, to: db}, {from: api, to: cache}, {from: api, to: archive}]\n"
    return text + flows
}

private func parseData(_ body: String) -> (Manifest?, [Diagnostic]) {
    ManifestParser.parse(dataHeader + body, source: dataSource)
}

private func cleanData(_ body: String) -> Manifest? {
    let (manifest, diagnostics) = parseData(body)
    check(manifest != nil && diagnostics.isEmpty, "expected a clean manifest, got \(diagnostics)")
    return manifest
}

/// A diagnostic at `path` containing `message`; with `at`, on the first line of the text containing it.
@MainActor private func dataFinding(_ name: String, _ body: String, path: String?, _ message: String,
                                    severity: Diagnostic.Severity = .error, at marker: String? = nil) -> CheckCase {
    CheckCase(name: "data \(name)") {
        let text = dataHeader + body
        let (manifest, diagnostics) = ManifestParser.parse(text, source: dataSource)
        check((manifest == nil) == (severity == .error), "unexpected load result: \(diagnostics)")
        let line = marker.flatMap { marker in text.components(separatedBy: "\n").firstIndex { $0.contains(marker) }.map { $0 + 1 } }
        check(diagnostics.contains {
            $0.severity == severity && $0.path == path && $0.message.contains(message) && (line == nil || $0.line == line)
        }, "expected \(severity)\(line.map { " on line \($0)" } ?? "") at \(path ?? "<none>") containing '\(message)', got \(diagnostics)")
    }
}

/// The manifest built from the first reference fence containing `marker`, as the fence harness builds it.
private func specFence(containing marker: String) throws -> Manifest? {
    guard let fence = try referenceFences().first(where: { $0.contains(marker) }) else {
        check(false, "no reference fence contains '\(marker)'")
        return nil
    }
    let (manifest, diagnostics) = ManifestParser.parse(specManifest(fence), source: dataSource)
    check(manifest != nil && diagnostics.isEmpty, "reference fence with '\(marker)': \(diagnostics)")
    return manifest
}

@MainActor func dataChecks() -> [CheckCase] {
    specChecks() + decodeChecks() + validationChecks() + helperChecks() + exampleChecks()
}

// MARK: - The spec's examples

@MainActor private func specChecks() -> [CheckCase] {
    [
        CheckCase(name: "data spec example decodes tables, rows, volumes and an entity") {
            guard let manifest = try specFence(containing: "\n  schema:") else { return }
            let db = manifest.root.node("db")
            check(db?.schema.map(\.name) == ["users", "orders", "order_items"], "tables: \(db?.schema.map(\.name) ?? [])")
            let orders = manifest.root.table("db", "orders")
            check(orders?.doc == "One row per checkout." && orders?.indexes == ["orders_user_id_idx (user_id)"], "orders doc or indexes")
            check(orders?.columns.map(\.name) == ["id", "user_id", "status", "total_cents"], "orders columns")
            check(orders?.column("id")?.pk == true && orders?.column("user_id")?.ref == "users.id" &&
                  orders?.column("status")?.note == "pending | paid | shipped" && orders?.column("total_cents")?.type == "bigint",
                  "column fields")
            check(orders?.rows == [["o-9f1c", "u-42", "paid", "4200"], ["o-77ab", "u-42", "pending", "1999"]],
                  "a map row becomes a column-order array: \(orders?.rows ?? [])")
            check(orders?.volume?.rows == 12_000_000 && orders?.volume?.growthPerDay == 40_000, "volume")
            check(manifest.root.table("db", "users")?.column("email")?.unique == true, "unique")
            check(manifest.root.table("db", "order_items")?.primaryKey.isEmpty == true, "order_items has no pk")
            let order = manifest.root.node("orders")?.entities.first
            check(order?.name == "Order" && order?.source == "db" && order?.root == "orders" &&
                  order?.includes == ["order_items", "users"] && order?.code == ["services/orders/domain/order.go:14"] &&
                  order?.doc?.hasPrefix("The aggregate") == true, "entity fields")
        },
        CheckCase(name: "data spec example decodes traffic and an slo") {
            guard let manifest = try specFence(containing: "traffic:") else { return }
            let flow = manifest.root.flow("place-order")
            check(flow?.rate == .perSecond(20), "the simulated rate stays as written")
            check(flow?.traffic?.peak == 120 && flow?.traffic?.daily == 4_000_000, "traffic: \(String(describing: flow?.traffic))")
            check(flow?.slo?.p99 == 0.3 && flow?.slo?.errors == 0.001 && flow?.slo?.p50 == nil, "slo: \(String(describing: flow?.slo))")
        },
        CheckCase(name: "data spec example assembles the order with its items and user") {
            guard let manifest = try specFence(containing: "\n  schema:"),
                  let order = manifest.root.node("orders")?.entities.first else { return }
            guard let tree = manifest.root.assembleEntity(order, on: "orders") else { check(false, "no tree"); return }
            check(tree.table == "orders" && tree.row == 0 && tree.relation == .root && tree.values.first == "o-9f1c", "root row")
            check(tree.children.map(\.table) == ["order_items", "order_items", "users"], "children: \(tree.children.map(\.table))")
            check(tree.children.map(\.relation) == [.child, .child, .parent], "relations")
            let item = tree.children[0]
            check(item.column == "order_id" && item.aboveColumn == "id" && item.values == ["o-9f1c", "A-1", "2"] &&
                  item.id == "orders#0/order_items#0", "child join: \(item)")
            let user = tree.children[2]
            check(user.column == "id" && user.aboveColumn == "user_id" && user.values == ["u-42", "ada@example.com"], "parent join")
            let pending = manifest.root.assembleEntity(order, on: "orders", key: "o-77ab")
            check(pending?.row == 1 && pending?.children.map(\.table) == ["users"], "keyed root row without items")
            check(manifest.root.assembleEntity(order, on: "orders", key: "o-none") == nil, "unknown key")
            let capped = manifest.root.assembleEntity(order, on: "orders", maxRows: 1)
            check(capped?.children.map(\.table) == ["order_items", "users"] && capped?.omitted == ["order_items": 1], "fan-out cap")
            let shallow = manifest.root.assembleEntity(order, on: "orders", maxDepth: 0)
            check(shallow?.children.isEmpty == true && shallow?.truncated == true, "depth cap")
            let joins = manifest.root.entityJoins(order, on: "orders")
            check(joins.map(\.table) == ["order_items", "users"] && joins.map(\.relation) == [.child, .parent], "entity joins")
        },
    ]
}

// MARK: - Decoding

@MainActor private func decodeChecks() -> [CheckCase] {
    func volume(_ rows: String, _ growth: String) -> TableVolume? {
        let manifest = cleanData(dataLevel(schema: "- {table: t, columns: [{name: a}], volume: {rows: \(rows), growth: \(growth)}}"))
        return manifest?.root.table("db", "t")?.volume
    }
    func traffic(_ peak: String, _ daily: String) -> FlowTraffic? {
        cleanData(dataLevel(flows: "flows: [{id: f, from: web, rate: 1/s, traffic: {peak: \(peak), daily: \(daily)}}]"))?.root.flow("f")?.traffic
    }
    func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-6 * max(1, b) } ?? false }
    return [
        CheckCase(name: "data counts take k, M and B suffixes") {
            for (text, value) in [("500", 500.0), ("40k", 40_000), ("2.5K", 2_500), ("12M", 12_000_000), ("1.2B", 1_200_000_000), ("0", 0)] {
                check(near(volume(text, "1/day")?.rows, value), "\(text) should be \(value): \(String(describing: volume(text, "1/day")))")
            }
        },
        CheckCase(name: "data growth is normalised to per day") {
            for (text, value) in [("40k/day", 40_000.0), ("1.2M/day", 1_200_000), ("500/h", 12_000), ("10/min", 14_400),
                                  ("3/s", 259_200), ("70k/week", 10_000), ("3M/month", 100_000), ("365k/year", 1_000), ("2/d", 2)] {
                check(near(volume("1", text)?.growthPerDay, value), "\(text) should be \(value)/day")
            }
        },
        CheckCase(name: "data traffic peak is a rate and daily a count") {
            for (peak, value) in [("120/s", 120.0), ("7200/min", 120), ("12k/s", 12_000), ("432k/h", 120)] {
                check(near(traffic(peak, "5M")?.peak, value), "\(peak) should be \(value)/s")
            }
            check(near(traffic("50/s", "4M")?.daily, 4_000_000) && near(traffic("50/s", "4M/day")?.daily, 4_000_000), "daily")
            let slo = cleanData(dataLevel(flows: "flows: [{id: f, from: web, slo: {p50: 40ms, p99: 1.5s, errors: 0.1%}}]"))?.root.flow("f")?.slo
            check(slo?.p50 == 0.04 && slo?.p99 == 1.5 && near(slo?.errors, 0.001), "slo: \(String(describing: slo))")
        },
        CheckCase(name: "data rows map to column-order arrays with nil for NULL") {
            let manifest = cleanData(dataLevel(schema: """
                - table: t
                  columns: [{name: a}, {name: b}, {name: c}]
                  rows:
                    - [x, null, ~]
                    - {c: 3, a: 1}
                    - [y, { k: v, n: 2 }, [1, two]]
                    - { a: "quoted null", b: "null" }
                - table: one
                  columns: [{name: v}]
                  rows: [alpha, beta]
                """))
            let rows = manifest?.root.table("db", "t")?.rows
            check(rows?[0] == ["x", nil, nil], "null and ~ are NULL: \(String(describing: rows?[0]))")
            check(rows?[1] == ["1", nil, "3"], "a map row fills by name and leaves the rest NULL: \(String(describing: rows?[1]))")
            check(rows?[2] == ["y", #"{ "k": "v", "n": 2 }"#, #"[1, "two"]"#], "nested values become JSON: \(String(describing: rows?[2]))")
            check(rows?[3] == ["quoted null", "null", nil], "a quoted null is text")
            check(manifest?.root.table("db", "one")?.rows == [["alpha"], ["beta"]], "a one-column table takes scalar rows")
        },
        dataFinding("count suffix m", dataLevel(schema: "- {table: t, columns: [{name: a}], volume: {rows: 12m}}"),
                    path: "nodes.db.schema.t.volume.rows", "write millions as M"),
        dataFinding("count garbage", dataLevel(schema: "- {table: t, columns: [{name: a}], volume: {rows: lots}}"),
                    path: "nodes.db.schema.t.volume.rows", "expected a count such as 500, 40k, 12M or 1.2B"),
        dataFinding("growth needs a period", dataLevel(schema: "- {table: t, columns: [{name: a}], volume: {growth: 40k}}"),
                    path: "nodes.db.schema.t.volume.growth", "growth needs a period, such as 40k/day"),
        dataFinding("growth period suggestion", dataLevel(schema: "- {table: t, columns: [{name: a}], volume: {growth: 40k/days}}"),
                    path: "nodes.db.schema.t.volume.growth", "did you mean '/day'"),
        dataFinding("growth ambiguous m", dataLevel(schema: "- {table: t, columns: [{name: a}], volume: {growth: 4/m}}"),
                    path: "nodes.db.schema.t.volume.growth", "write /min for minutes or /month for months"),
        dataFinding("peak needs a period", dataLevel(flows: "flows: [{id: f, from: web, traffic: {peak: 120}}]"),
                    path: "flows.f.traffic.peak", "write 120/s, not 120"),
        dataFinding("daily is per day", dataLevel(flows: "flows: [{id: f, from: web, traffic: {daily: 5/s}}]"),
                    path: "flows.f.traffic.daily", "daily is a count per day"),
        dataFinding("slo duration unit", dataLevel(flows: "flows: [{id: f, from: web, slo: {p99: 300}}]"),
                    path: "flows.f.slo.p99", "a duration needs a unit"),
        dataFinding("slo errors probability", dataLevel(flows: "flows: [{id: f, from: web, slo: {errors: 5}}]"),
                    path: "flows.f.slo.errors", "expected a probability"),
        dataFinding("unknown table key", dataLevel(schema: "- {table: t, columns: [{name: a}], colums: []}"),
                    path: "nodes.db.schema.t.colums", "did you mean 'columns'", severity: .warning),
        dataFinding("unknown column key", dataLevel(schema: "- {table: t, columns: [{name: a, primary: true}]}"),
                    path: "nodes.db.schema.t.columns.a.primary", "unknown key 'primary'", severity: .warning),
        dataFinding("unknown entity key", dataLevel(entities: "- {name: Order, root: orders, include: [users]}"),
                    path: "nodes.api.entities.Order.include", "did you mean 'includes'", severity: .warning),
        dataFinding("unknown traffic key", dataLevel(flows: "flows: [{id: f, from: web, traffic: {peek: 10/s}}]"),
                    path: "flows.f.traffic.peek", "did you mean 'peak'", severity: .warning),
        dataFinding("unknown slo key", dataLevel(flows: "flows: [{id: f, from: web, slo: {p90: 10ms}}]"),
                    path: "flows.f.slo.p90", "did you mean", severity: .warning),
        dataFinding("unknown column in a map row", dataLevel(schema: "- {table: t, columns: [{name: status}], rows: [{statsu: paid}]}"),
                    path: "nodes.db.schema.t.rows[0].statsu", "unknown column 'statsu' in 't'; did you mean 'status'", severity: .warning),
        dataFinding("table name with a dot", dataLevel(schema: "- {table: billing.invoices, columns: [{name: a}]}"),
                    path: "nodes.db.schema[0].table", "cannot be empty or contain spaces, dots or brackets"),
        dataFinding("ref syntax", dataLevel(schema: "- {table: t, columns: [{name: a, ref: users}]}"),
                    path: "nodes.db.schema.t.columns.a.ref", "use table.column, or node.table.column"),
        dataFinding("scalar row in a wide table", dataLevel(schema: "- {table: t, columns: [{name: a}, {name: b}], rows: [x]}"),
                    path: "nodes.db.schema.t.rows[0]", "expected a row: a list of values in column order, or a map"),
    ]
}

// MARK: - Validation

@MainActor private func validationChecks() -> [CheckCase] {
    let orders = "nodes.db.schema.orders"
    let entity = "nodes.api.entities.Order"
    return [
        dataFinding("duplicate table", dataLevel(schema: defaultSchema + "\n- {table: orders, columns: [{name: id}]}"),
                    path: "\(orders).table", "duplicate table 'orders'", at: "- {table: orders, columns: [{name: id}]}"),
        dataFinding("duplicate column", dataLevel(schema: "- {table: t, columns: [{name: id}, {name: id}]}"),
                    path: "nodes.db.schema.t.columns.id.name", "duplicate column 'id' in 't'"),
        CheckCase(name: "data composite primary keys and cross-node refs are allowed") {
            let manifest = cleanData(dataLevel())
            check(manifest?.root.table("db", "order_items")?.primaryKey.map(\.name) == ["order_id", "sku"], "composite key")
            check(manifest?.root.resolveRef("db.users.id", from: "archive") == ColumnRef(node: "db", table: "users", column: "id"),
                  "cross-node ref")
        },
        dataFinding("ref unknown table", dataLevel(schema: "- {table: users, columns: [{name: id}]}\n- {table: t, columns: [{name: a, ref: user.id}]}"),
                    path: "nodes.db.schema.t.columns.a.ref", "unknown table 'user' in 'db'; did you mean 'users'", at: "ref: user.id"),
        dataFinding("ref unknown column", dataLevel(schema: "- {table: users, columns: [{name: id}]}\n- {table: t, columns: [{name: a, ref: users.idd}]}"),
                    path: "nodes.db.schema.t.columns.a.ref", "unknown column 'idd' in 'users'; did you mean 'id'"),
        dataFinding("ref unknown node", dataLevel(archive: "[{table: e, columns: [{name: u, ref: dbb.users.id}]}]"),
                    path: "nodes.archive.schema.e.columns.u.ref", "unknown node 'dbb' in ref 'dbb.users.id'; did you mean 'db'"),
        dataFinding("ref names a node without its table", dataLevel(archive: "[{table: e, columns: [{name: u, ref: db.users}]}]"),
                    path: "nodes.archive.schema.e.columns.u.ref", "to refer to node 'db', write db.users.<column>"),
        dataFinding("ref to a node without a schema", dataLevel(archive: "[{table: e, columns: [{name: u, ref: cache.keys.id}]}]"),
                    path: "nodes.archive.schema.e.columns.u.ref", "unknown table 'keys' in 'cache'; 'cache' has no schema"),
        dataFinding("row width", dataLevel(schema: "- table: t\n  columns: [{name: a}, {name: b}]\n  rows:\n    - [x, y, z]"),
                    path: "nodes.db.schema.t.rows[0]", "row has 3 values but 't' has 2 columns", at: "- [x, y, z]"),
        dataFinding("row width with no columns", dataLevel(schema: "- {table: t, rows: [[x, y]]}"),
                    path: "nodes.db.schema.t.rows[0]", "row has 2 values but 't' has 0 columns"),
        dataFinding("duplicate primary key in sample rows", dataLevel(schema: "- {table: t, columns: [{name: a, pk: true}, {name: b, pk: true}], rows: [[x, 1], [x, 2], [x, 1]]}"),
                    path: "nodes.db.schema.t.rows[2]", "duplicate primary key (x, 1) in 't'; sample row 1 has it too", severity: .warning),
        dataFinding("schema on a service",
                    dataLevel().replacingOccurrences(of: "    ops:\n", with: "    schema: [{table: x, columns: [{name: a}]}]\n    ops:\n"),
                    path: "nodes.api.schema", "schema describes the tables of a database, store or search node; 'api' is a service", severity: .warning),
        dataFinding("unknown owner", dataLevel(schema: "- {table: t, columns: [{name: a}], owner: apii}"),
                    path: "nodes.db.schema.t.owner", "unknown node 'apii'; did you mean 'api'"),
        // Entities.
        CheckCase(name: "data entity source defaults to the one database the node has ops on") {
            let manifest = cleanData(dataLevel(entities: "- {name: Order, root: orders, includes: [order_items, users, products]}"))
            check(manifest?.root.node("api")?.entities.first?.source == "db", "the default source is filled in")
            let narrowed = cleanData(dataLevel(
                ops: defaultOps + "\n- {id: log, kind: sql, label: Log, target: archive, access: write, tables: [events]}",
                entities: "- {name: Event, root: events}"))
            check(narrowed?.root.node("api")?.entities.first?.source == "archive", "the root table narrows several candidates")
        },
        dataFinding("entity source unknown", dataLevel(entities: "- {name: Order, source: dbb, root: orders}"),
                    path: "\(entity).source", "unknown node 'dbb'; did you mean 'db'"),
        dataFinding("entity source is a cache", dataLevel(entities: "- {name: Order, source: cache, root: orders}"),
                    path: "\(entity).source", "an entity's source is a database, store or search node; 'cache' is a cache"),
        dataFinding("entity source without ops", dataLevel(ops: "- {id: s, kind: http, label: S}", entities: "- {name: Order, root: orders}"),
                    path: entity, "set source to the node this entity is loaded from; 'api' has no ops on a database, store or search node"),
        dataFinding("entity source with several candidates",
                    dataLevel(ops: defaultOps + "\n- {id: log, kind: sql, label: Log, target: archive, access: write, tables: [events]}",
                              archive: "[{table: orders, columns: [{name: id}]}]", entities: "- {name: Order, root: orders}"),
                    path: entity, "'api' has ops on 'db', 'archive'"),
        dataFinding("entity source without a schema",
                    dataLevel(archive: "[]", entities: "- {name: Event, source: archive, root: events}")
                        .replacingOccurrences(of: ", schema: []", with: ""),
                    path: "nodes.api.entities.Event.source", "'archive' has no schema"),
        dataFinding("entity root unknown", dataLevel(entities: "- {name: Order, root: order}"),
                    path: "\(entity).root", "unknown table 'order' in 'db'; did you mean 'orders'"),
        dataFinding("entity include unknown", dataLevel(entities: "- {name: Order, root: orders, includes: [order_item]}"),
                    path: "\(entity).includes[0]", "unknown table 'order_item' in 'db'; did you mean 'order_items'"),
        dataFinding("entity include unreachable", dataLevel(entities: "- {name: Order, root: orders, includes: [products]}"),
                    path: "\(entity).includes[0]", "'products' does not join 'orders' through ref columns; add a ref, or include the table that links them"),
        CheckCase(name: "data entity includes join through other includes in either direction") {
            let manifest = cleanData(dataLevel(entities: """
                - {name: Order, root: orders, includes: [products, order_items, users]}
                - {name: Customer, root: users, includes: orders}
                - {name: Product, root: products, includes: [order_items, orders, users]}
                """))
            guard let level = manifest?.root, let entities = level.node("api")?.entities, entities.count == 3 else { return }
            let joins = level.entityJoins(entities[0], on: "api")
            check(joins.map(\.table) == ["order_items", "users", "products"] && joins.map(\.above) == ["orders", "orders", "order_items"] &&
                  joins.map(\.relation) == [.child, .parent, .parent], "order joins: \(joins)")
            check(entities[1].includes == ["orders"], "includes as one string")
            let tree = level.assembleEntity(entities[0], on: "api")
            check(tree?.children.map(\.table) == ["order_items", "order_items", "users"], "order children")
            check(tree?.children.first?.children.map(\.table) == ["products"] && tree?.children.first?.children.first?.values == ["A-1", "Mug"],
                  "a product hangs from its item")
            let product = level.assembleEntity(entities[2], on: "api", key: "A-1")
            check(product?.children.map { $0.values.first ?? nil } == ["o1", "o3"] && product?.children.first?.children.first?.table == "orders" &&
                  product?.children.first?.children.first?.children.first?.table == "users", "product to items to orders to users")
            check(level.assembleEntity(entities[2], on: "api", key: "A-1", maxDepth: 2)?.children.first?.children.first?.truncated == true,
                  "depth cap marks the cut")
        },
        dataFinding("entity root listed in includes", dataLevel(entities: "- {name: Order, root: orders, includes: [orders, users]}"),
                    path: "\(entity).includes[0]", "'orders' is the root table", severity: .warning),
        dataFinding("entity include listed twice", dataLevel(entities: "- {name: Order, root: orders, includes: [users, users]}"),
                    path: "\(entity).includes[1]", "'users' is listed twice", severity: .warning),
        dataFinding("duplicate entity", dataLevel(entities: "- {name: Order, root: orders}\n- {name: Order, root: users}"),
                    path: "\(entity).name", "duplicate entity 'Order'"),
        // Op tables.
        dataFinding("op table missing from the schema", dataLevel(ops: "- {id: w, kind: sql, label: W, target: db, tables: [orders, ordr_items]}"),
                    path: "nodes.api.ops.w.tables[1]", "'db' has no table 'ordr_items' in its schema; did you mean 'order_items'", severity: .warning),
        dataFinding("op table as one string", dataLevel(ops: "- {id: w, kind: sql, label: W, target: db, tables: userz}"),
                    path: "nodes.api.ops.w.tables", "did you mean 'users'", severity: .warning),
        CheckCase(name: "data op tables are not checked against a target without a schema") {
            let text = dataLevel(ops: "- {id: w, kind: sql, label: W, target: archive, tables: [anything]}", archive: "[]")
                .replacingOccurrences(of: ", schema: []", with: "")
            check(cleanData(text) != nil, "a target without a schema was checked")
        },
        // Traffic and SLOs.
        CheckCase(name: "data a peak below the simulated rate is fine") {
            check(cleanData(dataLevel(flows: "flows: [{id: f, from: web, rate: 50/s, traffic: {peak: 10/s, daily: 400k}}]")) != nil, "warned")
        },
        dataFinding("traffic daily below a minute of peak", dataLevel(flows: "flows: [{id: f, from: web, traffic: {peak: 120/s, daily: 7k}}]"),
                    path: "flows.f.traffic.daily", "daily 7k against peak 120/s is less than one minute of peak traffic", severity: .warning),
        dataFinding("traffic daily above a day of peak", dataLevel(flows: "flows: [{id: f, from: web, traffic: {peak: 10/s, daily: 1M}}]"),
                    path: "flows.f.traffic.daily", "is more than a whole day at the peak rate", severity: .warning),
        dataFinding("slo p50 above p99", dataLevel(flows: "flows: [{id: f, from: web, slo: {p50: 500ms, p99: 200ms}}]"),
                    path: "flows.f.slo.p50", "p50 500ms is above p99 200ms", severity: .warning),
        dataFinding("slo p99 beyond the deadline", dataLevel(flows: "flows: [{id: f, from: web, deadline: 1s, slo: {p99: 2s}}]"),
                    path: "flows.f.slo.p99", "p99 2s is longer than the flow's deadline 1s", severity: .warning),
    ]
}

// MARK: - Shared helpers

@MainActor private func helperChecks() -> [CheckCase] {
    [
        CheckCase(name: "data joins, touched tables and owners") {
            let (manifest, diagnostics) = parseData(dataLevel(
                ops: defaultOps + "\n- {id: log, kind: sql, label: Log, target: archive, access: read-write, tables: [events, nope]}"))
            check(diagnostics.count == 1 && diagnostics.first?.message.contains("no table 'nope'") == true, "fixture: \(diagnostics)")
            guard let level = manifest?.root else { return }
            let joins = level.joins(of: TableRef(node: "db", table: "orders"))
            check(joins.map(\.direction) == [.outgoing, .incoming], "join directions: \(joins)")
            check(joins.first?.column == "user_id" && joins.first?.other == ColumnRef(node: "db", table: "users", column: "id"), "outgoing pair")
            check(joins.last?.column == "id" && joins.last?.other == ColumnRef(node: "db", table: "order_items", column: "order_id"), "incoming pair")
            let users = level.joins(of: TableRef(node: "db", table: "users"))
            check(users.map(\.other.description) == ["db.orders.user_id", "archive.events.user_id"], "incoming across nodes: \(users)")
            guard let log = level.node("api")?.ops.first(where: { $0.id == "log" }) else { return }
            let touched = level.tables(touchedBy: log, on: "api")
            check(touched.map(\.name) == ["events", "nope"] && touched.map(\.node) == ["archive", "archive"] &&
                  touched.first?.schema?.name == "events" && touched.last?.schema == nil, "touched tables")
            check(level.writers(of: TableRef(node: "db", table: "order_items")).map(\.op.id) == ["write"], "writers")
            check(level.owners(of: TableRef(node: "db", table: "orders")) == ["api"], "inferred owner")
            check(level.owners(of: TableRef(node: "db", table: "users")).isEmpty, "nobody writes users")
            check(level.owners(of: TableRef(node: "archive", table: "events")) == ["api"], "read-write counts as a writer")
            let declared = cleanData(dataLevel(schema: "- {table: t, columns: [{name: a}], owner: web}", ops: "- {id: w, kind: sql, label: W, target: db, access: write, tables: [t]}"))
            check(declared?.root.owners(of: TableRef(node: "db", table: "t")) == ["web"], "a declared owner wins")
        },
        CheckCase(name: "data join highlighting follows refs to the key and back") {
            guard let level = cleanData(dataLevel())?.root else { return }
            func rows(_ table: String, _ column: String, _ value: String, on node: String = "db") -> [String] {
                level.joinedRows(ColumnRef(node: node, table: table, column: column), value: value).map { "\($0.node).\($0.table)#\($0.row).\($0.column)" }
            }
            let user = ["db.users#0.id", "db.orders#0.user_id", "db.orders#1.user_id", "archive.events#0.user_id"]
            check(rows("orders", "user_id", "u1") == user, "from a ref: \(rows("orders", "user_id", "u1"))")
            check(rows("users", "id", "u1") == user, "from the key")
            check(rows("events", "user_id", "u1", on: "archive") == user, "from another node")
            check(rows("orders", "id", "o1") == ["db.orders#0.id", "db.order_items#0.order_id", "db.order_items#1.order_id"], "children")
            check(rows("order_items", "sku", "A-1") == ["db.products#0.sku", "db.order_items#0.sku", "db.order_items#2.sku"], "a composite key column")
            check(rows("orders", "status", "paid").isEmpty, "a column that joins nothing")
            check(rows("users", "id", "u9").isEmpty, "a value no row has")
        },
        CheckCase(name: "data row keys and count text") {
            guard let level = cleanData(dataLevel())?.root else { return }
            check(level.table("db", "order_items")?.rowIndex(key: "o3,A-1") == 2, "composite key lookup")
            check(level.table("db", "orders")?.rowIndex(key: "o2") == 1, "single key lookup")
            check(level.table("db", "orders")?.value(row: 9, column: 0) == nil, "out of range value")
            let texts = [4_000_000, 1_250, 950, 999_999, 1_200_000_000, 0.5].map(DataFormat.count)
            check(texts == ["4M", "1.3k", "950", "1M", "1.2B", "0.5"], "count text: \(texts)")
            check(DataFormat.rate(120) == "120/s" && DataFormat.rate(0.5) == "30/min", "rate text")
        },
    ]
}

// MARK: - Bundled examples

@MainActor private func exampleChecks() -> [CheckCase] {
    [
        CheckCase(name: "data bundled examples resolve refs and assemble every entity") {
            let library = Library(builtIn: try requiredResource("Examples"), dirs: [])
            var schemas = 0
            func walk(_ level: Level, in id: String) {
                for node in level.nodes {
                    for table in node.schema {
                        schemas += 1
                        check(!table.rows.isEmpty && table.volume?.rows != nil, "\(id) \(node.id).\(table.name) needs sample rows and a volume")
                        for column in table.columns {
                            if let ref = column.ref {
                                check(level.resolveRef(ref, from: node.id) != nil, "\(id) \(node.id).\(table.name).\(column.name) ref \(ref)")
                            }
                        }
                        for join in level.joins(of: TableRef(node: node.id, table: table.name)) where join.direction == .outgoing {
                            guard let target = level.table(join.other.tableRef), let index = table.columnIndex(join.column),
                                  let targetIndex = target.columnIndex(join.other.column) else { continue }
                            let keys = Set(target.rows.indices.compactMap { target.value(row: $0, column: targetIndex) })
                            for row in table.rows.indices {
                                if let value = table.value(row: row, column: index) {
                                    check(keys.contains(value), "\(id) \(table.name).\(join.column) '\(value)' joins no \(join.other)")
                                }
                            }
                        }
                    }
                    for entity in node.entities {
                        let tree = level.assembleEntity(entity, on: node.id)
                        check(tree != nil && level.entityJoins(entity, on: node.id).count == entity.includes.count,
                              "\(id) entity \(entity.name) on \(node.id) does not assemble")
                    }
                    if let inside = node.inside { walk(inside, in: id) }
                }
            }
            for entry in library.entries { if let manifest = entry.manifest { walk(manifest.root, in: entry.id) } }
            check(schemas >= 8, "expected schemas in the bundled examples, found \(schemas) tables")
            let checkout = library.manifest("checkout")
            check(checkout?.root.node("db")?.schema.map(\.name) == ["users", "prices", "orders", "order_items", "payments", "outbox"],
                  "checkout tables: \(checkout?.root.node("db")?.schema.map(\.name) ?? [])")
            check(checkout?.root.node("orders")?.entities.map(\.name) == ["Order", "Price"], "checkout entities on orders-svc")
            let order = checkout?.root.node("orders")?.entities.first
            let tree = order.flatMap { checkout?.root.assembleEntity($0, on: "orders") }
            check(Set(tree?.children.map(\.table) ?? []) == ["order_items", "payments", "users"], "the order assembles items, payment and user")
            let place = checkout?.root.flow("place-order")
            check(place?.traffic?.peak != nil && place?.traffic?.daily != nil && place?.slo?.p99 != nil, "place-order traffic and slo")
        },
    ]
}
