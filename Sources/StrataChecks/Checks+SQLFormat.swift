import Foundation
import StrataCore

// The SQL formatter (Support/SQLFormat.swift), the query warnings (Parse/Validate+SQL.swift) and the
// `binary:` field with the components a service card lists.

/// Queries as agents and people write them: compressed, lower case, commented, with every parameter style.
private let corpus = [
    "SELECT o.id, o.status, o.total_cents, o.currency, u.email, u.display_name, i.sku, i.qty, i.price_cents, p.status AS payment_status FROM orders o JOIN users u ON u.id = o.user_id JOIN order_items i ON i.order_id = o.id LEFT JOIN payments p ON p.order_id = o.id WHERE o.id = $1;",
    "BEGIN; INSERT INTO orders (id, user_id, status, total_cents, currency, idempotency_key) VALUES ($1, $2, 'placed', $3, 'EUR', $4); INSERT INTO order_items (order_id, sku, qty, price_cents) SELECT $1, unnest($5::text[]), unnest($6::int[]), unnest($7::int[]); INSERT INTO outbox (topic, key, payload) VALUES ('order-events', $1, $8); COMMIT;",
    "-- name: ClaimOutbox :many\nupdate outbox set claimed_at = now() where id in (select id from outbox where published_at is null order by id limit 100 for update skip locked) returning id, topic, key, payload;",
    "with due as (select id from campaigns where status = 3200 and start_at <= now() for update skip locked), started as (update campaigns c set status = 3300 from due where c.id = due.id returning c.id) select count(*) from started;",
    "INSERT INTO prices (sku, amount_cents, currency) VALUES (@sku, sqlc.arg(amount), sqlc.narg('currency')) ON CONFLICT (sku) DO UPDATE SET amount_cents = EXCLUDED.amount_cents, currency = EXCLUDED.currency, updated_at = now() WHERE prices.amount_cents <> EXCLUDED.amount_cents RETURNING sku;",
    "select 'select * from x where a and b' as s, \"Order\", \"select\" from t -- trailing note\nwhere a = 1 /* inline */ and b = 2",
    "select a.key, a.status, a.locked, a.interval from accounts a where a.locked = false and a.\"Key\" is distinct from $1 and extract(epoch from a.created_at) > 0 and a.n between 1 and 5",
    "SELECT 'it''s' || E'a\\'b' AS s, $$ select ;\n  from $$ AS body, `tick` FROM t WHERE c = ? AND d = :name AND e = @e;",
    "select 'a'\n  'b' as joined",
    "SELECT id, (SELECT count(*) FROM items i WHERE i.order_id = o.id) AS n FROM orders o UNION ALL SELECT id, 0 FROM archived ORDER BY id DESC NULLS LAST FETCH FIRST 10 ROWS ONLY",
    "select row_number() over (partition by user_id order by created_at desc) as rn, sum(total) filter (where status = 'paid') from orders group by user_id, status having count(*) > 1",
    "/* leading */ SELECT 1; -- after one\nSELECT 2;\n-- the end",
    "SELECT * FROM t WHERE a IN ($1, $2) AND b = ANY($3::bigint[]) AND c @> '{\"a\":1}'::jsonb AND d ->> 'k' = 'v' AND e=-1",
    "SELECT a, -- first\n b /* second */ FROM t WHERE x IN (SELECT y FROM u -- inner\n WHERE z) AND w",
    "DELETE FROM sessions WHERE expires_at < now() - interval '30 days' RETURNING id",
    "CREATE TABLE IF NOT EXISTS t (id bigserial PRIMARY KEY, name text NOT NULL, created_at timestamp with time zone DEFAULT now())",
]

@MainActor func sqlFormatChecks() -> [CheckCase] {
    [
        CheckCase(name: "sql format splits statements and marks the transaction") {
            let statements = SQLFormat.statements(corpus[1])
            check(statements.count == 5, "statements: \(statements.map(\.text))")
            check(statements.map(\.isTransactionControl) == [true, false, false, false, true], "transaction control")
            check(statements.allSatisfy { $0.text.hasSuffix(";") }, "each statement keeps its semicolon")
            check(statements[1].text == """
                INSERT INTO orders (
                  id,
                  user_id,
                  status,
                  total_cents,
                  currency,
                  idempotency_key
                )
                VALUES ($1, $2, 'placed', $3, 'EUR', $4);
                """, "insert:\n\(statements[1].text)")
            check(statements[2].text == """
                INSERT INTO order_items (order_id, sku, qty, price_cents)
                SELECT $1, unnest($5::text[]), unnest($6::int[]), unnest($7::int[]);
                """, "insert select:\n\(statements[2].text)")
            check(SQLFormat.statements("SELECT 1").count == 1, "one statement without a semicolon")
            check(SQLFormat.statements("SELECT ';' AS a; SELECT (1);").count == 2, "a semicolon in a string does not split")
            check(SQLFormat.statements("CREATE FUNCTION f() RETURNS int AS $$ BEGIN; RETURN 1; END $$ LANGUAGE sql;").count == 1,
                  "a semicolon in a dollar-quoted body does not split")
        },
        CheckCase(name: "sql format puts clauses on lines and conditions under WHERE") {
            check(SQLFormat.format(corpus[0]) == """
                SELECT
                  o.id,
                  o.status,
                  o.total_cents,
                  o.currency,
                  u.email,
                  u.display_name,
                  i.sku,
                  i.qty,
                  i.price_cents,
                  p.status AS payment_status
                FROM orders o
                JOIN users u ON u.id = o.user_id
                JOIN order_items i ON i.order_id = o.id
                LEFT JOIN payments p ON p.order_id = o.id
                WHERE o.id = $1;
                """, "select:\n\(SQLFormat.format(corpus[0]))")
            let between = SQLFormat.format(corpus[6])
            check(between.contains("\n  AND a.n BETWEEN 1 AND 5"), "BETWEEN keeps its AND:\n\(between)")
            check(between.contains("\n  AND a.\"Key\" IS DISTINCT FROM $1\n"), "IS DISTINCT FROM is not a FROM clause:\n\(between)")
            check(between.contains("extract(epoch FROM a.created_at)"), "FROM inside a call stays inline:\n\(between)")
            check(SQLFormat.format("select a from t where x = 1 and y = 2") == "SELECT a\nFROM t\nWHERE x = 1\n  AND y = 2", "short query")
        },
        CheckCase(name: "sql format indents subqueries, locks and CTE bodies") {
            check(SQLFormat.format(corpus[2]) == """
                -- name: ClaimOutbox :many
                UPDATE outbox
                SET claimed_at = now()
                WHERE id IN (
                  SELECT id
                  FROM outbox
                  WHERE published_at IS NULL
                  ORDER BY id
                  LIMIT 100
                  FOR UPDATE SKIP LOCKED
                )
                RETURNING id, topic, key, payload;
                """, "subquery:\n\(SQLFormat.format(corpus[2]))")
            check(SQLFormat.format(corpus[3]) == """
                WITH due AS (
                  SELECT id
                  FROM campaigns
                  WHERE status = 3200
                    AND start_at <= now()
                  FOR UPDATE SKIP LOCKED
                ),
                started AS (
                  UPDATE campaigns c
                  SET status = 3300
                  FROM due
                  WHERE c.id = due.id
                  RETURNING c.id
                )
                SELECT count(*)
                FROM started;
                """, "cte:\n\(SQLFormat.format(corpus[3]))")
            let union = SQLFormat.format(corpus[9])
            check(union.hasPrefix("SELECT\n  id,\n  (\n    SELECT count(*)\n"), "a select list with a subquery breaks:\n\(union)")
            check(union.contains("\nUNION ALL\nSELECT id, 0\nFROM archived\nORDER BY id DESC NULLS LAST\nFETCH FIRST 10 ROWS ONLY"), "union:\n\(union)")
        },
        CheckCase(name: "sql format lays out upserts with sqlc parameters") {
            check(SQLFormat.format(corpus[4]) == """
                INSERT INTO prices (sku, amount_cents, currency)
                VALUES (@sku, sqlc.arg(amount), sqlc.narg('currency'))
                ON CONFLICT (sku) DO UPDATE
                SET
                  amount_cents = EXCLUDED.amount_cents,
                  currency = EXCLUDED.currency,
                  updated_at = now()
                WHERE prices.amount_cents <> EXCLUDED.amount_cents
                RETURNING sku;
                """, "upsert:\n\(SQLFormat.format(corpus[4]))")
            check(SQLFormat.format("insert into t (a) values (:a) on conflict do nothing") == "INSERT INTO t (a)\nVALUES (:a)\nON CONFLICT DO NOTHING",
                  "do nothing: \(SQLFormat.format("insert into t (a) values (:a) on conflict do nothing"))")
        },
        CheckCase(name: "sql format keeps comments where they were") {
            check(SQLFormat.format(corpus[5]) == """
                SELECT 'select * from x where a and b' AS s, "Order", "select"
                FROM t -- trailing note
                WHERE a = 1 /* inline */
                  AND b = 2
                """, "comments:\n\(SQLFormat.format(corpus[5]))")
            check(SQLFormat.format(corpus[11]) == "/* leading */\nSELECT 1; -- after one\n\nSELECT 2;\n-- the end",
                  "comments around statements:\n\(SQLFormat.format(corpus[11]))")
            let listed = SQLFormat.format(corpus[13])
            check(listed.hasPrefix("SELECT\n  a, -- first\n  b /* second */\nFROM t\n"), "a commented list breaks:\n\(listed)")
            check(listed.contains("-- inner\n"), "a comment inside a subquery ends its line:\n\(listed)")
        },
        CheckCase(name: "sql format leaves strings, identifiers and bodies alone") {
            let quoted = SQLFormat.format(corpus[7])
            check(quoted.contains("'it''s' || E'a\\'b' AS s"), "strings:\n\(quoted)")
            check(quoted.contains("$$ select ;\n  from $$ AS body"), "dollar-quoted body verbatim:\n\(quoted)")
            check(quoted.contains("`tick`") && quoted.contains("c = ?") && quoted.contains("d = :name") && quoted.contains("e = @e"),
                  "parameters:\n\(quoted)")
            check(SQLFormat.format(corpus[8]) == "SELECT 'a'\n  'b' AS joined", "a string continued over a newline stays continued")
            let keys = SQLFormat.format(corpus[6])
            check(keys.hasPrefix("SELECT a.key, a.status, a.locked, a.interval\n"), "identifiers named like keywords keep their case:\n\(keys)")
            check(keys.contains("a.locked = FALSE"), "a column named locked stays lower case:\n\(keys)")
            check(SQLFormat.format("select now() - interval '1 day', x.interval from x for no key update skip locked")
                    .hasSuffix("INTERVAL '1 day', x.interval\nFROM x\nFOR NO KEY UPDATE SKIP LOCKED"), "contextual keywords")
            check(SQLFormat.format("SELECT a FROM t WHERE e=-1 AND f=ARRAY[1,2]").hasSuffix("e=-1\n  AND f=ARRAY[1, 2]"),
                  "operators and arrays keep their spacing: \(SQLFormat.format("SELECT a FROM t WHERE e=-1 AND f=ARRAY[1,2]"))")
        },
        CheckCase(name: "sql format breaks long joins and wraps what it cannot break") {
            let join = SQLFormat.format("SELECT c.id FROM campaigns c LEFT JOIN campaign_events e ON e.campaign_id = c.id AND e.kind = 'x'", width: 42)
            check(join == "SELECT c.id\nFROM campaigns c\nLEFT JOIN campaign_events e\n  ON e.campaign_id = c.id\n  AND e.kind = 'x'", "join:\n\(join)")
            let wrapped = SQLFormat.format("SELECT a FROM t WHERE c.account_id = sqlc.arg(account_id) AND x = 1", width: 30)
            check(wrapped.contains("WHERE c.account_id =\n    sqlc.arg(account_id)\n  AND x = 1"), "wrapped:\n\(wrapped)")
            let long = SQLFormat.format(corpus[0], width: 30)
            check(long.split(separator: "\n").allSatisfy { $0.count <= 30 }, "lines over 30 columns:\n\(long)")
        },
        CheckCase(name: "sql format is idempotent") {
            for source in corpus {
                for width in [SQLFormat.defaultWidth, 44, 30, 16] {
                    let once = SQLFormat.format(source, width: width)
                    let twice = SQLFormat.format(once, width: width)
                    check(once == twice, "not idempotent at \(width):\n\(once)\n--- became ---\n\(twice)")
                }
            }
        },
        CheckCase(name: "sql format changes only whitespace and keyword case") {
            for source in corpus {
                for width in [SQLFormat.defaultWidth, 44, 16] {
                    let before = SQLFormat.tokens(source), after = SQLFormat.tokens(SQLFormat.format(source, width: width))
                    check(before.count == after.count, "token count changed for \(source)")
                    for (a, b) in zip(before, after) where a.kind != b.kind || a.text != b.text {
                        let caseOnly = a.kind == .word && b.kind == .word && a.text.uppercased() == b.text
                        check(caseOnly, "'\(a.text)' became '\(b.text)' in \(source)")
                    }
                }
            }
        },
        CheckCase(name: "sql format recognises SQL") {
            check(SQLFormat.looksLikeSQL("-- name: X :one\nselect 1"), "commented select")
            check(SQLFormat.looksLikeSQL("WITH a AS (SELECT 1) SELECT * FROM a"), "with")
            check(SQLFormat.looksLikeSQL("(SELECT 1) UNION (SELECT 2)"), "parenthesised select")
            check(!SQLFormat.looksLikeSQL("{ \"query\": { \"match\": { \"title\": \"x\" } } }"), "json")
            check(!SQLFormat.looksLikeSQL("look up the user by email"), "prose")
            check(!SQLFormat.looksLikeSQL(""), "empty")
        },
        CheckCase(name: "sql format finds elided queries") {
            let elided = ["SELECT ...", "SELECT … FROM t", "SELECT * FROM t WHERE id IN (...)", "<query>", "SELECT <columns> FROM t", "TODO",
                          "INSERT INTO t VALUES (TODO)"]
            for query in elided { check(SQLFormat.placeholder(in: query) != nil, "missed a placeholder in \(query)") }
            check(SQLFormat.placeholder(in: "SELECT <column list> FROM t") == "<column list>", "the placeholder is quoted back")
            let whole = ["SELECT '...' FROM t", "SELECT a FROM t -- returns ... rows", "SELECT a FROM t WHERE a<b AND b>c",
                         "SELECT a FROM t WHERE x < y AND y > z", "SELECT \"…\" FROM t", "SELECT a FROM t /* TODO: index */",
                         "SELECT arr[1:2] FROM t", "SELECT todo FROM tasks"]
            for query in whole { check(SQLFormat.placeholder(in: query) == nil, "a false placeholder in \(query)") }
        },
        CheckCase(name: "sql format finds statements that are not whole") {
            check(SQLFormat.incompleteStatements("SELECT id, name") == ["SELECT id, name"], "select without from")
            check(SQLFormat.incompleteStatements("BEGIN; SELECT id; COMMIT;") == ["SELECT id;"], "one statement of a transaction")
            let partial = ["get the user by id", "update the order status", "set the status to paid", "fetch user by email",
                           "UPDATE orders", "DELETE orders WHERE id = $1", "INSERT orders", "SELECT *", "start campaign"]
            for query in partial { check(SQLFormat.incompleteStatements(query).count == 1, "missed \(query)") }
            let whole = ["SELECT 1", "SELECT now()", "SELECT pg_try_advisory_lock(hashtext($1))", "SELECT $1::int", "BEGIN",
                         "TRUNCATE outbox", "LOCK TABLE t IN EXCLUSIVE MODE", "NOTIFY jobs", "VALUES (1, 2)", "UPDATE t SET a = 1",
                         "DELETE FROM t", "INSERT INTO t DEFAULT VALUES", "SET LOCAL statement_timeout = '5s'", "START TRANSACTION",
                         "FETCH 10 FROM cur"] + corpus
            for query in whole {
                check(SQLFormat.incompleteStatements(query).isEmpty, "flagged a whole query: \(query) → \(SQLFormat.incompleteStatements(query))")
            }
        },
        sqlFinding("an elided query", "{id: a, kind: sql, label: A, target: db, query: \"SELECT ...\"}", path: "nodes.api.ops.a.query",
                   "the query looks elided ('...'); copy the full query verbatim from the code"),
        sqlFinding("a placeholder query", "{id: a, kind: sql, label: A, target: db, query: \"<query>\"}", path: "nodes.api.ops.a.query",
                   "looks elided ('<query>')"),
        sqlFinding("a described query", "{id: a, kind: sql, label: A, target: db, query: \"load the order with its items\"}",
                   path: "nodes.api.ops.a.query", "is not a whole statement (no FROM, INTO or SET where one belongs)"),
        sqlFinding("an UPDATE described in words", "{id: a, kind: sql, label: A, target: db, query: \"update the order status\"}",
                   path: "nodes.api.ops.a.query", "'update the order status' is not a whole statement"),
        sqlFinding("a sql op without a query", "{id: a, kind: sql, label: A, target: db}", path: "nodes.api.ops.a",
                   "this sql op has no query yet; copy the full query verbatim"),
        sqlFinding("an elided search query", "{id: a, kind: search, label: A, target: db, query: \"SELECT … FROM docs\"}",
                   path: "nodes.api.ops.a.query", "looks elided ('…')"),
        CheckCase(name: "sql format whole queries validate cleanly") {
            for query in ["SELECT id FROM t WHERE a = $1", "SELECT 1", "BEGIN; UPDATE t SET a = 1; COMMIT;"] {
                let (manifest, diagnostics) = ManifestParser.parse(sqlManifest("{id: a, kind: sql, label: A, target: db, query: \"\(query)\"}"),
                                                                   source: sqlSource)
                check(manifest != nil && diagnostics.isEmpty, "\(query): \(diagnostics)")
            }
            let search = sqlManifest("{id: a, kind: search, label: A, target: db, query: '{ \"match\": { \"title\": \"x\" } }'}")
            check(ManifestParser.parse(search, source: sqlSource).1.isEmpty, "a JSON search query is fine")
        },
        CheckCase(name: "sql format binaries and components") {
            let text = """
                strata: 1
                id: bins
                title: Binaries
                nodes:
                  - id: svc
                    kind: service
                    code: cmd
                    inside:
                      nodes:
                        - {id: in, kind: port}
                        - {id: api, kind: service, binary: cmd/api, code: cmd/api/main.go}
                        - {id: worker, kind: worker, binary: cmd/worker}
                        - {id: scheduler, kind: cron, binary: cmd/scheduler}
                        - {id: db, kind: database}
                        - {id: hint, kind: note, doc: Shared packages live in internal/.}
                        - {id: thumb, kind: function}
                """
            let (manifest, diagnostics) = ManifestParser.parse(text, source: sqlSource)
            check(diagnostics.isEmpty, "diagnostics: \(diagnostics)")
            let svc = manifest?.root.node("svc")
            check(svc?.components.map(\.id) == ["api", "worker", "scheduler", "thumb"], "components: \(svc?.components.map(\.id) ?? [])")
            check(svc?.inside?.node("worker")?.binary == "cmd/worker", "binary decoded")
            check(svc?.binary == nil && manifest?.root.node("svc")?.inside?.node("in")?.components.isEmpty == true, "no binary, no components")
        },
    ]
}

private let sqlSource = ManifestSource.file(URL(fileURLWithPath: "/checks/sql.yaml"))

private func sqlManifest(_ op: String) -> String {
    """
    strata: 1
    id: sql
    title: SQL
    nodes:
      - {id: db, kind: database}
      - {id: api, kind: service, ops: [\(op)]}
    edges: [{from: api, to: db}]
    """
}

@MainActor private func sqlFinding(_ name: String, _ op: String, path: String, _ message: String) -> CheckCase {
    CheckCase(name: "sql format warns about \(name)") {
        let (manifest, diagnostics) = ManifestParser.parse(sqlManifest(op), source: sqlSource)
        check(manifest != nil, "the manifest failed to load: \(diagnostics)")
        check(diagnostics.contains { $0.severity == .warning && $0.path == path && $0.message.contains(message) },
              "expected a warning at \(path) containing '\(message)', got \(diagnostics)")
        check(diagnostics.count == 1, "expected one finding, got \(diagnostics)")
    }
}
