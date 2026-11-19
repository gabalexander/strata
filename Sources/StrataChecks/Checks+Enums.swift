import Foundation
import StrataCore

// Enums: decoding, validation, value lookups, lifecycle order, occurrence detection in SQL and JSON,
// search, usage, and `strata enums` (docs/manifest.md, Enums).

private let enumSource = ManifestSource.file(URL(fileURLWithPath: "/checks/enums.yaml"))

/// The manifest around the reference's Enums fence: the nodes its `by` names and a table that links
/// a column to the enum.
func enumSpecManifest(_ fence: String) -> String {
    """
    strata: 1
    id: campaigns-spec
    title: Enums spec
    nodes:
      - {id: web, kind: client}
      - id: campaigns
        kind: service
        ops:
          - {id: schedule, kind: sql, label: Schedule campaign, target: db, access: write, tables: [campaigns],
             query: "UPDATE campaigns SET status = 3200 WHERE id = $1 AND status = 3100"}
      - {id: scheduler, kind: worker}
      - id: db
        kind: database
        schema:
          - table: campaigns
            columns: [{name: id, pk: true}, {name: status, type: int, enum: campaign-status}]
            rows: [[c1, 3100], [c2, 3300]]
    edges: [{from: web, to: campaigns}, {from: campaigns, to: db}, {from: scheduler, to: db}]

    """ + fence
}

private func enumLoad(_ text: String) -> (Manifest?, [Diagnostic]) {
    ManifestParser.parse(text, source: enumSource)
}

/// A manifest with one enum, a table that holds it, and whatever the case adds.
private func enumCase(enums: String, column: String = "{name: status, type: int, enum: campaign-status}",
                      rows: String = "[[c1, 3100], [c2, 3200]]", extra: String = "") -> String {
    """
    strata: 1
    id: enums
    title: Enum check
    enums:
    \(enums)
    nodes:
      - {id: web, kind: client}
      - id: campaigns
        kind: service
        ops: [{id: schedule, kind: sql, label: Schedule, target: db, access: write, tables: [campaigns],
               query: "UPDATE campaigns SET status = 3200 WHERE id = $1 AND status = 3100"}]
      - id: db
        kind: database
        schema:
          - table: campaigns
            columns: [{name: id, pk: true}, \(column)]
            rows: \(rows)
    edges: [{from: web, to: campaigns}, {from: campaigns, to: db}]
    \(extra)
    """
}

private let campaignEnum = """
      - id: campaign-status
        label: Campaign status
        values:
          - {value: 3100, name: draft}
          - {value: 3200, name: scheduled, doc: Waiting for start_at.}
          - {value: 3300, name: running}
          - {value: 3400, name: paused}
          - {value: 3900, name: finished, terminal: true}
        transitions:
          - {from: 3100, to: 3200, label: schedule, by: campaigns/schedule}
          - {from: 3200, to: 3300, label: start_at reached, by: campaigns}
          - {from: 3300, to: 3400, label: pause}
          - {from: 3400, to: 3300, label: resume}
          - {from: 3300, to: 3900, label: budget spent}
    """

@MainActor private func enumFinding(_ name: String, enums: String, column: String? = nil, rows: String? = nil,
                                    severity: Diagnostic.Severity, path: String?, _ message: String) -> CheckCase {
    CheckCase(name: "enums \(name)") {
        var text = enumCase(enums: enums)
        if let column { text = enumCase(enums: enums, column: column, rows: rows ?? "[[c1, 3100], [c2, 3200]]") }
        else if let rows { text = enumCase(enums: enums, rows: rows) }
        let (manifest, diagnostics) = enumLoad(text)
        check((manifest == nil) == (severity == .error), "unexpected load result: \(diagnostics)")
        check(diagnostics.contains { $0.severity == severity && $0.path == path && $0.message.contains(message) },
              "expected \(severity) at \(path ?? "-") containing '\(message)', got \(diagnostics)")
    }
}

@MainActor func enumChecks() -> [CheckCase] {
    enumModelChecks() + enumValidationChecks() + enumOccurrenceChecks() + enumCLIChecks()
}

@MainActor private func enumModelChecks() -> [CheckCase] {
    [
        CheckCase(name: "enums reference fence decodes clean with its state machine") {
            guard let fence = try referenceFences().first(where: { $0.hasPrefix("enums:") }) else {
                check(false, "no enums fence in the manifest reference")
                return
            }
            let (manifest, diagnostics) = enumLoad(enumSpecManifest(fence))
            check(manifest != nil && diagnostics.isEmpty, "spec enums: \(diagnostics)")
            guard let def = manifest?.enumDef("campaign-status") else { check(false, "campaign-status missing"); return }
            check(def.label == "Campaign status" && def.code == ["internal/campaign/status.go:8"] && def.values.count == 5, "enum fields")
            check(def.value("3200")?.name == "scheduled" && def.value("3200")?.doc == "Waiting for start_at.", "value lookup")
            check(def.value("3900")?.terminal == true && def.value("3100")?.terminal == false, "terminal")
            check(def.transitions.count == 5 && def.transitions[0].by == "campaigns/schedule" && def.transitions[1].label == "start_at reached",
                  "transitions: \(def.transitions)")
            check(manifest?.enumValue("campaign-status", "scheduled")?.value == "3200", "lookup by name")
            check(manifest?.root.table("db", "campaigns")?.column("status")?.enumRef == "campaign-status", "column enum")
            check(manifest?.resolveActor("campaigns/schedule") == EnumActor(path: [], node: "campaigns", op: "schedule") &&
                  manifest?.resolveActor("scheduler") == EnumActor(path: [], node: "scheduler", op: nil), "by resolves")
            check(def.transitions(from: "3300").map(\.to) == ["3400", "3900"] && def.transitions(to: "3300").map(\.from) == ["3200", "3400"],
                  "transitions from and to")
        },
        CheckCase(name: "enums values are kept as written, numbers and strings alike") {
            let (manifest, diagnostics) = enumLoad(enumCase(enums: """
                  - id: campaign-status
                    values: [{value: 3100, name: draft}, {value: "3200", name: scheduled}, {value: on-hold, name: "on hold"}]
                    transitions: [{from: "3100", to: 3200}, {from: 3200, to: on-hold}]
                """, rows: "[[c1, 3100], [c2, \"3200\"], [c3, on-hold]]"))
            check(manifest != nil && diagnostics.isEmpty, "mixed values: \(diagnostics)")
            let def = manifest?.enumDef("campaign-status")
            check(def?.values.map(\.value) == ["3100", "3200", "on-hold"] && def?.label == "campaign-status", "values and default label")
            check(def?.resolve("on hold")?.value == "on-hold" && def?.title(of: "3200") == "3200 scheduled" && def?.title(of: "77") == "77",
                  "resolve and titles")
        },
        CheckCase(name: "enums lifecycle order is topological and handles cycles") {
            let (manifest, _) = enumLoad(enumCase(enums: campaignEnum))
            guard let def = manifest?.enumDef("campaign-status") else { check(false, "enum missing"); return }
            let life = def.lifecycle()
            check(life.order == ["3100", "3200", "3300", "3400", "3900"], "order: \(life.order)")
            check(life.layer == ["3100": 0, "3200": 1, "3300": 2, "3400": 3, "3900": 3], "layers: \(life.layer)")
            check(life.row["3400"] == 0 && life.row["3900"] == 1, "rows: \(life.row)")
            check(life.back == [3], "resume is the back edge: \(life.back)")

            // A pure cycle starts at the first value; isolated values come last in the first column.
            var ring = EnumDef(id: "ring")
            ring.values = ["a", "b", "c", "lone"].map { EnumValue(value: $0, name: $0) }
            ring.transitions = [EnumTransition(from: "b", to: "c"), EnumTransition(from: "c", to: "a"), EnumTransition(from: "a", to: "b"),
                                EnumTransition(from: "a", to: "a")]
            let cycle = ring.lifecycle()
            check(cycle.order == ["a", "lone", "b", "c"] && cycle.layer["c"] == 2 && cycle.layer["lone"] == 0, "cycle: \(cycle)")
            check(cycle.back == [1, 3], "back edges of a ring and a self loop: \(cycle.back)")
        },
        CheckCase(name: "enums columns per level and usage") {
            let (manifest, diagnostics) = enumLoad(enumCase(enums: campaignEnum).replacingOccurrences(
                of: """
                ops: [{id: schedule, kind: sql, label: Schedule, target: db, access: write, tables: [campaigns],
                           query: "UPDATE campaigns SET status = 3200 WHERE id = $1 AND status = 3100"}]
                """,
                with: """
                ops:
                      - {id: schedule, kind: sql, label: Schedule, target: db, access: write, tables: [campaigns],
                         query: "UPDATE campaigns SET status = 3200 WHERE id = $1 AND status = 3100"}
                      - {id: events, kind: publish, direction: out, label: Event, payload: '{ "id": "c1", "status": 3300 }'}
                    inside:
                      nodes:
                        - id: cache
                          kind: database
                          schema: [{table: snapshots, columns: [{name: state, enum: campaign-status}], rows: [[3100]]}]
                """))
            check(manifest != nil && diagnostics.isEmpty, "nested level: \(diagnostics)")
            guard let manifest else { return }
            check(manifest.root.enumColumns().map(\.description) == ["db.campaigns.status"], "root columns")
            check(manifest.enumColumns().map { "\($0.path.joined(separator: "/")):\($0.column)" } ==
                  [":db.campaigns.status", "campaigns:cache.snapshots.state"], "every level: \(manifest.enumColumns())")
            check(manifest.enumOf(node: "cache", table: "snapshots", column: "state", at: ["campaigns"])?.id == "campaign-status", "enumOf")
            let usage = manifest.enumUsage("campaign-status")
            check(usage.columns.count == 2 && usage.ops.map(\.op) == ["schedule", "events"] && usage.ops.last?.values == ["3300"],
                  "usage: \(usage.ops)")
        },
        CheckCase(name: "enums search by value, name and label") {
            let (manifest, _) = enumLoad(enumCase(enums: campaignEnum))
            guard let manifest else { check(false, "manifest"); return }
            check(manifest.searchEnums("3200").first == EnumSearchHit(enumID: "campaign-status", value: "3200", score: 100), "by code")
            check(manifest.searchEnums("scheduled").first?.value == "3200", "by name")
            check(manifest.searchEnums("sched").first?.value == "3200", "by prefix")
            let label = manifest.searchEnums("campaign status")
            check(label.first?.value == nil && label.first?.enumID == "campaign-status" && label.count == 1, "by label: \(label)")
            check(manifest.searchEnums("campaign running").first?.value == "3300", "label and name")
            check(manifest.searchEnums("nothing").isEmpty && manifest.searchEnums("  ").isEmpty, "no match")
        },
    ]
}

@MainActor private func enumValidationChecks() -> [CheckCase] {
    let two = """
          - {id: campaign-status, values: [{value: 1, name: a}]}
          - {id: campaign-status, values: [{value: 2, name: b}]}
        """
    return [
        enumFinding("duplicate ids", enums: two, rows: "[[c1, 1]]", severity: .error, path: "enums.campaign-status.id",
                    "duplicate enum 'campaign-status'"),
        enumFinding("duplicate values", enums: """
              - {id: campaign-status, values: [{value: 3100, name: draft}, {value: 3100, name: copy}]}
            """, rows: "[[c1, 3100]]", severity: .error, path: "enums.campaign-status.values[1].value", "duplicate value 3100"),
        enumFinding("duplicate names", enums: """
              - {id: campaign-status, values: [{value: 3100, name: draft}, {value: 3200, name: draft}]}
            """, severity: .warning, path: "enums.campaign-status.values[1].name", "duplicate name 'draft'"),
        enumFinding("empty values", enums: "  - {id: campaign-status, values: []}", rows: "[]", severity: .error,
                    path: "enums.campaign-status.values", "at least one value"),
        enumFinding("missing name", enums: "  - {id: campaign-status, values: [{value: 3100}]}", rows: "[]", severity: .error,
                    path: "enums.campaign-status.values[0].name", "required value is missing"),
        enumFinding("unknown transition value", enums: """
              - id: campaign-status
                values: [{value: 3100, name: draft}, {value: 3200, name: scheduled}]
                transitions: [{from: 3100, to: 3201}]
            """, severity: .error, path: "enums.campaign-status.transitions[0].to", "unknown value 3201 in 'campaign-status'; did you mean 3200?"),
        enumFinding("transition by name", enums: """
              - id: campaign-status
                values: [{value: 3100, name: draft}, {value: 3200, name: scheduled}]
                transitions: [{from: draft, to: 3200}]
            """, severity: .error, path: "enums.campaign-status.transitions[0].from", "'draft' is the name of 3100"),
        enumFinding("unknown by node", enums: """
              - id: campaign-status
                values: [{value: 3100, name: draft}, {value: 3200, name: scheduled}]
                transitions: [{from: 3100, to: 3200, by: campaign}]
            """, severity: .error, path: "enums.campaign-status.transitions[0].by", "unknown node 'campaign' in by 'campaign'; did you mean 'campaigns'?"),
        enumFinding("unknown by op", enums: """
              - id: campaign-status
                values: [{value: 3100, name: draft}, {value: 3200, name: scheduled}]
                transitions: [{from: 3100, to: 3200, by: campaigns/schedul}]
            """, severity: .error, path: "enums.campaign-status.transitions[0].by", "unknown op 'schedul' on 'campaigns' in by 'campaigns/schedul'; did you mean 'campaigns/schedule'?"),
        enumFinding("invalid by", enums: """
              - id: campaign-status
                values: [{value: 3100, name: draft}]
                transitions: [{from: 3100, to: 3100, by: "a/b/c"}]
            """, rows: "[[c1, 3100]]", severity: .error, path: "enums.campaign-status.transitions[0].by", "invalid op reference"),
        enumFinding("unknown column enum", enums: campaignEnum, column: "{name: status, enum: campaign-state}", severity: .error,
                    path: "nodes.db.schema.campaigns.columns.status.enum", "unknown enum 'campaign-state'; did you mean 'campaign-status'?"),
        enumFinding("unknown sample values", enums: campaignEnum, rows: "[[c1, 3100], [c2, 3150], [c3, 3150], [c4, scheduled], [c5, null]]",
                    severity: .warning, path: "nodes.db.schema.campaigns.rows[1]",
                    "campaigns.status holds '3150', 'scheduled', not values of 'campaign-status'"),
        enumFinding("terminal with a way out", enums: campaignEnum + "\n      - {from: 3900, to: 3100, label: reopen}", severity: .warning,
                    path: "enums.campaign-status.transitions[5].from", "3900 finished is terminal but has a transition to 3100 draft"),
        CheckCase(name: "enums by resolves on a deep-dive level") {
            let text = enumCase(enums: """
                  - id: campaign-status
                    values: [{value: 3100, name: draft}, {value: 3200, name: scheduled}]
                    transitions: [{from: 3100, to: 3200, by: planner/plan}]
                """).replacingOccurrences(of: "ops: [{id: schedule,", with: """
                inside: {nodes: [{id: planner, kind: worker, ops: [{id: plan, kind: call, label: Plan}]}]}
                    ops: [{id: schedule,
                """)
            let (manifest, diagnostics) = enumLoad(text)
            check(manifest != nil && diagnostics.isEmpty, "deep by: \(diagnostics)")
            check(manifest?.resolveActor("planner/plan") == EnumActor(path: ["campaigns"], node: "planner", op: "plan"), "actor path")
        },
        CheckCase(name: "enums unknown keys warn") {
            let (manifest, diagnostics) = enumLoad(enumCase(enums: """
                  - {id: campaign-status, values: [{value: 3100, name: draft, terminl: true}], colour: red}
                """, rows: "[[c1, 3100]]"))
            check(manifest != nil && diagnostics.map(\.message).sorted() == ["unknown key 'colour'", "unknown key 'terminl'; did you mean 'terminal'?"],
                  "unknown keys: \(diagnostics)")
        },
        CheckCase(name: "enums bundled checkout links its status columns") {
            let library = Library(builtIn: try requiredResource("Examples"), dirs: [])
            guard let checkout = library.manifest("checkout") else { check(false, "checkout missing"); return }
            check(checkout.enums.map(\.id) == ["order-status", "payment-status"], "checkout enums: \(checkout.enums.map(\.id))")
            check(checkout.root.table("db", "orders")?.column("status")?.enumRef == "order-status" &&
                  checkout.root.table("db", "payments")?.column("status")?.enumRef == "payment-status", "linked columns")
            let payment = checkout.enumDef("payment-status")
            check(payment?.transitions.allSatisfy { $0.by.flatMap(checkout.resolveActor)?.op != nil } == true, "payment transitions name their ops")
            check(checkout.enums.contains { $0.values.allSatisfy { Int($0.value) != nil } }, "an integer-coded enum")
        },
    ]
}

@MainActor private func enumOccurrenceChecks() -> [CheckCase] {
    let twoEnums = campaignEnum + """

          - id: payment-status
            values: [{value: authorized, name: authorized}, {value: captured, name: captured}, {value: refunded, name: refunded}]
        """
    let text = enumCase(enums: twoEnums).replacingOccurrences(of: "rows: [[c1, 3100], [c2, 3200]]", with: """
        rows: [[c1, 3100], [c2, 3200]]
              - table: payments
                columns: [{name: id, pk: true}, {name: campaign_id, ref: campaigns.id}, {name: status, enum: payment-status}]
                rows: [[p1, c1, authorized]]
              - table: users
                columns: [{name: id, pk: true}, {name: status}]
        """)
    func found(_ query: String, tables: [TableRef] = []) -> [String] {
        guard let manifest = enumLoad(text).0 else { return ["<no manifest>"] }
        return manifest.enumOccurrences(in: query, level: manifest.root, tables: tables).map { hit in
            "\(query[hit.range])=\(hit.enumID):\(hit.value ?? "?")"
        }
    }
    return [
        CheckCase(name: "enums occurrence fixture decodes") {
            let (manifest, diagnostics) = enumLoad(text)
            check(manifest != nil && diagnostics.isEmpty, "fixture: \(diagnostics)")
        },
        CheckCase(name: "enums occurrences in SQL comparisons and IN lists") {
            check(found("SELECT * FROM campaigns WHERE status = 3200") == ["3200=campaign-status:3200"], "equals")
            check(found("SELECT id FROM campaigns WHERE status IN (3100, 3200) AND id <> 'x'") ==
                  ["3100=campaign-status:3100", "3200=campaign-status:3200"], "in list")
            check(found("SELECT id FROM campaigns WHERE status NOT IN (3900)") == ["3900=campaign-status:3900"], "not in")
            check(found("UPDATE campaigns SET status = 3300 WHERE id = $1 AND status != 3200") ==
                  ["3300=campaign-status:3300", "3200=campaign-status:3200"], "update set and !=")
            check(found("SELECT * FROM campaigns WHERE status = $1 OR status = :status OR status = ?") == [], "parameters are not values")
            check(found("SELECT * FROM campaigns WHERE status = 3150") == ["3150=campaign-status:?"], "unknown value in a named table")
            check(found("-- status = 3100\nSELECT 1 FROM campaigns /* status = 3200 */ WHERE \"status\" = 3300") ==
                  ["3300=campaign-status:3300"], "comments skipped, quoted identifier")
            check(found("SELECT * FROM campaigns WHERE status = 3200abc") == [], "not a number")
        },
        CheckCase(name: "enums occurrences follow statement tables and aliases") {
            check(found("UPDATE payments SET status = 'captured' WHERE id = $1 AND status = 'authorized'; UPDATE campaigns SET status = 3300") ==
                  ["'captured'=payment-status:captured", "'authorized'=payment-status:authorized", "3300=campaign-status:3300"],
                  "two statements, two enums")
            check(found("SELECT c.id FROM campaigns c JOIN payments AS p ON p.campaign_id = c.id WHERE c.status = 3300 AND p.status = 'refunded'") ==
                  ["3300=campaign-status:3300", "'refunded'=payment-status:refunded"], "aliases")
            check(found("SELECT * FROM users WHERE status = 3200") == [], "a table whose status is not an enum")
            check(found("SELECT * FROM public.campaigns WHERE status = 3200") == ["3200=campaign-status:3200"], "schema-qualified table")
            check(found("SELECT * FROM users u WHERE u.status = 3200") == [], "qualified by another table")
        },
        CheckCase(name: "enums occurrences in INSERT values") {
            check(found("INSERT INTO campaigns (id, status) VALUES ($1, 3100), ('c9', 3200);") ==
                  ["3100=campaign-status:3100", "3200=campaign-status:3200"], "rows by position")
            check(found("INSERT INTO payments (id, campaign_id, status) VALUES ($1, lower($2), 'authorized')") ==
                  ["'authorized'=payment-status:authorized"], "nested parentheses")
            check(found("INSERT INTO campaigns (id, status) SELECT id, 3100 FROM drafts") == [], "insert from select")
        },
        CheckCase(name: "enums occurrences in JSON payloads") {
            check(found(#"{ "id": "c1", "status": 3200 }"#) == ["3200=campaign-status:3200"], "number value")
            check(found(#"{"status":"scheduled"}"#) == [#""scheduled"=campaign-status:3200"#], "a name resolves to its code")
            check(found(#"{ "status": 3300, "payment": { "status": "captured" }, "items": [{ "status": "refunded" }] }"#) ==
                  ["3300=campaign-status:3300", #""captured"=payment-status:captured"#, #""refunded"=payment-status:refunded"#],
                  "parent keys and values pick the enum")
            check(found(#"{ "status": "ok" }"#) == [], "a literal no enum knows, with no table named")
            check(found(#"{ "payment": { "status": "lost" } }"#) == [#""lost"=payment-status:?"#], "unknown value under a named table")
            check(found("status: 3900") == ["3900=campaign-status:3900"], "yaml-style key")
            check(found(#"{ "status": 3300 }"#, tables: [TableRef(node: "db", table: "payments")]) == ["3300=campaign-status:3300"],
                  "op tables prefer but never force an enum that doesn't know the value")
            check(found(#"{ "status": "authorized" }"#, tables: [TableRef(node: "db", table: "payments")]) ==
                  [#""authorized"=payment-status:authorized"#], "op tables")
        },
        CheckCase(name: "enums occurrences ranges cover the literal") {
            guard let manifest = enumLoad(text).0 else { check(false, "manifest"); return }
            let query = "UPDATE payments SET status = 'captured'"
            let hit = manifest.enumOccurrences(in: query).first
            check(hit.map { String(query[$0.range]) } == "'captured'" && hit?.literal == "captured" && hit?.key == "status" &&
                  hit?.table == "payments", "occurrence fields: \(String(describing: hit))")
        },
        CheckCase(name: "enums occurrences in the bundled checkout") {
            let library = Library(builtIn: try requiredResource("Examples"), dirs: [])
            guard let checkout = library.manifest("checkout"), let orders = checkout.root.node("orders") else { check(false, "checkout"); return }
            func codes(_ op: String, _ text: (StrataCore.Operation) -> String?) -> [String] {
                guard let operation = orders.ops.first(where: { $0.id == op }), let body = text(operation) else { return [] }
                return checkout.enumOccurrences(in: body, level: checkout.root, op: operation, on: "orders").map { "\($0.enumID):\($0.value ?? "?")" }
            }
            check(codes("capture-payment", \.query) == ["payment-status:captured", "payment-status:authorized", "order-status:20", "order-status:10"],
                  "capture-payment: \(codes("capture-payment", \.query))")
            check(codes("insert-order", \.query) == ["order-status:10", "payment-status:authorized"], "insert-order")
            check(codes("get-order", \.response) == ["order-status:20", "payment-status:captured"], "get-order response")
            check(codes("order-placed", \.payload) == ["order-status:10"], "OrderPlaced payload")
        },
    ]
}

@MainActor private func enumCLIChecks() -> [CheckCase] {
    [
        CheckCase(name: "enums cli prints values and transitions") {
            guard let checkout = StrataResources.url("Examples/checkout.yaml") else { check(false, "missing checkout"); return }
            let text = try enumCLI(["enums", checkout.path])
            let lines = text.output.components(separatedBy: "\n")
            check(text.status == 0 && lines.first == "checkout · 2 enums" && lines.contains("order-status · Order status · db.orders.status"),
                  "header: \(text.output)")
            check(lines.contains("    10 placed → 20 paid (payment captured, by orders/capture-payment)") &&
                  lines.contains("    20 paid → 30 shipped (warehouse ships it)") &&
                  lines.contains("    authorized → captured (provider captures, by orders/capture-payment)"), "transitions: \(text.output)")
            check(lines.contains { $0.hasPrefix("  30  shipped") && $0.contains("terminal") }, "terminal value: \(text.output)")

            let found = try enumCLI(["enums", checkout.path, "--find", "20"])
            check(found.status == 0 && found.output.contains("  20  paid") && !found.output.contains("  10  placed") &&
                  !found.output.contains("payment-status"), "--find by code: \(found.output)")
            let missing = try enumCLI(["enums", checkout.path, "--find", "zzz"])
            check(missing.status == 1 && missing.output.contains("No enum value matches 'zzz'"), "--find without a match: \(missing.output)")

            let json = try enumCLI(["enums", checkout.path, "--json"])
            let listings = try JSONSerialization.jsonObject(with: Data(json.output.utf8)) as? [[String: Any]] ?? []
            let order = listings.first { $0["id"] as? String == "order-status" }
            check(json.status == 0 && (order?["values"] as? [[String: Any]])?.count == 4 &&
                  order?["columns"] as? [String] == ["db.orders.status"] &&
                  ((order?["transitions"] as? [[String: Any]])?.first?["by"] as? String) == "orders/capture-payment", "json: \(json.output)")
            let help = try enumCLI(["--help"])
            check(help.output.contains("enums <file|id>"), "help lists enums")
        },
    ]
}

private func enumCLI(_ args: [String]) throws -> (status: Int32, output: String) {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().appendingPathComponent("strata")
    let fm = FileManager.default
    let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let process = Process()
    process.executableURL = executable
    process.arguments = args
    process.currentDirectoryURL = root
    var environment = ProcessInfo.processInfo.environment
    environment["STRATA_HOME"] = root.appendingPathComponent("home").path
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)
    defer { watchdog.cancel() }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationReason == .exit ? process.terminationStatus : -1, String(decoding: data, as: UTF8.self))
}
