import Foundation
import StrataCore

// Briefs (docs/manifest.md, Briefs): decoding `brief:`, the automatic short form, and the warning on a
// long doc, narration or summary that has no brief.

private func parse(_ body: String) -> (Manifest?, [Diagnostic]) {
    ManifestParser.parse("strata: 1\nid: briefs\ntitle: Briefs\n" + body, source: .file(URL(fileURLWithPath: "/checks/briefs.yaml")))
}

/// A paragraph of `count` characters or so, in sentences, no brief.
private func paragraph(_ count: Int) -> String {
    let sentence = "The worker drains the queue and writes each result to the store. "
    return String(String(repeating: sentence, count: count / sentence.count + 1).prefix(count))
        .trimmingCharacters(in: .whitespaces)
}

@MainActor func briefChecks() -> [CheckCase] {
    [
        CheckCase(name: "brief short form ends at the first sentence") {
            let cases: [(String, String)] = [
                ("Owns orders. Writes to Postgres.", "Owns orders."),
                ("Is it cached? Usually.", "Is it cached?"),
                ("Calls `cfg.Load()` at start. Then it waits.", "Calls `cfg.Load()` at start."),
                ("Calls `pool.Get`. Then it waits.", "Calls `pool.Get`."),
                ("Retries every 0.5 s with backoff. Gives up after 3.", "Retries every 0.5 s with backoff."),
                ("Runs Go 1.22. Builds with make.", "Runs Go 1.22."),
                ("Talks to stores, e.g. Postgres and Redis, over TLS. More here.", "Talks to stores, e.g. Postgres and Redis, over TLS."),
                ("Uses the lease (i.e. a key with a TTL) to fence writers. More.", "Uses the lease (i.e. a key with a TTL) to fence writers."),
                ("Caches vs. stores differ here. More.", "Caches vs. stores differ here."),
                ("Keys, TTLs, etc. are set here. More.", "Keys, TTLs, etc. are set here."),
                ("Holds keys, TTLs, etc. The relay reads them.", "Holds keys, TTLs, etc."),
                ("Waits 10 min. Then it retries.", "Waits 10 min."),
                ("See [[Maps/a.b note]] for the setup. More.", "See [[Maps/a.b note]] for the setup."),
                ("Read [the runbook](https://wiki.example.com/a.b) first. More.", "Read [the runbook](https://wiki.example.com/a.b) first."),
                ("Owns the order\nlifecycle. Then more.", "Owns the order lifecycle."),
                ("A heading without a stop\n\nThe next paragraph.", "A heading without a stop"),
                ("Three binaries:\n- api\n- worker", "Three binaries…"),
                ("- api serves the admin UI\n- worker drains the queue", "api serves the admin UI"),
                ("## Billing\n\nMore.", "Billing"),
                ("**Owns** the roster. More.", "**Owns** the roster."),
                ("Says \"stop.\" Then it stops.", "Says \"stop.\""),
                ("No stop at all", "No stop at all"),
            ]
            for (text, expected) in cases {
                let short = Brief.shortForm(text)
                check(short == expected, "short form of \(text.debugDescription): got \(short.debugDescription), expected \(expected.debugDescription)")
            }
        },
        CheckCase(name: "brief short form is capped at a word, outside code and links") {
            let long = "The billing worker totals every open invoice of an account from its line items, its discounts and the taxes"
                + " the tax service returns, then writes the total."
            let short = Brief.shortForm(long)
            check(short.count <= Brief.shortFormCharacters + 1 && short.hasSuffix("…"), "not capped: \(short)")
            check(long.hasPrefix(String(short.dropLast())), "not a prefix: \(short)")
            check(!short.dropLast().hasSuffix(" "), "ends in a space: \(short)")
            // Position 100 falls inside the code span: the cut backs out before it.
            let code = String(repeating: "word ", count: 18) + "`internal/adapters/postgres/invoicerepo.Load` and more words after it."
            let cut = Brief.shortForm(code)
            check(cut.filter { $0 == "`" }.count % 2 == 0 && cut.hasSuffix("…"), "cut inside code: \(cut)")
            let wiki = String(repeating: "word ", count: 18) + "[[Maps/a long note name here]] and more words after it."
            check(!Brief.shortForm(wiki).contains("[["), "cut inside a wiki link: \(Brief.shortForm(wiki))")
            let aside = String(repeating: "word ", count: 15) + "(an aside that runs on well past the cap of the short form) and more."
            check(!Brief.shortForm(aside).contains("("), "left an aside open: \(Brief.shortForm(aside))")
        },
        CheckCase(name: "brief long text threshold") {
            check(!Brief.isLong(String(repeating: "a", count: Brief.longCharacters)), "280 characters counted as long")
            check(Brief.isLong(String(repeating: "a", count: Brief.longCharacters + 1)), "281 characters not long")
            check(!Brief.isLong("one\ntwo\n\nthree\n"), "3 lines counted as long")
            check(Brief.isLong("- one\n- two\n- three\n- four"), "4 bullets not long")
            check(Brief.briefProblem("Owns orders; prices the cart and commits the order.") == nil, "a good brief has a problem")
            check(Brief.briefProblem(String(repeating: "a", count: Brief.briefCharacters + 1)) != nil, "a long brief has no problem")
            check(Brief.briefProblem("one\ntwo") != nil, "a two-line brief has no problem")
        },
        CheckCase(name: "brief parts lead with the brief or a short form") {
            let long = paragraph(400)
            let briefed = Brief.parts(brief: "Owns invoices.", detail: long)
            check(briefed == Brief.Parts(lead: "Owns invoices.", more: long, leadIsBrief: true), "brief and doc: \(String(describing: briefed))")
            check(Brief.parts(brief: "Owns invoices.", detail: nil)?.more == nil, "a brief alone has more")
            check(Brief.parts(brief: "Owns invoices.", detail: "Owns invoices.")?.more == nil, "a doc equal to its brief shows twice")
            let short = Brief.parts(brief: nil, detail: "Short and sweet. Two sentences.")
            check(short == Brief.Parts(lead: "Short and sweet. Two sentences.", more: nil, leadIsBrief: false), "short doc: \(String(describing: short))")
            let auto = Brief.parts(brief: nil, detail: long)
            check(auto?.lead == "The worker drains the queue and writes each result to the store." && auto?.more == long && auto?.leadIsBrief == false,
                  "long doc: \(String(describing: auto))")
            check(Brief.parts(brief: "  ", detail: nil) == nil, "an empty brief made parts")
            check(Brief.line(brief: nil, detail: long) == "The worker drains the queue and writes each result to the store.", "line of a long doc")
        },
        CheckCase(name: "brief decodes on nodes, ops, flows, mechanisms and levels") {
            let (manifest, diagnostics) = parse("""
                brief: The root level in one line.
                narration: Watch the requests.
                nodes:
                  - { id: client, kind: client }
                  - id: api
                    kind: service
                    brief: Owns orders.
                    doc: Fails when Postgres refuses writes.
                    ops:
                      - { id: get, kind: http, label: GET /orders, brief: Lists orders. }
                    how:
                      - id: lock
                        title: Lock
                        brief: One writer at a time.
                        participants: [ { id: a, label: A } ]
                        steps: [ { from: a, to: a, label: take } ]
                    inside:
                      brief: Inside the api.
                      nodes:
                        - { id: handler, kind: service, brief: Parses the request. }
                edges:
                  - { from: client, to: api }
                flows:
                  - { id: requests, label: Requests, brief: Customers list their orders., from: client, steps: [ { call: api } ] }
                """)
            check(diagnostics.isEmpty, "diagnostics: \(diagnostics)")
            guard let manifest, let api = manifest.root.node("api") else { check(false, "did not decode"); return }
            check(manifest.root.brief == "The root level in one line.", "level brief")
            check(api.brief == "Owns orders." && api.doc == "Fails when Postgres refuses writes.", "node brief")
            check(api.ops.first?.brief == "Lists orders.", "op brief")
            check(api.how.first?.brief == "One writer at a time.", "mechanism brief")
            check(api.inside?.brief == "Inside the api.", "inside level brief")
            check(api.inside?.node("handler")?.brief == "Parses the request.", "inner node brief")
            check(manifest.root.flow("requests")?.brief == "Customers list their orders.", "flow brief")
        },
        CheckCase(name: "brief warns about a long doc, narration or summary without one") {
            let long = paragraph(400)
            let (_, diagnostics) = parse("""
                narration: "\(long)"
                nodes:
                  - id: api
                    kind: service
                    doc: "\(long)"
                    ops:
                      - { id: get, kind: http, label: GET /orders, doc: "\(long)" }
                      - { id: put, kind: http, label: PUT /orders, brief: Saves an order., doc: "\(long)" }
                    how:
                      - id: lock
                        title: Lock
                        summary: "\(long)"
                        participants: [ { id: a, label: A } ]
                        steps: [ { from: a, to: a, label: take } ]
                    inside:
                      nodes:
                        - { id: handler, kind: service, doc: "\(long)" }
                        - { id: tidy, kind: service, brief: Parses the request., doc: "\(long)" }
                  - { id: short, kind: service, doc: "One line on what it does.\\nOne gotcha.\\nOne number." }
                  - { id: sticky, kind: note, doc: "\(long)" }
                """)
            let warned = Set(diagnostics.filter { $0.severity == .warning && $0.message.contains("add a one-line brief:") }.compactMap(\.path))
            let expected: Set<String> = ["narration", "nodes.api.doc", "nodes.api.ops.get.doc", "nodes.api.how.lock.summary",
                                         "nodes.api.inside.nodes.handler.doc"]
            check(warned == expected, "warned at \(warned.sorted()), expected \(expected.sorted())")
            check(diagnostics.count == expected.count, "other diagnostics: \(diagnostics)")
            check(diagnostics.first { $0.path == "nodes.api.doc" }?.message.hasPrefix("doc is 400 characters") == true,
                  "message does not say how long: \(diagnostics.first { $0.path == "nodes.api.doc" }?.message ?? "")")
            let bullets = parse("nodes: [ { id: api, kind: service, doc: \"- a\\n- b\\n- c\\n- d\" } ]").1
            check(bullets.contains { $0.path == "nodes.api.doc" && $0.message.hasPrefix("doc is 4 lines") }, "four bullets: \(bullets)")
        },
        CheckCase(name: "brief warns about a brief that is long or on several lines") {
            let (_, diagnostics) = parse("""
                nodes:
                  - { id: client, kind: client, brief: "\(String(repeating: "word ", count: 30))" }
                  - { id: api, kind: service, brief: "one\\ntwo" }
                flows:
                  - { id: requests, from: client, brief: "\(String(repeating: "word ", count: 30))", steps: [ { call: api } ] }
                """)
            let paths = Set(diagnostics.filter { $0.severity == .warning && $0.message.hasPrefix("brief is") }.compactMap(\.path))
            check(paths == ["nodes.client.brief", "nodes.api.brief", "flows.requests.brief"], "warned at \(paths.sorted()): \(diagnostics)")
        },
    ]
}
