import Foundation
import StrataCore

// Drift (docs/manifest.md, Drift): each finding kind on a synthetic repo built in a temp dir, no false
// positives on the clean repo, the SQL normalisation rules, HEAD and the cache, `strata drift` output and
// exit codes, and a timing bound on a repo of a few thousand files.

@MainActor func driftChecks() -> [CheckCase] {
    [
        CheckCase(name: "drift finds nothing on a clean repo") {
            let fixture = try DriftFixture()
            guard let report = fixture.check() else { return check(false, "fixture manifest did not parse") }
            check(report.status == .checked, "status \(report.status)")
            check(report.findings.isEmpty, "clean fixture has findings:\n" + report.findings.map { "\($0.severity) \($0.rule) \($0.message)" }.joined(separator: "\n"))
            check(report.summary.freshness == 100 && report.summary.checked >= 25, "summary \(report.summary)")
            let kinds = Dictionary(uniqueKeysWithValues: report.summary.kinds.map { ($0.kind, $0.checked) })
            check(kinds[.code, default: 0] >= 10 && kinds[.sql] == 5 && kinds[.binaries] == 4 && kinds[.messaging, default: 0] >= 4 && kinds[.enums] == 3,
                  "checked per kind \(kinds)")
            check(!report.findings.contains { $0.repo?.file.hasPrefix("vendor/") == true || $0.repo?.file.contains("node_modules") == true },
                  "vendor/ and node_modules/ are skipped")
        },
        CheckCase(name: "drift sql normalisation") {
            let a = Drift.normalizedSQL("SELECT id\n  FROM Orders -- comment\n WHERE id = $1;")
            let b = Drift.normalizedSQL("select ID from orders /* x */ where ID = ?")
            check(a == b && a == ["select id from orders where id = ?"], "whitespace, case, comments, placeholders: \(a) vs \(b)")
            check(Drift.normalizedSQL("SELECT 1 FROM t WHERE a = :name AND b = @b AND c = sqlc.arg(c) AND d = sqlc.narg('d')")
                    == ["select 1 from t where a = ? and b = ? and c = ? and d = ?"], "named placeholders and sqlc.arg")
            check(Drift.normalizedSQL("BEGIN; UPDATE t SET a = 1 WHERE id = $1; COMMIT;") == ["update t set a = 1 where id = ?"],
                  "transaction control dropped")
            check(Drift.normalizedSQL("SELECT * FROM t WHERE s = 'Open'") != Drift.normalizedSQL("SELECT * FROM t WHERE s = 'open'"),
                  "string literals keep their case in the exact pass")
            check(Drift.normalizedSQL("SELECT * FROM t WHERE id IN (101, 102, 103) AND s = 'x'", loose: true)
                    == Drift.normalizedSQL("SELECT * FROM t WHERE id IN (sqlc.slice(ids)) AND s = $2", loose: true),
                  "loose: literals and IN lists read as placeholders")
            check(Drift.normalizedSQL("SELECT a FROM t WHERE x <> 1") == Drift.normalizedSQL("SELECT a FROM t WHERE x != 1"), "<> is !=")
            check(Drift.normalizedSQL("-- name: GetX :one\nSELECT a FROM \"T\" WHERE id = $1") == ["select a from t where id = ?"],
                  "sqlc name line and quoted identifiers")
        },
        CheckCase(name: "drift code references: missing file with hint, line past end, moved symbol") {
            let fixture = try DriftFixture()
            // The map as written against the clean repo; then the repo moves on.
            let text = fixture.manifestText().replacingOccurrences(of: "internal/cache/keys.go:4", with: "internal/cache/keys.go:40")
            try fixture.move("internal/lock/lock.go", "internal/lock/valkey_lock.go")
            try fixture.edit("internal/cache/keys.go") { _ in "package cache\n\nconst priceKeyPrefix = \"app:price:\"\n" }
            // GetOrder moves 20 lines down.
            try fixture.edit("internal/store/query.sql") { String(repeating: "-- padding\n", count: 20) + $0 }
            guard let report = fixture.check(text, kinds: [.code]) else { return check(false, "no manifest") }
            let missing = report.findings.filter { $0.rule == "missing-file" }
            check(missing.count == 2 && missing.allSatisfy { $0.severity == .error && $0.found?.hasPrefix("internal/lock/valkey_lock.go") == true },
                  "renamed file with a hint: \(missing.map(\.message))")
            check(missing.contains { $0.map?.mechanism == "sweep-lock" && $0.map?.step == "take" }, "a step's reference is located: \(missing.map { $0.map?.description ?? "" })")
            let past = report.findings.first { $0.rule == "line-past-end" }
            check(past?.severity == .warn && past?.map?.op == "price" && past?.message.contains("3 lines") == true, "line past end: \(String(describing: past))")
            let moved = report.findings.filter { $0.rule == "symbol-moved" }
            check(moved.contains { $0.map?.op == "get-order" && $0.found == "internal/store/query.sql:21" && $0.severity == .warn },
                  "sqlc name moved: \(moved.map { "\($0.map?.op ?? "") \($0.found ?? "")" })")
            check(report.summary.kind(.code)?.stale == report.findings.filter { $0.severity != .info }.count, "stale facts \(report.summary)")
        },
        CheckCase(name: "drift code references: weak symbols only flag definitions, never prose") {
            let fixture = try DriftFixture()
            // The doc names Cancel(), defined in repo.go; a reference inside Cancel, and one at a symbol the
            // doc names that this file doesn't define, are both fine.
            let cancelBody = fixture.line("ExecContext(ctx,", in: "internal/orders/repo.go")
            let search = fixture.line("func (r *Repo) Search", in: "internal/orders/repo.go")
            let ops = [
                "- { id: inside, kind: http, label: cancel endpoint, doc: \"Calls `Cancel()`.\", code: \"internal/orders/repo.go:\(cancelBody)\" }",
                "- { id: elsewhere, kind: http, label: other, doc: \"See `Acquire()`.\", code: \"internal/orders/repo.go:3\" }",
                "- { id: outside, kind: http, label: count endpoint, doc: \"Calls `Cancel()`.\", code: \"internal/orders/repo.go:\(search)\" }",
                "- { id: dir, kind: http, label: dir, code: internal/orders }",
                "- { id: url, kind: http, label: url, code: \"https://example.com/x.go:3\" }",
                "- { id: glob, kind: http, label: glob, code: \"internal/store/*.sql\" }",
                "- { id: noglob, kind: http, label: noglob, code: \"internal/nowhere/*.sql\" }",
            ].map { "      " + $0 }.joined(separator: "\n")
            guard let report = fixture.check(fixture.manifestText(extraOps: ops), kinds: [.code]) else { return check(false, "no manifest") }
            let byOp = Dictionary(grouping: report.findings) { $0.map?.op ?? "" }
            check(byOp["inside"] == nil && byOp["elsewhere"] == nil && byOp["dir"] == nil && byOp["url"] == nil && byOp["glob"] == nil,
                  "false positives: \(report.findings.map { "\($0.map?.op ?? "") \($0.rule)" })")
            check(byOp["outside"]?.first?.rule == "symbol-moved" && byOp["outside"]?.first?.severity == .info, "weak symbol outside its definition is a note")
            check(byOp["noglob"]?.first?.rule == "missing-file", "a glob that matches nothing")
        },
        CheckCase(name: "drift sql: changed, renamed, missing and unmapped queries") {
            let fixture = try DriftFixture()
            try fixture.edit("internal/store/query.sql") { text in
                text.replacingOccurrences(of: "WHERE id = $1;", with: "WHERE id = $1 AND deleted_at IS NULL;")
                    .replacingOccurrences(of: "-- name: InsertOrder :one", with: "-- name: CreateOrder :one")
                    .replacingOccurrences(of: "-- name: ListOrders :many", with: "-- name: ListOrdersByCustomer :many")
                    .replacingOccurrences(of: "WHERE customer_id = sqlc.arg(customer_id)", with: "WHERE customer_id = sqlc.arg(customer_id) AND state <> 'closed'")
                    + "\n-- name: ListReturns :many\nSELECT id FROM returns WHERE order_id = $1;\n"
            }
            try fixture.edit("internal/orders/repo.go") { text in
                text.replacingOccurrences(of: "WHERE state = 'open'", with: "WHERE state = 'open' AND region = $1")
                    + "\nconst purge = `DELETE FROM orders WHERE state = 'closed' AND updated_at < now() - interval '1 year'`\n"
            }
            try fixture.edit("internal/orders/repo.go") { $0.replacingOccurrences(of: "\"UPDATE orders SET state = 'closed' \"+", with: "\"UPDATE orders SET state = 'void' \"+") }
            guard let report = fixture.check(kinds: [.sql]) else { return check(false, "no manifest") }
            func finding(_ op: String) -> DriftFinding? { report.findings.first { $0.map?.op == op } }
            let changed = finding("get-order")
            check(changed?.rule == "query-changed" && changed?.repo == DriftRepoLocation(file: "internal/store/query.sql", line: 1)
                  && changed?.diff?.contains { $0.hasPrefix("+") && $0.contains("deleted_at IS NULL") } == true
                  && changed?.diff?.contains { $0.hasPrefix("- WHERE id = $1") } == true,
                  "sqlc body changed with a diff: \(String(describing: changed))")
            let renamed = finding("insert-order")
            check(renamed?.rule == "query-renamed" && renamed?.found == "CreateOrder" && renamed?.fix.contains("-- name: CreateOrder :one") == true,
                  "same text under a new name: \(String(describing: renamed))")
            let gone = finding("list-orders")
            check(gone?.rule == "query-changed" && gone?.severity == .warn && gone?.found == "ListOrdersByCustomer",
                  "renamed and changed: the closest query: \(String(describing: gone))")
            let count = finding("count-open")
            check(count?.rule == "query-changed" && count?.repo?.file == "internal/orders/repo.go", "raw SQL changed: \(String(describing: count))")
            let cancel = finding("cancel")
            check(cancel?.rule == "query-changed" && cancel?.diff?.contains { $0.contains("'void'") } == true, "concatenated Go string: \(String(describing: cancel))")
            let unmapped = report.findings.filter { $0.rule == "unmapped-query" }
            check(unmapped.contains { $0.severity == .warn && $0.ref == "ListReturns" } &&
                  unmapped.contains { $0.severity == .info && $0.repo?.file == "internal/orders/repo.go" && $0.message.contains("DELETE FROM orders") },
                  "unmapped sqlc (warn) and raw SQL (note): \(unmapped.map(\.message))")
            check(!report.findings.contains { $0.message.contains("generated_only") || $0.message.contains("settings") || $0.message.contains("WHERE \"") },
                  "generated code, migrations and fragments aren't queries: \(report.findings.map(\.message))")

            // A sqlc query that is gone with nothing like it is an error.
            try fixture.edit("internal/store/query.sql") { _ in "-- name: Other :one\nSELECT 1 FROM elsewhere WHERE x = $1;\n" }
            let missing = fixture.check(kinds: [.sql])?.findings.first { $0.map?.op == "get-order" }
            check(missing?.rule == "query-missing" && missing?.severity == .error, "sqlc name gone: \(String(describing: missing))")
        },
        CheckCase(name: "drift binaries: unmapped, gone, subcommands, Procfile") {
            let fixture = try DriftFixture()
            try fixture.write("cmd/reaper/main.go", "package main\n\nfunc main() {}\n")
            try fixture.write("internal/plugin/cmd/helper/internal/x/main.go", "package main\n\nfunc main() {}\n")
            try fixture.edit("internal/cli/cmds.go") { $0.replacingOccurrences(of: "Use: \"sweeper\"", with: "Use: \"janitor\"") }
            try fixture.edit("Procfile") { $0 + "scheduler: ./bin/scheduler\n" }
            try fixture.move("cmd/worker", "cmd/consumer")
            guard let report = fixture.check(kinds: [.binaries]) else { return check(false, "no manifest") }
            let rules = report.findings.map { "\($0.severity.rawValue) \($0.rule) \($0.ref ?? "")" }
            check(rules.contains("warn unmapped-binary cmd/reaper"), "new cmd main: \(rules)")
            check(rules.contains("info unmapped-binary internal/plugin/cmd/helper/internal/x"), "a nested internal main is a note: \(rules)")
            check(rules.contains("error binary-gone ./cmd/worker"), "mapped binary gone: \(rules)")
            check(rules.contains("warn unmapped-binary cmd/consumer"), "its replacement is unmapped: \(rules)")
            check(rules.contains("warn subcommand-gone tool start sweeper --once"), "subcommand gone: \(rules)")
            check(rules.contains("info unmapped-subcommand tool start janitor"), "sibling subcommand: \(rules)")
            check(rules.contains("warn unmapped-binary scheduler"), "Procfile entry: \(rules)")
            check(!rules.contains { $0.contains("tools/gen") || $0.contains("relay") || $0.contains("cmd/api") }, "no false positives: \(rules)")
        },
        CheckCase(name: "drift messaging and keys") {
            let fixture = try DriftFixture()
            try fixture.edit("internal/bus/bus.go") { text in
                text.replacingOccurrences(of: "\"order.created\"", with: "\"order.placed\"")
                    .replacingOccurrences(of: "\treturn err\n}\n\nfunc Publish", with: "\tif _, err := ch.QueueDeclare(\"orders.refunds\", true, false, false, false, nil); err != nil {\n\t\treturn err\n\t}\n\treturn err\n}\n\nfunc Publish")
                    + "\nconst auditQueue = \"orders.audit\"\n"
            }
            try fixture.edit("internal/lock/lock.go") { $0 + "\nfunc leaseKey(id string) string { return fmt.Sprintf(\"app:lease:%s\", id) }\n" }
            try fixture.edit("internal/cache/keys.go") { $0.replacingOccurrences(of: "app:price:", with: "app:cost:") }
            guard let report = fixture.check(kinds: [.messaging]) else { return check(false, "no manifest") }
            let rules = report.findings.map { "\($0.severity.rawValue) \($0.rule) \($0.ref ?? "")" }
            check(rules.contains("warn unmapped-name orders.refunds"), "declared queue: \(rules)")
            check(rules.contains("warn unmapped-name order.placed"), "routing key: \(rules)")
            check(rules.contains("info unmapped-name orders.audit"), "named constant is a note: \(rules)")
            check(rules.contains("info unmapped-name app:lease:%s"), "key pattern: \(rules)")
            check(rules.contains("warn name-gone order.created"), "mapped routing key gone: \(rules)")
            check(rules.contains("info key-gone app:price:{sku}") && rules.contains("info unmapped-name app:cost:"), "key prefix changed: \(rules)")
            check(!rules.contains { $0.contains("app:lock") || $0.contains("vendored") || $0.contains("shop/1.0") }, "no false positives: \(rules)")
        },
        CheckCase(name: "drift enums: added, removed, renamed, iota and SQL") {
            let fixture = try DriftFixture()
            try fixture.edit("internal/orders/status.go") { text in
                text.replacingOccurrences(of: "\tStatusShipped Status = 30\n", with: "\tStatusShipped Status = 30\n\tStatusReturned Status = 40\n")
                    .replacingOccurrences(of: "\tStatusPaid    Status = 20\n", with: "")
                    .replacingOccurrences(of: "\tPriorityHigh\n", with: "\tPriorityHigh\n\tPriorityUrgent\n")
            }
            try fixture.edit("internal/store/migrations/001_init.sql") { $0 + "\nALTER TYPE order_kind ADD VALUE 'marketplace';\n" }
            guard let report = fixture.check(kinds: [.enums]) else { return check(false, "no manifest") }
            func on(_ id: String) -> [String] { report.findings.filter { $0.map?.enumID == id }.map { "\($0.rule) \($0.found ?? $0.ref ?? "")" } }
            check(on("order-status").contains("value-added 40 (StatusReturned)") && on("order-status").contains("value-removed 20 (paid)"),
                  "typed const block: \(on("order-status"))")
            check(on("priority") == ["value-added 3 (PriorityUrgent)"], "iota: \(on("priority"))")
            check(on("order-kind") == ["value-added marketplace"], "Postgres enum with ADD VALUE: \(on("order-kind"))")

            // A string enum with one value swapped is a rename (here the CHECK constraint's values); a map enum
            // the repo doesn't define is a note.
            let text = fixture.manifestText().replacingOccurrences(of: "  - id: priority\n", with: """
                  - id: order-state
                    values: [{ value: new, name: new }, { value: open, name: open }, { value: done, name: done }]
                  - id: tiers
                    values: [{ value: gold, name: gold }, { value: silver, name: silver }]
                  - id: priority

                """)
            guard let second = fixture.check(text, kinds: [.enums]) else { return check(false, "no manifest") }
            let state = second.findings.filter { $0.map?.enumID == "order-state" }
            check(state.count == 1 && state[0].rule == "value-renamed" && state[0].ref == "done" && state[0].found == "closed", "rename: \(state.map(\.message))")
            check(second.findings.contains { $0.map?.enumID == "tiers" && $0.rule == "enum-not-found" && $0.severity == .info }, "not found is a note")
        },
        CheckCase(name: "drift report: badges per level, JSON cache round trip, git HEAD") {
            let fixture = try DriftFixture()
            try fixture.edit("internal/cli/cmds.go") { $0.replacingOccurrences(of: "Use: \"sweeper\"", with: "Use: \"janitor\"") }
            try fixture.remove("internal/lock/lock.go")
            guard let report = fixture.check() else { return check(false, "no manifest") }
            check(report.staleNodes(level: [])["orders"].map { $0 >= 2 } == true, "a finding inside a deep dive badges its node: \(report.staleNodes(level: []))")
            check(report.staleNodes(level: ["orders"]) == ["sweeper": 1], "the inner node: \(report.staleNodes(level: ["orders"]))")
            check(report.findings(level: [], node: "orders").contains { $0.map?.level == ["orders"] && $0.map?.node == "sweeper" },
                  "node findings include its deep dive")

            // Cache: ~/.strata/drift/<id>.json, decoded back the same.
            let home = fixture.root.appendingPathComponent("home")
            setenv("STRATA_HOME", home.path, 1)
            defer { unsetenv("STRATA_HOME") }
            try DriftCache.save(report)
            let loaded = DriftCache.load(report.manifest)
            check(FileManager.default.fileExists(atPath: home.appendingPathComponent("drift/drift-fixture.json").path), "cache file path")
            check(loaded?.findings == report.findings && loaded?.summary == report.summary && loaded?.repo == report.repo, "cache round trip")

            // HEAD: a branch ref, packed-refs, and a worktree's gitdir file.
            let git = fixture.root.appendingPathComponent(".git")
            try FileManager.default.createDirectory(at: git.appendingPathComponent("refs/heads"), withIntermediateDirectories: true)
            try Data("ref: refs/heads/main\n".utf8).write(to: git.appendingPathComponent("HEAD"))
            try Data("0123abc\n".utf8).write(to: git.appendingPathComponent("refs/heads/main"))
            check(DriftGit.head(fixture.root) == "0123abc" && DriftGit.head(fixture.root.appendingPathComponent("internal/orders")) == "0123abc", "branch ref")
            try FileManager.default.removeItem(at: git.appendingPathComponent("refs/heads/main"))
            try Data("# pack-refs\nfeed42 refs/heads/main\n".utf8).write(to: git.appendingPathComponent("packed-refs"))
            check(DriftGit.head(fixture.root) == "feed42", "packed-refs")
            let worktree = fixture.root.appendingPathComponent("wt")
            let wtGit = git.appendingPathComponent("worktrees/wt")
            try FileManager.default.createDirectory(at: wtGit, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
            try Data("gitdir: \(wtGit.path)\n".utf8).write(to: worktree.appendingPathComponent(".git"))
            try Data("ref: refs/heads/feature\n".utf8).write(to: wtGit.appendingPathComponent("HEAD"))
            try Data("../..\n".utf8).write(to: wtGit.appendingPathComponent("commondir"))
            try Data("# pack-refs\nfeed42 refs/heads/main\nbeef77 refs/heads/feature\n".utf8).write(to: git.appendingPathComponent("packed-refs"))
            check(DriftGit.head(worktree) == "beef77", "worktree HEAD through commondir: \(String(describing: DriftGit.head(worktree)))")
            let fresh = Drift.check(fixture.manifest()!)
            check(fresh.head == "feed42", "the report carries HEAD")
            var stale = fresh
            stale.head = "old"
            check(DriftCache.isCurrent(fresh, manifest: fixture.manifest()!, digest: nil) && !DriftCache.isCurrent(stale, manifest: fixture.manifest()!, digest: nil),
                  "isCurrent compares HEAD")
        },
        CheckCase(name: "drift without a repo, or with one that isn't here") {
            let (none, _) = ManifestParser.parse("strata: 1\nid: x\ntitle: X\nnodes: [{ id: a, kind: service }]\n", source: .file(URL(fileURLWithPath: "/checks/x.yaml")))
            check(none.map { Drift.check($0).status } == .noRepo, "no repo:")
            let (gone, _) = ManifestParser.parse("strata: 1\nid: y\ntitle: Y\nrepo: /nonexistent/strata-drift-repo\nnodes: [{ id: a, kind: service, code: main.go }]\n",
                                                 source: .file(URL(fileURLWithPath: "/checks/y.yaml")))
            let report = gone.map { Drift.check($0) }
            check(report?.status == .repoMissing && report?.findings.isEmpty == true && report?.repo == "/nonexistent/strata-drift-repo", "repo missing")
            check(gone.map { Drift.check($0, options: DriftOptions(repo: "/nonexistent/other")).repo } == "/nonexistent/other", "--repo overrides")
            for url in (try? FileManager.default.contentsOfDirectory(at: StrataResources.url("Examples")!, includingPropertiesForKeys: nil)) ?? [] {
                guard let manifest = ManifestParser.parse(try String(contentsOf: url, encoding: .utf8), source: .bundled(url)).0 else { continue }
                let status = Drift.check(manifest).status
                check(status != .checked, "\(url.lastPathComponent) has no repo here: \(status)")
            }
        },
        CheckCase(name: "cli drift: grouped output, json, kinds, quiet and exit codes") {
            let fixture = try DriftFixture()
            let map = fixture.root.appendingPathComponent("map.yaml")
            try Data(fixture.manifestText().utf8).write(to: map)
            let clean = try driftCLI(["drift", map.path], cwd: fixture.root)
            check(clean.status == 0 && clean.output.contains("freshness 100%") && clean.output.contains("SQL · 5 checked"), "clean: \(clean.output)")
            check(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("home/drift/drift-fixture.json").path), "the CLI caches a full check")

            try fixture.move("internal/lock/lock.go", "internal/lock/valkey_lock.go")
            try fixture.write("cmd/reaper/main.go", "package main\n\nfunc main() {}\n")
            let drifted = try driftCLI(["drift", map.path], cwd: fixture.root)
            check(drifted.status == 1 && drifted.output.contains("Code references · ") && drifted.output.contains("error internal/lock/lock.go is gone")
                  && drifted.output.contains("fix: Point code at internal/lock/valkey_lock.go") && drifted.output.contains("not on the map")
                  && drifted.output.contains("cmd/reaper builds a binary no node runs"), "drifted: \(drifted.output)")
            let json = try driftCLI(["drift", map.path, "--json"], cwd: fixture.root)
            let object = try JSONSerialization.jsonObject(with: Data(json.output.utf8)) as? [String: Any]
            let findings = object?["findings"] as? [[String: Any]] ?? []
            check(json.status == 1 && object?["status"] as? String == "checked" && findings.contains {
                ($0["map"] as? [String: Any])?["mechanism"] as? String == "sweep-lock" && $0["fix"] is String && ($0["repo"] as? [String: Any])?["file"] != nil
                    && ($0["map"] as? [String: Any])?["line"] is Int
            }, "json: \(json.output.prefix(400))")
            let only = try driftCLI(["drift", map.path, "--kind", "sql,enums"], cwd: fixture.root)
            check(only.status == 0 && only.output.contains("SQL · ") && !only.output.contains("Code references"), "--kind: \(only.output)")
            let quiet = try driftCLI(["drift", map.path, "--quiet"], cwd: fixture.root)
            check(quiet.status == 1 && quiet.output.split(separator: "\n").count == 1 && quiet.output.contains("drift-fixture · freshness"), "--quiet: \(quiet.output)")
            let bad = try driftCLI(["drift", map.path, "--kind", "nope"], cwd: fixture.root)
            check(bad.status == 2 && bad.output.contains("--kind takes"), "bad kind: \(bad.output)")
            let elsewhere = try driftCLI(["drift", map.path, "--repo", "/nonexistent/strata-repo"], cwd: fixture.root)
            check(elsewhere.status == 2 && elsewhere.output.contains("isn't on this machine"), "missing repo: \(elsewhere.output)")
            let example = try driftCLI(["drift", "checkout"], cwd: fixture.root)
            check(example.status == 2 && example.output.contains("checkout has no repo"), "bundled example: \(example.output)")
            let help = try driftCLI(["--help"], cwd: fixture.root)
            check(help.output.contains("drift <file|id>"), "help lists drift")
        },
        CheckCase(name: "drift timing on a repo of a few thousand files") {
            let fixture = try DriftFixture()
            for i in 0..<3000 {
                let dir = "internal/pkg\(i / 50)"
                if i % 3 == 0 {
                    try fixture.write("\(dir)/repo\(i).go", """
                        package pkg\(i / 50)

                        const q\(i) = `SELECT id, name FROM table\(i % 40) WHERE id = $1 AND tenant = $2`

                        func Get\(i)() string { return q\(i) }

                        const (
                        \tKind\(i)A = iota
                        \tKind\(i)B
                        )

                        """)
                } else if i % 3 == 1 {
                    try fixture.write("\(dir)/doc\(i).md", String(repeating: "Some notes about package \(i).\n", count: 40))
                } else {
                    try fixture.write("\(dir)/svc\(i).go", "package pkg\(i / 50)\n\nfunc Handle\(i)(x int) int {\n\treturn x * \(i)\n}\n")
                }
            }
            try fixture.edit("internal/store/query.sql") { text in
                text + (0..<200).map { "\n-- name: Query\($0) :one\nSELECT a, b FROM t\($0) WHERE id = $1;\n" }.joined()
            }
            let started = Date()
            guard let report = fixture.check() else { return check(false, "no manifest") }
            let seconds = Date().timeIntervalSince(started)
            check(report.files > 3000, "indexed \(report.files) files")
            check(report.summary.kind(.sql)?.unmapped == 1200, "unmapped queries: \(report.summary.kind(.sql)?.unmapped ?? 0)")
            check(seconds < 3, "drift took \(seconds) s on \(report.files) files")
        },
    ]
}

private func driftCLI(_ args: [String], cwd: URL) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().appendingPathComponent("strata")
    process.arguments = args
    process.currentDirectoryURL = cwd
    var environment = ProcessInfo.processInfo.environment
    environment.removeValue(forKey: "STRATA_RESOURCES")
    environment["STRATA_HOME"] = cwd.appendingPathComponent("home").path
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}
