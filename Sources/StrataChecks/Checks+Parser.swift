import Foundation
import StrataCore

private let testSource = ManifestSource.file(URL(fileURLWithPath: "/checks/parser.yaml"))
private let header = """
strata: 1
id: test
title: Parser check
""" + "\n"

@MainActor func parserChecks() -> [CheckCase] {
    yamlChecks() + diagnosticChecks() + manifestChecks() + commandChecks() + glossaryChecks() + libraryChecks() + limitChecks()
        + opChecks()
}

@MainActor private func limitChecks() -> [CheckCase] {
    [
        CheckCase(name: "parser rejects excessive node counts") {
            for (param, count, limit) in [("replicas", "9223372036854775807", 64), ("concurrency", "100001", 100000),
                                          ("queue", "1000001", 1000000), ("capacity", "1000001", 1000000),
                                          ("prefetch", "100001", 100000)] {
                let (manifest, diagnostics) = load("nodes: [{ id: a, kind: service, \(param): \(count) }]")
                check(manifest == nil && diagnostics.contains {
                    $0.severity == .error && $0.path == "nodes.a.\(param)" && $0.message.contains(String(limit))
                }, "\(param) above \(limit) was not diagnosed: \(diagnostics)")
                check(load("nodes: [{ id: a, kind: service, \(param): \(limit) }]").0 != nil,
                      "\(param) at the limit was rejected")
            }
        },
        CheckCase(name: "parser rejects excessive flow rates and sends") {
            for rate in ["1000000000000/s", "600060/min", "every 99us"] {
                let (manifest, diagnostics) = load("""
                    nodes: [{ id: client, kind: client }]
                    flows: [{ id: input, from: client, rate: \(rate), steps: [] }]
                    """)
                check(manifest == nil && diagnostics.contains { $0.path == "flows.input.rate" && $0.message.contains("10000/s") },
                      "accepted excessive rate \(rate): \(diagnostics)")
            }
            for command in ["rate input 10001/s", "send input 10001"] {
                let (manifest, diagnostics) = load("""
                    nodes: [{ id: client, kind: client }]
                    flows: [{ id: input, from: client, rate: 10000/s, steps: [] }]
                    scenarios: [{ id: burst, setup: [\(command)] }]
                    """)
                check(manifest == nil && diagnostics.contains { $0.severity == .error && $0.message.contains("10000") },
                      "accepted command above the limit: \(command), \(diagnostics)")
            }
            check(ManifestParser.parseCommand("send input 10000") == .success(.send("input", 10000)),
                  "send at the limit was rejected")
            check(ManifestParser.parseCommand("rate input every 100us") == .success(.rate("input", .every(0.0001))),
                  "fixed arrivals at the limit were rejected")
        },
        CheckCase(name: "parser warns about zero-time publish cycles") {
            let template = """
                nodes:
                  - { id: a, kind: queue, latency: fixed 0ms }
                  - { id: b, kind: topic, latency: fixed 0ms }
                  - { id: first, kind: worker, latency: fixed 0ms }
                  - { id: second, kind: worker, latency: fixed 0ms }
                edges:
                  - { from: a, to: first, latency: fixed 0ms }
                  - { from: first, to: b, latency: fixed 0ms }
                  - { from: b, to: second, latency: fixed 0ms }
                  - { from: second, to: a, latency: fixed 0ms }
                flows:
                  - { id: ab, on: a, by: first, steps: [{ publish: b }] }
                  - { id: ba, on: b, by: second, steps: [{ work: DURATION }, { publish: a }] }
                """
            for duration in ["fixed 0ms", "fixed 1ms"] {
                let (manifest, diagnostics) = load(template.replacingOccurrences(of: "DURATION", with: duration))
                check(manifest != nil, "cycle fixture did not decode: \(diagnostics)")
                check(diagnostics.contains { $0.severity == .warning && $0.message.contains("zero-time publish cycle") }
                      == (duration == "fixed 0ms"), "incorrect cycle warning for \(duration): \(diagnostics)")
            }
        },
    ]
}

private func load(_ body: String, preamble: String = header) -> (Manifest?, [Diagnostic]) {
    ManifestParser.parse(preamble + body, source: testSource)
}

private func expectClean(_ result: (Manifest?, [Diagnostic])) -> Manifest? {
    check(result.0 != nil && result.1.isEmpty, "expected a clean manifest, got \(result.1)")
    return result.0
}

@MainActor private func finding(
    _ name: String, _ body: String, line: Int, path: String? = nil,
    _ message: String, severity: Diagnostic.Severity = .error, preamble: String = header
) -> CheckCase {
    CheckCase(name: "parser \(name)") {
        let (manifest, diagnostics) = load(body, preamble: preamble)
        check((manifest == nil) == (severity == .error), "unexpected load result: \(diagnostics)")
        check(diagnostics.contains {
            $0.severity == severity && $0.line == line && $0.path == path && $0.message.contains(message)
        }, "expected \(severity) on line \(line) at \(path ?? "<syntax>") containing '\(message)', got \(diagnostics)")
    }
}

@MainActor private func yamlChecks() -> [CheckCase] {
    [
        CheckCase(name: "parser YAML quotes, multiline flow, comments and URL fragments") {
            let manifest = expectClean(load(#"""
                # A comment before the level.
                layout: manual
                nodes:
                  - id: a
                    kind: postgres
                    label: 'It''s #1: a database'
                    doc: "line one\nline two\t\"quoted\" \u263a"
                    at: [
                      0.25,
                      -1.5, # trailing comment
                    ]
                    links: [
                      { label: "A: link # keep", url: https://example.com/a#fragment },
                      { label: "An 'inside' quote", note: "docs/Database: schema.md" }
                    ]
                  - { id: b, kind: postgres, tech: Custom } # remove this
                """#))
            let a = manifest?.root.node("a")
            check(a?.kind == .database && a?.tech == "postgres", "kind alias did not set tech")
            check(manifest?.root.node("b")?.tech == "Custom", "alias replaced explicitly set tech")
            check(a?.label == "It's #1: a database", "single quotes changed the label")
            check(a?.doc == "line one\nline two\t\"quoted\" ☺", "double-quoted escapes changed the text")
            check(a?.at == GridPoint(0.25, -1.5), "multiline position")
            check(a?.links.map(\.target) == [.url("https://example.com/a#fragment"), .note("docs/Database: schema.md")], "link targets")
        },
        CheckCase(name: "parser YAML block scalar chomping and folding") {
            let manifest = expectClean(load("""
                nodes:
                - id: a
                  kind: note
                  doc: |-
                    # This is text.
                    Two lines.

                - id: b
                  kind: note
                  doc: >+
                    A paragraph
                    wrapped over lines.

                    A new paragraph.
                      More indented.
                    Done.


                - id: c
                  kind: note
                  doc: |
                    Clip to one newline.

                """ + "\n"))
            check(manifest?.root.node("a")?.doc == "# This is text.\nTwo lines.", "literal strip or indentless sequence")
            check(manifest?.root.node("b")?.doc == "A paragraph wrapped over lines.\nA new paragraph.\n  More indented.\nDone.\n\n\n", "folded keep")
            check(manifest?.root.node("c")?.doc == "Clip to one newline.\n", "literal clip")
        },
        CheckCase(name: "parser JSON objects preserve source order and Unicode escapes") {
            let text = #"""
                {
                  "strata":1, "id":"json", "title":"\uD83D\uDE80",
                  "nodes":[
                    {"id":"z", "kind":"note", "doc":"quote: \"#\""},
                    {"id":"a", "kind":"note", "at":[-2,1]}
                  ]
                }
                """#
            let result = expectClean(load(text, preamble: ""))
            check(result?.title == "🚀", "JSON surrogate pair")
            check(result?.root.nodes.map(\.id) == ["z", "a"], "JSON array order")
            check(result?.root.node("z")?.line == 4 && result?.root.node("a")?.line == 5, "JSON node lines")
            check(result?.root.node("z")?.doc == "quote: \"#\"", "JSON escapes or comments")
        },
        finding("tab indentation", "nodes:\n\t- { id: a, kind: note }", line: 5, "use spaces"),
        finding("mapping indentation", "nodes:\n  - id: a\n     kind: note", line: 6, "bad indentation"),
        finding("unclosed flow sequence", "nodes: [\n  {id: a, kind: note}", line: 4, "expected ']'"),
        finding("unclosed flow mapping", "nodes: [{id: a]", line: 4, "expected '}'"),
        finding("missing flow comma", "nodes: [{id: a kind: note}]", line: 4, "quote values"),
        finding("unclosed quote", "nodes: []\nnotes: \"hi", line: 5, "unclosed quoted scalar"),
        finding("bad escape", #"notes: "\q""#, line: 4, "unknown escape"),
        finding("duplicate block key", "nodes: []\ntitle: Again", line: 5, "first defined on line 3"),
        finding("duplicate flow key", "{\n \"strata\":1,\n \"strata\":1\n}", line: 3, "duplicate key", preamble: ""),
        finding("anchor unsupported", "nodes: &list []", line: 4, "anchors, aliases, and tags"),
        finding("root mapping required", "[]", line: 1, "expected a mapping", preamble: ""),
        finding("unknown key reports key line", "nodes: [{id: a, kind: note, lable:\n   A}]", line: 4,
                path: "nodes.a.lable", "did you mean 'label'", severity: .warning),
    ]
}

@MainActor private func diagnosticChecks() -> [CheckCase] {
    let endpoints = "nodes: [{id: web, kind: client}, {id: api, kind: service}, {id: q, kind: queue}]\n"
    return [
        finding("manifest id", "strata: 1\nid: Bad!\ntitle: Check\nnodes: []", line: 2, path: "id", "invalid id", preamble: ""),
        finding("version", "strata: 2\nid: check\ntitle: Check\nnodes: []", line: 1, path: "strata", "use strata: 1", preamble: ""),
        finding("missing nodes", "", line: 1, path: "nodes", "required list"),
        finding("wrong list type", "nodes: {}", line: 4, path: "nodes", "expected a list"),
        finding("node kind", "nodes: [{id: a, kind: servce}]", line: 4, path: "nodes.a.kind", "did you mean 'service'"),
        finding("duration unit", "nodes: [{id: a, kind: service, latency: 20}]", line: 4, path: "nodes.a.latency", "write 20ms, not 20"),
        finding("bad interval", "nodes: [{id: a, kind: service, latency: 40ms..20ms}]", line: 4, path: "nodes.a.latency", "ascending"),
        finding("bad probability", "nodes: [{id: a, kind: cache, hitRate: 101%}]", line: 4, path: "nodes.a.hitRate", "probability"),
        finding("coordinate type", "nodes: [{id: a, kind: service, at: [0, right]}]", line: 4, path: "nodes.a.at[1]", "finite number"),
        finding("edge endpoint", endpoints + "edges: [{from: web, to: ap}]", line: 5, path: "edges[0].to", "did you mean 'api'"),
        finding("duplicate edge", endpoints + "edges:\n - {from: web, to: api}\n - {from: web, to: api}", line: 7,
                path: "edges[1]", "duplicate edge"),
        finding("missing group", "nodes: [{id: a, kind: service, group: vpc}]", line: 4, path: "nodes.a.group", "unknown group"),
        finding("missing parent group", endpoints + "groups: [{id: mygroup, parent: vpc}]", line: 5, path: "groups.mygroup.parent", "unknown parent"),
        finding("group parent cycle", endpoints + "groups: [{id: a, parent: b}, {id: b, parent: a}]", line: 5, path: "groups.a.parent", "cycle"),
        finding("duplicate node id", "nodes:\n - {id: a, kind: service}\n - {id: a, kind: queue}", line: 6, path: "nodes.a.id", "first defined on line 5"),
        finding("duplicate flow id", endpoints + "flows:\n - {id: f, from: web}\n - {id: f, from: web}", line: 7,
                path: "flows.f.id", "duplicate id"),
        finding("duplicate term id", endpoints + "terms:\n - {id: t, term: First, short: Text}\n - {id: t, term: Second, short: Text}", line: 7,
                path: "terms.t.id", "duplicate id"),
        finding("nested level reference", """
            nodes:
              - id: a
                kind: service
                inside:
                  nodes: [{id: x, kind: port}]
                  flows: [{id: f, from: x, steps: [{call: a}]}]
            """, line: 9, path: "nodes.a.inside.flows.f.steps[0].call", "unknown node"),
        finding("missing flow origin", endpoints + "flows: [{id: f}]", line: 5, path: "flows.f", "a flow needs"),
        finding("invalid source", endpoints + "flows: [{id: f, from: api}]", line: 5, path: "flows.f.from", "must be a source or port"),
        finding("invalid buffer", endpoints + "flows: [{id: f, on: api, by: api}]", line: 5, path: "flows.f.on", "must be a buffer"),
        finding("invalid consumer", endpoints + "flows: [{id: f, on: q, by: web}]", line: 5, path: "flows.f.by", "must be a server"),
        finding("missing consumer", endpoints + "flows: [{id: f, on: q}]", line: 5, path: "flows.f.by", "needs by"),
        finding("two origins", endpoints + "flows: [{id: f, from: web, on: q, by: api}]", line: 5, path: "flows.f.on", "cannot have both"),
        finding("consumer rate", endpoints + "flows: [{id: f, on: q, by: api, rate: 1/s}]", line: 5, path: "flows.f.rate", "cannot have a rate"),
        finding("invalid rate duration", endpoints + "flows: [{id: f, from: web, rate: every 0ms}]", line: 5, path: "flows.f.rate", "must be positive"),
        finding("step wrong action", endpoints + "flows: [{id: f, from: web, steps: [{call: api, work: 1ms}]}]", line: 5,
                path: "flows.f.steps[0]", "exactly one step"),
        finding("wrong call role", endpoints + "flows: [{id: f, from: web, steps: [{call: q}]}]", line: 5,
                path: "flows.f.steps[0].call", "must be a server"),
        finding("wrong publish role", endpoints + "flows: [{id: f, from: web, steps: [{publish: api}]}]", line: 5,
                path: "flows.f.steps[0].publish", "must be a buffer"),
        finding("miss requires cache", endpoints + "flows: [{id: f, from: web, steps: [{call: api, miss: []}]}]", line: 5,
                path: "flows.f.steps[0].miss", "only valid on calls to caches"),
        finding("recursive call path", endpoints + """
            flows:
              - id: f
                from: web
                steps:
                  - call: api
                    steps:
                      - parallel:
                          - call: api
            """, line: 12, path: "flows.f.steps[0].steps[0].parallel[0].call", "web -> api -> api"),
        finding("missing dlq", "nodes: [{id: q, kind: queue, dlq: missing}]", line: 4, path: "nodes.q.dlq", "unknown node"),
        finding("wrong dlq role", "nodes: [{id: q, kind: queue, dlq: a}, {id: a, kind: worker}]", line: 4, path: "nodes.q.dlq", "must be a buffer"),
        finding("unknown bind target", endpoints + "controls: [{label: Ack, bind: missing.ack, options: [manual, auto]}]", line: 5,
                path: "controls[0].bind", "unknown node"),
        finding("unknown bind parameter", endpoints + "controls: [{label: Errors, bind: api.erors, min: 0, max: 1, step: 0.1}]", line: 5,
                path: "controls[0].bind", "did you mean 'errors'"),
        finding("wrong option type", endpoints + "controls: [{label: Ack, bind: api.ack, options: [manual, 1]}]", line: 5,
                path: "controls[0].options[1]", "manual, auto"),
        finding("toggle requires bool", endpoints + "controls: [{label: Ack, bind: api.ack}]", line: 5, path: "controls[0].bind", "boolean"),
        finding("insight comparison operand", endpoints + """
            controls:
              - label: Errors
                bind: api.errors
                options: [0, 1]
                insights: [{when: "> many", text: More errors.}]
            """, line: 9, path: "controls[0].insights[0].when", "expected a number"),
        finding("unknown action reference", """
            nodes:
              - id: a
                kind: service
                actions:
                  - {label: Kill, do: ["kill missing"]}
            """, line: 8, path: "nodes.a.actions[0].do[0]", "unknown node"),
        finding("unknown scenario reference", endpoints + """
            scenarios:
              - id: s
                steps:
                  - at: 1s
                    do:
                      - kill api
                      - send missing
            """, line: 11, path: "scenarios.s.steps[0].do[1]", "unknown flow"),
        finding("malformed command", endpoints + #"scenarios: [{id: s, setup: ["kll api"]}]"#, line: 5, path: "scenarios.s.setup[0]", "did you mean 'kill'"),
        finding("missing command edge", endpoints + #"scenarios: [{id: s, setup: ["cut web api"]}]"#, line: 5, path: "scenarios.s.setup[0]", "unknown edge"),
        finding("unknown glossary pack", endpoints + "glossaries: [rabittmq]", line: 5, path: "glossaries[0]", "did you mean 'rabbitmq'"),
        finding("unknown term", "nodes: [{id: a, kind: service, term: missing}]", line: 4, path: "nodes.a.term", "unknown term", severity: .warning),
        finding("implicit edge warning", endpoints + "flows: [{id: f, from: web, steps: [{call: api}]}]", line: 5,
                path: "flows.f.steps[0].call", "implicit edge", severity: .warning),
        finding("consumer edge warning", endpoints + "flows: [{id: f, on: q, by: api}]", line: 5,
                path: "flows.f.by", "implicit edge", severity: .warning),
        finding("position collision", "nodes: [{id: a, kind: service, at: [1, 0]}, {id: b, kind: service, at: [1, 0]}]", line: 4,
                path: "nodes.b.at", "share the same position", severity: .warning),
        finding("JSON field line", """
            {
              "strata":1,"id":"check","title":"Check",
              "nodes":[{"id":"a","kind":"service","latency":
                20}]
            }
            """, line: 4, path: "nodes.a.latency", "write 20ms, not 20", preamble: ""),
    ]
}

@MainActor private func manifestChecks() -> [CheckCase] {
    [
        CheckCase(name: "parser validates every bundled example") {
            let directory = try requiredResource("Examples")
            let library = Library(builtIn: directory, dirs: [])
            check(library.entries.contains { $0.id == "checkout" }, "missing checkout")
            for entry in library.entries {
                check(entry.manifest != nil && entry.diagnostics.isEmpty, "\(entry.url.lastPathComponent): \(entry.diagnostics)")
            }
            let fixture = Fixtures.checkout
            let parsed = library.manifest("checkout")
            check(parsed?.root.nodes.map(\.id) == fixture.root.nodes.map(\.id), "fixture nodes")
            check(parsed?.root.flows.map(\.id) == fixture.root.flows.map(\.id), "fixture flows")
            check(parsed?.level(at: ["orders"])?.nodes.map(\.id) == fixture.level(at: ["orders"])?.nodes.map(\.id), "fixture deep dive")
        },
        CheckCase(name: "parser manifest reference YAML fences") {
            let fences = try referenceFences()
            check(fences.count >= 11, "missing manifest reference fences: \(fences.count)")
            for (index, snippet) in fences.enumerated() {
                let input = specManifest(snippet)
                let (manifest, diagnostics) = load(input, preamble: "")
                check(manifest != nil && diagnostics.allSatisfy { $0.severity == .warning && $0.message.contains("implicit edge") },
                      "reference fence \(index + 1): \(diagnostics)")
            }
        },
        CheckCase(name: "parser automatic checkout layout and longest path") {
            let spec = try referenceFences()[0]
            let text = spec.replacingOccurrences(of: #", at: \[[^\]]*\]"#, with: "", options: .regularExpression)
            guard let a = expectClean(load(text, preamble: "")), let b = expectClean(load(text, preamble: "")) else { return }
            let positions = a.root.nodes.compactMap(\.at)
            check(positions.count == a.root.nodes.count && Set(positions).count == a.root.nodes.count, "positions are missing or collide")
            check(a.root.nodes.map(\.at) == b.root.nodes.map(\.at), "layout is not deterministic")
            let columns = ["web", "api", "orders", "events", "mailer"].compactMap { a.root.node($0)?.at?.x }
            check(columns.count == 5 && zip(columns, columns.dropFirst()).allSatisfy { $0 < $1 } && columns.first == 0,
                  "checkout should run web, api, orders, events, mailer left to right: \(columns)")
            for edge in a.root.edges {
                check((a.root.node(edge.from)?.at?.x ?? 10) < (a.root.node(edge.to)?.at?.x ?? 0), "backwards hop: \(edge.id)")
            }
        },
        CheckCase(name: "parser layout fits around fixed nodes and puts notes below") {
            let (manifest, diagnostics) = load("""
                layout: manual
                nodes:
                  - {id: src, kind: client, at: [0, 2]}
                  - {id: a, kind: service, at: [1, 2]}
                  - {id: b, kind: service}
                  - {id: annotation, kind: note}
                  - {id: inner, kind: service, inside: {nodes: [{id: inner-note, kind: note}]}}
                flows: [{id: f, from: src, steps: [{parallel: [{call: a}, {call: b}]}]}]
                """)
            check(diagnostics.count == 2 && diagnostics.allSatisfy { $0.severity == .warning }, "unexpected findings: \(diagnostics)")
            guard let manifest else { return }
            check(manifest.root.edges.map(\.implicit) == [true, true], "implicit edges missing")
            check(manifest.root.node("a")?.at == GridPoint(1, 2) && manifest.root.node("src")?.at == GridPoint(0, 2), "explicit nodes moved")
            check(manifest.root.node("b")?.at?.x == 1 && manifest.root.node("b")?.at != GridPoint(1, 2), "branch overlapped an explicit node")
            let noteRow = manifest.root.node("annotation")?.at?.y ?? -.infinity
            check(manifest.root.nodes.filter { $0.kind != .note }.allSatisfy { ($0.at?.y ?? .infinity) < noteRow }, "note does not sit below the diagram")
            check(manifest.level(at: ["inner"])?.node("inner-note")?.at == GridPoint(0, 0), "inside layout missing")
        },
        CheckCase(name: "parser layout reduces crossings and handles declared cycles") {
            let manifest = expectClean(load("""
                nodes:
                  - {id: a, kind: client, at: [0, 0]}
                  - {id: b, kind: client, at: [0, 1]}
                  - {id: d, kind: service}
                  - {id: c, kind: service}
                  - {id: e, kind: service}
                  - {id: f, kind: service}
                edges: [{from: a, to: c}, {from: b, to: d}, {from: e, to: f}, {from: f, to: e}]
                """))
            check(manifest?.root.node("c")?.at?.y ?? 99 < manifest?.root.node("d")?.at?.y ?? -99, "barycenter failed to uncross ordered edges")
            check(manifest?.root.node("e")?.at != nil && manifest?.root.node("f")?.at != nil, "cycle stopped layout")
        },
        CheckCase(name: "parser decodes distributions, conditions, effects and controls") {
            let manifest = expectClean(load("""
                nodes:
                  - {id: web, kind: user}
                  - {id: api, kind: service, latency: p50 20ms p99 400ms, timeout: 500us, errors: 20%, async: true}
                  - {id: queue, kind: rabbitmq, ttl: 2m, capacity: 2, overflow: drop-oldest}
                edges: [{from: web, to: api, latency: fixed 20ms, loss: 0.1}, {from: api, to: queue}]
                flows:
                  - id: web
                    from: web
                    rate: 600/min
                    steps:
                      - call: api
                        p: 30%
                        timeout: 2s
                        retries: 0
                        backoff: 20ms
                        breaker: {failures: 3, cooldown: 3s}
                        optional: true
                        steps:
                          - parallel:
                              - {work: exp 10ms}
                              - {publish: queue}
                controls:
                  - {label: Up, bind: api.up}
                  - label: Rate
                    bind: web.rate
                    options: [10, every 2s, manual]
                    insights:
                      - {when: 1..10, text: Some traffic., effects: [{metric: throughput, dir: flat}]}
                      - {text: Otherwise.}
                """))
            check(manifest?.root.node("api")?.params.latency == .lognormal(p50: 0.02, p99: 0.4), "lognormal")
            check(manifest?.root.node("queue")?.params.ttl == 120, "minutes")
            check(manifest?.root.flow("web")?.rate == .perSecond(10), "per-minute rate")
            check(manifest?.root.flow("web")?.steps.first?.p == 0.3, "step probability")
            check(manifest?.root.flow("web")?.steps.first?.breaker == Breaker(failures: 3, cooldown: 3), "circuit breaker")
            check(manifest?.root.controls.first?.input == .toggle, "toggle")
            check(manifest?.root.controls.last?.insights.first?.when == .between(1, 10), "range condition")
        },
        CheckCase(name: "parser note embeds") {
            for input in ["view: orders/handler", "view: [orders, handler]"] {
                let (embed, diagnostics) = ManifestParser.parseEmbed("sim: checkout\n" + input + "\nscenario: outage\nheight: 320\nautoplay: false", note: "Notes/a.md", index: 2)
                if case .library("checkout")? = embed?.target {} else { check(false, "library target") }
                check(diagnostics.isEmpty && embed?.view == ["orders", "handler"] && embed?.scenario == "outage" && embed?.height == 320 && embed?.autoplay == false,
                      "library embed: \(diagnostics)")
            }
            let (inline, diagnostics) = ManifestParser.parseEmbed("nodes: [{id: in, kind: port}]\nheight: 500", note: "Notes/a.md", index: 2)
            if case .inline(let manifest)? = inline?.target {
                check(manifest.id == "Notes/a.md#2" && manifest.root.node("in")?.at != nil && inline?.height == 500 && diagnostics.isEmpty, "inline defaults")
                check(manifest.title == "Diagram in a", "inline title names the note: \(manifest.title)")
            } else {
                check(false, "inline target: \(diagnostics)")
            }
            let (_, errors) = ManifestParser.parseEmbed("sim: checkout\nview: orders//handler", note: "a", index: 0)
            check(errors.first?.path == "view" && errors.first?.line == 2, "embed path diagnostic")
        },
    ]
}

func requiredResource(_ name: String) throws -> URL {
    guard let url = StrataResources.url(name) else { throw CocoaError(.fileNoSuchFile) }
    return url
}

func referenceFences() throws -> [String] {
    let text = try String(contentsOf: requiredResource("Docs/manifest.md"), encoding: .utf8)
    var fences: [String] = []
    var lines: [String]?
    for line in text.components(separatedBy: "\n") {
        if line == "```yaml" { lines = [] }
        else if line == "```", let captured = lines {
            fences.append(captured.joined(separator: "\n"))
            lines = nil
        } else {
            lines?.append(line)
        }
    }
    return fences
}

func specManifest(_ snippet: String) -> String {
    if snippet.hasPrefix("strata: 1") { return snippet }
    if let wrapped = howSpecFence(snippet) { return wrapped }
    if snippet.hasPrefix("enums:") { return enumSpecManifest(snippet) }
    if snippet.hasPrefix("journeys:") { return journeySpecManifest(snippet) }
    // The node and step field catalogs contain ellipses and mutually exclusive alternatives.
    let text = snippet.replacingOccurrences(of: "[...]", with: "[]").components(separatedBy: "\n")
        .filter { !$0.contains("inside: {...}") }.joined(separator: "\n")
    let nodes = """
        nodes:
          - {id: web, kind: client}
          - {id: api, kind: gateway}
          - {id: orders, kind: cache}
          - {id: order-events, kind: topic}
          - {id: mailer, kind: worker}
          - {id: inventory, kind: service}
          - {id: pricing, kind: service}
          - {id: db, kind: database}
          - {id: db-replica, kind: database}
        """ + "\n"
    let source = "flows: [{id: place-order, from: web}]\n"
    let term = "terms: [{id: grpc, term: gRPC, short: RPC}, {id: prefetch, term: Prefetch, short: Buffer}]\n"
    func indent(_ text: String, _ width: Int) -> String {
        text.components(separatedBy: "\n").map { String(repeating: " ", count: width) + $0 }.joined(separator: "\n")
    }
    if text.hasPrefix("  - id: orders") { return header + "nodes:\n" + text }
    if text.hasPrefix("- id: orders"), text.contains("\n  ops:") {
        // The operations example: the nodes its ops target, and the inbound op its rpc call reaches.
        return header + "nodes:\n" + indent(text, 2) + """

              - {id: db, kind: database}
              - {id: cache, kind: cache}
              - {id: events, kind: topic}
              - id: payments
                kind: service
                ops: [{id: charge, kind: rpc, label: Charge card, method: payments.v1.Payments/Charge}]
            edges:
              - {from: orders, to: db}
              - {from: orders, to: cache}
              - {from: orders, to: events}
              - {from: orders, to: payments}
            """
    }
    if text.hasPrefix("- id: db"), text.contains("\n  schema:") {
        // The data example: a database with tables and a service with an entity assembled from them.
        return header + "nodes:\n" + indent(text, 2)
    }
    if text.hasPrefix("- call:"), text.contains("op: insert-order") {
        // A step that names an op of the calling node.
        return header + """
            nodes:
              - {id: web, kind: client}
              - id: orders
                kind: service
                ops: [{id: insert-order, kind: sql, target: db, label: INSERT order, query: "INSERT INTO orders (id) VALUES ($1)"}]
              - {id: db, kind: database}
            edges: [{from: web, to: orders}, {from: orders, to: db}]
            flows:
              - id: place-order
                from: web
                steps:
                  - call: orders
                    steps:

            """ + indent(text, 10)
    }
    if text.hasPrefix("- id: orders") {
        return header + "groups: [{id: backend}]\n" + term + "nodes:\n" + indent(text, 2) + "\n  - {id: dead-letters, kind: queue}"
    }
    if text.hasPrefix("- from:") { return header + nodes + "edges:\n" + indent(text, 2) }
    if text.hasPrefix("- call:") {
        return header + nodes + "flows:\n  - id: place-order\n    from: web\n    steps:\n" + indent(text, 6)
    }
    if text.hasPrefix("actions:") { return header + nodes + "  - id: control\n    kind: service\n" + indent(text, 4) }
    if text.hasPrefix("controls:") { return header + nodes + source + term + text }
    if text.hasPrefix("scenarios:") { return header + nodes + source + text }
    return header + nodes + text
}

@MainActor private func commandChecks() -> [CheckCase] {
    let commands: [(String, Command)] = [
        ("kill db", .kill("db")), ("restore db", .restore("db")), ("slow db 10", .slow("db", 10)),
        ("fail payments 50%", .fail("payments", 0.5)), ("scale orders 4", .scale("orders", 4, relative: false)),
        ("scale orders +1", .scale("orders", 1, relative: true)), ("scale orders -1", .scale("orders", -1, relative: true)),
        ("set mailer.prefetch 1", .set(Binding(.node("mailer"), "prefetch"), .number(1))),
        ("set mailer.ack auto", .set(Binding(.node("mailer"), "ack"), .string("auto"))),
        ("set api.latency fixed 10ms", .set(Binding(.node("api"), "latency"), .string("fixed 10ms"))),
        ("rate place-order 50/s", .rate("place-order", .perSecond(50))), ("rate place-order every 2s", .rate("place-order", .every(2))),
        ("send place-order", .send("place-order", 1)), ("send place-order 4", .send("place-order", 4)),
        ("cut a b", .cut("a", "b")), ("heal a b", .heal("a", "b")), ("delay a b 20ms", .delay("a", "b", 0.02)),
        ("redirect db standby", .redirect("db", "standby")), ("unredirect db", .unredirect("db")), ("purge q", .purge("q")),
        ("say Back:  writes resume.", .say("Back:  writes resume.")), ("pause", .pause),
    ]
    let invalid = [
        ("kill", "kill <node>"), ("pause now", "pause"), ("send orders 0", "positive request count"),
        ("fail api 1.1", "probability"), ("delay a b 20", "write 20ms, not 20"), ("set a.ack 1", "manual, auto"),
        ("set a.prfetch 1", "did you mean 'prefetch'"), ("slow api nan", "positive factor"), ("kill API", "invalid id"),
        ("restore db\nkill db", "one command per line"),
    ]
    return commands.map { text, expected in
        CheckCase(name: "parser command \(text)") {
            let parsed = try ManifestParser.parseCommand(text).get()
            check(parsed == expected, "expected \(expected), got \(parsed)")
            check(ManifestParser.parseCommand(" \t" + text + "  ") == .success(expected), "surrounding whitespace changed the command")
        }
    } + invalid.map { text, message in
        CheckCase(name: "parser invalid command \(text)") {
            if case .failure(let diagnostic) = ManifestParser.parseCommand(text) {
                check(diagnostic.message.contains(message), "expected '\(message)', got \(diagnostic)")
            } else {
                check(false, "invalid command parsed")
            }
        }
    }
}

@MainActor private func glossaryChecks() -> [CheckCase] {
    [
        CheckCase(name: "parser glossary packs, local precedence, and qualified lookup") {
            check(GlossaryPacks.available.contains("rabbitmq") && GlossaryPacks.available.contains("grpc"), "missing packs")
            var manifest = Fixtures.checkout
            manifest.glossaries = ["rabbitmq", "grpc"]
            manifest.terms = [Term(id: "prefetch", term: "Local prefetch", short: "Local")]
            let index = TermIndex(manifest: manifest)
            check(index.terms.first?.id == "prefetch" && index.term("prefetch")?.short == "Local", "local term did not take priority")
            check(index.term("rabbitmq/prefetch")?.short != "Local" && index.term("rabbitmq/prefetch") != nil, "qualified lookup")
            check(index.term("grpc/rpc")?.term == "RPC and stub", "second glossary pack missing")
            _ = expectClean(load("glossaries: [rabbitmq]\nnodes: [{id: q, kind: queue, term: rabbitmq/prefetch}]"))
        },
        CheckCase(name: "parser glossary word boundaries, escaping and repeat suppression") {
            var queue = Term(id: "queue", term: "queue", short: "")
            queue.match = ["queue", "queues"]
            let cpp = Term(id: "cpp", term: "C++", short: "")
            let text = "enqueue queueing queue-name pre-queue `queue` [[queues]] QUEUES then queue and C++."
            let matches = TermIndex(terms: [queue, cpp]).matches(in: text)
            check(matches.map { String(text[$0.range]) } == ["QUEUES", "C++"], "term match text")
            check(matches.map { $0.term.id } == ["queue", "cpp"], "term match identity")
        },
        CheckCase(name: "parser glossary longest overlapping phrase and first occurrence") {
            let queue = Term(id: "q", term: "queue", short: "")
            let readQueue = Term(id: "read", term: "read queue", short: "")
            var topic = Term(id: "topic", term: "Topic", short: "")
            topic.match = ["topic", "topic exchange"]
            let index = TermIndex(terms: [queue, readQueue, topic])
            let text = "``read ` queue`` [[topic]] Read queue, queue. Topic then topic exchange."
            let matches = index.matches(in: text)
            check(matches.map { String(text[$0.range]) } == ["Read queue", "Topic"], "longest or first occurrence did not win")
            let reverse = "queue backlog depth"
            let cross = TermIndex(terms: [Term(id: "a", term: "queue backlog", short: ""),
                                          Term(id: "b", term: "backlog depth", short: ""),
                                          Term(id: "c", term: "queue", short: "")])
            check(cross.matches(in: reverse).map { $0.term.id } == ["a"], "equal length should prefer the earlier phrase")
            let words = "sql read transaction"
            let later = TermIndex(terms: [Term(id: "a", term: "sql read", short: ""), Term(id: "b", term: "read transaction", short: "")])
            check(later.matches(in: words).map { $0.term.id } == ["b"], "longest should win even when it starts later")
        },
    ]
}

@MainActor private func libraryChecks() -> [CheckCase] {
    [
        CheckCase(name: "parser library override, duplicate ids, and nested detail diagnostics") {
            try withTempDirectory { root in
                let bundled = root.appendingPathComponent("bundle")
                let first = root.appendingPathComponent("first")
                let second = root.appendingPathComponent("second")
                for url in [bundled, first, second] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
                try writeManifest(header + "nodes: []", at: bundled.appendingPathComponent("test.yaml"))
                let winningFile = first.appendingPathComponent("b.yml")
                let duplicate = second.appendingPathComponent("a.json")
                try writeManifest("""
                    strata: 1
                    id: test
                    title: User copy
                    nodes:
                      - id: a
                        kind: service
                        inside:
                          nodes:
                            - id: b
                              kind: service
                              detail: absent
                    """, at: winningFile)
                try writeManifest(#"{"strata":1,"id":"test","title":"A sorts first","nodes":[]}"#, at: duplicate)
                let library = Library(builtIn: bundled, dirs: [first, second])
                check(library.entries.count == 2 && library.entries.allSatisfy { !$0.builtIn }, "user file did not override the bundle")
                check(library.manifest("test")?.title == "User copy", "later user file won")
                let loser = library.entries.first { $0.url.path == duplicate.path }
                check(loser?.manifest == nil && loser?.diagnostics.first?.message.contains(winningFile.path) == true, "duplicate diagnostic")
                let detail = library.entry("test")?.diagnostics.first
                check(detail?.severity == .warning && detail?.line == 11 && detail?.path == "nodes.a.inside.nodes.b.detail",
                      "detail warning: \(String(describing: detail))")
                try writeManifest(header.replacingOccurrences(of: "id: test", with: "id: absent") + "nodes: []", at: second.appendingPathComponent("detail.yaml"))
                library.reload()
                check(library.entry("test")?.diagnostics.isEmpty == true, "known detail still reports a warning")
            }
        },
        CheckCase(name: "parser library live reload picks up atomic saves, in-place writes, and removals") {
            try withTempDirectory { root in
                let url = root.appendingPathComponent("example.yaml")
                try writeManifest(header + "nodes: []", at: url)
                let library = Library(builtIn: nil, dirs: [root])
                library.startWatching()
                let originalRevision = library.revision
                try writeManifest(header.replacingOccurrences(of: "Parser check", with: "Atomic save") + "nodes: []", at: url, atomic: true)
                check(until { library.manifest("test")?.title == "Atomic save" }, "atomic replacement was missed")
                check(library.revision > originalRevision, "atomic replacement did not bump revision")

                let revisionAfterSave = library.revision
                try writeManifest(header.replacingOccurrences(of: "Parser check", with: "Direct save") + "nodes: []", at: url)
                check(until { library.manifest("test")?.title == "Direct save" }, "in-place write was missed")
                check(library.revision > revisionAfterSave, "in-place write did not bump revision")

                try FileManager.default.removeItem(at: url)
                check(until { library.entry("test") == nil }, "removed file is still present")
            }
        },
        CheckCase(name: "parser library duplicate chooses free filenames and ids") {
            try withTempDirectory { root in
                let previous = ProcessInfo.processInfo.environment["STRATA_HOME"]
                setenv("STRATA_HOME", root.path, 1)
                defer {
                    if let previous { setenv("STRATA_HOME", previous, 1) } else { unsetenv("STRATA_HOME") }
                }
                let library = Library()
                check(library.duplicate("checkout")?.lastPathComponent == "checkout.yaml", "could not copy checkout")
                check(library.entry("checkout")?.builtIn == false, "copy did not override the bundled manifest")
                check(library.duplicate("checkout")?.lastPathComponent == "checkout-2.yaml", "duplicate did not choose a free path")
                check(library.entry("checkout-2")?.diagnostics.isEmpty == true &&
                      library.manifest("checkout-2")?.root.node("orders")?.canDeepDive == true, "renamed copy did not validate")
            }
        },
        CheckCase(name: "parser config decoding and defaults") {
            try withTempDirectory { root in
                let url = root.appendingPathComponent("config.yaml")
                let (defaults, missing) = ConfigLoader.load(url)
                check(defaults == StrataConfig() && missing.isEmpty, "missing config should use defaults")
                try writeManifest("""
                    vault: ~/Documents/Vault
                    simDirs: [~/extra]
                    hotkey: ctrl+shift+s
                    editor: "code -g"
                    menubar: false
                    hideFromScreenShare: false
                    """, at: url)
                let (config, diagnostics) = ConfigLoader.load(url)
                check(diagnostics.isEmpty && config.simDirs == ["~/extra"] && config.editor == "code -g" &&
                      !config.menubar && !config.hideFromScreenShare, "config fields: \(diagnostics)")
                check(config.vaultURL.path.hasSuffix("/Documents/Vault"), "vault tilde expansion")
                try writeManifest("menubar: nope\nhideFromScreenShar: true", at: url)
                let (_, errors) = ConfigLoader.load(url)
                check(errors.map(\.path) == ["menubar", "hideFromScreenShar"] && errors.map(\.line) == [1, 2], "config diagnostics")
            }
        },
    ]
}

private func withTempDirectory(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("strata-check-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

private func writeManifest(_ text: String, at url: URL, atomic: Bool = false) throws {
    try text.write(to: url, atomically: atomic, encoding: .utf8)
}

@MainActor private func until(_ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(4)
    while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    return condition()
}

// MARK: - Operations

/// A level for op diagnostics: `OPS` lands on line 12 (node `api`), `FLOWS` starts on line 15.
private func opsCase(_ ops: String, flows: String = "") -> String {
    """
    nodes:
      - {id: web, kind: client}
      - {id: db, kind: database}
      - {id: q, kind: queue}
      - {id: t, kind: topic}
      - {id: cache, kind: cache}
      - {id: archive, kind: database}
      - {id: pay, kind: service, ops: [{id: charge, kind: rpc, label: Charge}, {id: settle, kind: http, label: Settle, direction: out}]}
      - {id: api, kind: service, ops: [\(ops)]}
    edges: [{from: web, to: api}, {from: api, to: db}, {from: api, to: q}, {from: api, to: t}, {from: api, to: cache},
            {from: api, to: pay}]
    """ + (flows.isEmpty ? "" : "\n" + flows)
}

/// A one-line source flow from web whose steps are `steps`.
private func opsFlow(_ steps: String) -> String {
    "flows: [{id: f, from: web, steps: [\(steps)]}]"
}

@MainActor private func opChecks() -> [CheckCase] {
    let api = "nodes.api.ops"
    let step = "flows.f.steps[0]"
    let nested = "flows.f.steps[0].steps[0]"
    return [
        CheckCase(name: "parser decodes every op field, direction and fact order") {
            guard let manifest = expectClean(load("""
                nodes:
                  - {id: web, kind: client}
                  - {id: db, kind: database}
                  - {id: cache, kind: cache}
                  - {id: events, kind: topic}
                  - id: api
                    kind: service
                    ops:
                      - id: create
                        kind: http
                        label: POST /orders
                        method: POST
                        path: /orders
                        request: { sku: A-1, qty: 2, gift: false, note: "say \\"hi\\"" }
                        response: '{ "id": "o-1" }'
                        status: [201, "409 duplicate"]
                        code: api/routes.go:12
                        risks: one risk
                        facts: { zeta: 1, alpha: "two", mid: true }
                      - id: insert
                        kind: sql
                        target: db
                        label: INSERT order
                        access: read-write
                        tables: [orders, outbox]
                        indexes: orders_pkey
                        tx: true
                        locks: row
                        query: |
                          INSERT INTO orders VALUES ($1);
                        code: [a.go:1, b.go:2]
                        risks: [hot rows, lock waits]
                        tags: [write-path]
                        inside:
                          nodes: [{id: lock, kind: service}]
                      - { id: emit, kind: publish, target: events, label: OrderPlaced, topic: order-events, key: order_id, group: g, payload: { order_id: o-1, total: 4200 } }
                      - { id: listen, kind: consume, target: events, label: Listen, group: api }
                      - { id: listen-topic, kind: consume, label: Listen topic, topic: order-events }
                      - { id: hook, kind: http, label: Webhook, direction: out, method: POST }
                      - { id: served, kind: rpc, label: Served, streaming: server }
                      - { id: price, kind: cache, target: cache, label: GET price, command: GET, key: "price:{sku}", ttl: 5m, access: read }
                      - { id: deep, kind: rpc, label: Deep, detail: other-manifest }
                edges:
                  - {from: web, to: api}
                  - {from: api, to: db}
                  - {from: api, to: cache}
                  - {from: api, to: events}
                  - {from: events, to: api}
                flows:
                  - id: f
                    from: web
                    steps:
                      - call: api
                        op: create
                        steps:
                          - { call: db, op: insert }
                          - { publish: events, op: api/emit }
                  - { id: g, on: events, by: api, steps: [{ work: 1ms, op: listen }] }
                """)) else { return }
            guard let ops = manifest.root.node("api")?.ops else { check(false, "api has no ops"); return }
            func op(_ id: String) -> StrataCore.Operation? { ops.first { $0.id == id } }
            check(ops.map(\.id) == ["create", "insert", "emit", "listen", "listen-topic", "hook", "served", "price", "deep"], "op order: \(ops.map(\.id))")
            let directions = ops.map(\.direction.rawValue)
            check(directions == ["in", "out", "out", "in", "in", "out", "in", "out", "in"], "direction inference: \(directions)")
            let create = op("create")
            check(create?.kind == .http && create?.method == "POST" && create?.path == "/orders", "http fields")
            check(create?.request == #"{ "sku": "A-1", "qty": 2, "gift": false, "note": "say \"hi\"" }"#, "mapping request as JSON: \(create?.request ?? "nil")")
            check(create?.response == #"{ "id": "o-1" }"# && create?.status == ["201", "409 duplicate"], "response or status")
            check(create?.code == ["api/routes.go:12"] && create?.risks == ["one risk"], "code or risks as one string")
            check(create?.facts.map(\.key) == ["zeta", "alpha", "mid"] && create?.facts.map(\.value) == ["1", "two", "true"],
                  "facts lost their order: \(create?.facts.map { "\($0.key)=\($0.value)" } ?? [])")
            let insert = op("insert")
            check(insert?.target == "db" && insert?.access == .readWrite && insert?.tables == ["orders", "outbox"] &&
                  insert?.indexes == ["orders_pkey"] && insert?.tx == true && insert?.locks == "row", "sql fields")
            check(insert?.query == "INSERT INTO orders VALUES ($1);\n" && insert?.code.count == 2 &&
                  insert?.risks == ["hot rows", "lock waits"] && insert?.tags == ["write-path"], "sql text and lists")
            check(insert?.inside?.node("lock")?.at != nil, "op inside level was not decoded and laid out")
            let emit = op("emit")
            check(emit?.topic == "order-events" && emit?.key == "order_id" && emit?.group == "g" &&
                  emit?.payload == #"{ "order_id": "o-1", "total": 4200 }"#, "publish fields: \(emit?.payload ?? "nil")")
            check(op("listen")?.group == "api" && op("listen-topic")?.target == nil, "consume fields")
            check(op("served")?.streaming == "server", "streaming")
            let price = op("price")
            check(price?.ttl == 300 && price?.command == "GET" && price?.key == "price:{sku}" && price?.access == .read, "cache fields")
            check(op("deep")?.detail == "other-manifest" && op("deep")?.line != nil, "detail or line")
            let flow = manifest.root.flow("f")?.steps.first
            check(flow?.op == "create", "step op")
            if case .call(_, let inner, _)? = flow?.action {
                check(inner.map(\.op) == ["insert", "api/emit"], "nested step ops")
            } else {
                check(false, "flow step is not a call")
            }
            check(manifest.root.resolveOp("create", caller: "web", target: "api")?.node == "api", "resolve on the target")
            check(manifest.root.resolveOp("insert", caller: "api", target: "db")?.op.id == "insert", "resolve on the caller")
            check(manifest.root.resolveOp("api/emit", caller: nil, target: nil)?.op.kind == .publish, "resolve node/op")
            check(manifest.root.resolveOp("missing", caller: "api", target: "db") == nil, "resolved a missing op")
        },
        CheckCase(name: "parser op direction inference and override") {
            let cases: [(String, OpDirection)] = [
                ("{id: a, kind: http, label: A}", .inbound),
                ("{id: a, kind: rpc, label: A, target: pay}", .outbound),
                ("{id: a, kind: sql, label: A, target: db, query: \"SELECT 1\"}", .outbound),
                ("{id: a, kind: consume, label: A, target: q}", .inbound),
                ("{id: a, kind: consume, label: A, topic: jobs}", .inbound),
                ("{id: a, kind: http, label: A, direction: out}", .outbound),
                ("{id: a, kind: sql, label: A, direction: out, query: \"SELECT 1\"}", .outbound),
                ("{id: a, kind: publish, label: A, target: q}", .outbound),
            ]
            for (op, expected) in cases {
                let manifest = expectClean(load(opsCase(op)))
                check(manifest?.root.node("api")?.ops.first?.direction == expected, "\(op) should be \(expected.rawValue)")
            }
        },
        CheckCase(name: "parser resolves step ops on the caller, the target, and node/op") {
            let manifest = expectClean(load(opsCase(
                "{id: serve, kind: http, label: Serve}, {id: read, kind: sql, label: Read, target: db, query: \"SELECT 1\"}, {id: put, kind: publish, label: Put, target: q}",
                flows: opsFlow("{call: api, op: serve, steps: [{call: db, op: read}, {publish: q, op: put}, {call: pay, op: pay/charge}, {work: 1ms, op: serve}]}"))))
            check(manifest != nil, "valid step op references were rejected")
        },
        // Errors.
        finding("op duplicate id", opsCase("{id: a, kind: http, label: A}, {id: a, kind: http, label: B}"),
                line: 12, path: "\(api).a.id", "duplicate id 'a'"),
        finding("op unknown kind", opsCase("{id: a, kind: sqll, label: A}"), line: 12, path: "\(api).a.kind", "did you mean 'sql'"),
        finding("op label required", opsCase("{id: a, kind: sql, target: db}"), line: 12, path: "\(api).a.label", "required value is missing"),
        finding("op unknown target", opsCase("{id: a, kind: sql, label: A, target: dbb}"), line: 12, path: "\(api).a.target", "did you mean 'db'"),
        finding("op sql to a queue", opsCase("{id: a, kind: sql, label: A, target: q}"), line: 12, path: "\(api).a.target",
                "a sql op cannot target 'q', a queue; target a database or search node"),
        finding("op publish to a service", opsCase("{id: a, kind: publish, label: A, target: pay}"), line: 12, path: "\(api).a.target",
                "cannot target 'pay', a service; target a queue or topic"),
        finding("op rpc to a client", opsCase("{id: a, kind: rpc, label: A, target: web}"), line: 12, path: "\(api).a.target",
                "an rpc op cannot target 'web', a client"),
        finding("op calls syntax", opsCase("{id: a, kind: rpc, label: A, target: pay, calls: charge}"), line: 12, path: "\(api).a.calls",
                "use node/op"),
        finding("op calls unknown op", opsCase("{id: a, kind: rpc, label: A, target: pay, calls: pay/charg}"), line: 12,
                path: "\(api).a.calls", "unknown op 'charg' on 'pay'; did you mean 'charge'"),
        finding("op calls unknown node", opsCase("{id: a, kind: rpc, label: A, target: pay, calls: payy/charge}"), line: 12,
                path: "\(api).a.calls", "unknown node 'payy'"),
        finding("op streaming mode", opsCase("{id: a, kind: rpc, label: A, streaming: bidirectional}"), line: 12,
                path: "\(api).a.streaming", "expected one of unary, server, client, bidi"),
        finding("op access mode", opsCase("{id: a, kind: sql, label: A, target: db, access: rw}"), line: 12,
                path: "\(api).a.access", "expected one of read, write, read-write"),
        finding("op direction value", opsCase("{id: a, kind: http, label: A, direction: inbound}"), line: 12,
                path: "\(api).a.direction", "expected in or out"),
        finding("op inside and detail", opsCase("{id: a, kind: http, label: A, inside: {nodes: []}, detail: other}"), line: 12,
                path: "\(api).a.detail", "use either inside or detail"),
        finding("op ttl unit", opsCase("{id: a, kind: cache, label: A, target: cache, ttl: 300}"), line: 12,
                path: "\(api).a.ttl", "a duration needs a unit"),
        finding("op facts mapping", opsCase("{id: a, kind: http, label: A, facts: [a, b]}"), line: 12,
                path: "\(api).a.facts", "expected a mapping of fact names"),
        finding("op inside level", opsCase("{id: a, kind: http, label: A, inside: {nodes: [{id: x, kind: port}], flows: [{id: f, from: x, steps: [{call: nope}]}]}}"),
                line: 12, path: "\(api).a.inside.flows.f.steps[0].call", "unknown node 'nope'"),
        finding("step op unknown", opsCase("{id: a, kind: http, label: A}", flows: opsFlow("{call: api, op: nope}")), line: 15,
                path: "\(step).op", "unknown op 'nope' on 'web' or 'api'"),
        finding("step op suggestion", opsCase("{id: serve, kind: http, label: A}", flows: opsFlow("{call: api, op: serv}")), line: 15,
                path: "\(step).op", "did you mean 'serve'"),
        finding("step op unknown on node", opsCase("{id: a, kind: http, label: A}", flows: opsFlow("{call: pay, op: pay/nope}")), line: 15,
                path: "\(step).op", "unknown op 'nope' on 'pay'"),
        finding("step op unknown node", opsCase("{id: a, kind: http, label: A}", flows: opsFlow("{call: api, op: nobody/a}")), line: 15,
                path: "\(step).op", "unknown node 'nobody'"),
        finding("step op syntax", opsCase("{id: a, kind: http, label: A}", flows: opsFlow("{call: api, op: a/b/c}")), line: 15,
                path: "\(step).op", "invalid op reference"),
        // Warnings.
        finding("op unknown key", opsCase("{id: a, kind: sql, label: A, target: db, tabls: [x]}"), line: 12,
                path: "\(api).a.tabls", "did you mean 'tables'", severity: .warning),
        finding("op field for another kind", opsCase("{id: a, kind: publish, label: A, target: q, query: x}"), line: 12,
                path: "\(api).a.query", "'query' does not apply to a publish op; use it on sql or search ops", severity: .warning),
        finding("op cache to a database", opsCase("{id: a, kind: cache, label: A, target: db}"), line: 12, path: "\(api).a.target",
                "a cache op usually targets a cache; 'db' is a database", severity: .warning),
        finding("op http to a cache", opsCase("{id: a, kind: http, label: A, target: cache}"), line: 12, path: "\(api).a.target",
                "an http op usually targets a server", severity: .warning),
        finding("op own node", opsCase("{id: a, kind: rpc, label: A, target: api}"), line: 12, path: "\(api).a.target",
                "an op cannot target its own node", severity: .warning),
        finding("op without an edge", opsCase("{id: a, kind: sql, label: A, target: archive}"), line: 12, path: "\(api).a.target",
                "no edge connects 'api' and 'archive'", severity: .warning),
        finding("op inbound with a target", opsCase("{id: a, kind: http, label: A, target: pay, direction: in}"), line: 12,
                path: "\(api).a.direction", "an inbound op has no target", severity: .warning),
        finding("op sql without a target", opsCase("{id: a, kind: sql, label: A}"), line: 12, path: "\(api).a",
                "a sql op without a target reads as served by 'api'", severity: .warning),
        finding("op consume without a buffer", opsCase("{id: a, kind: consume, label: A}"), line: 12, path: "\(api).a",
                "a consume op names its buffer in target or topic", severity: .warning),
        finding("op calls from an inbound op", opsCase("{id: a, kind: http, label: A, calls: pay/charge}"), line: 12,
                path: "\(api).a.calls", "calls links an outbound op to the op it reaches; 'a' is inbound", severity: .warning),
        finding("op calls an outbound op", opsCase("{id: a, kind: http, label: A, target: pay, calls: pay/settle}"), line: 12,
                path: "\(api).a.calls", "'pay/settle' is an outbound op", severity: .warning),
        finding("op publish calls a non-consumer", opsCase("{id: a, kind: publish, label: A, target: q, calls: pay/charge}"), line: 12,
                path: "\(api).a.calls", "a publish reaches a consume op", severity: .warning),
        finding("op calls another node than its target", opsCase("{id: a, kind: rpc, label: A, target: pay, calls: api/b}, {id: b, kind: http, label: B}"),
                line: 12, path: "\(api).a.calls", "calls names an op on 'api' but the target is 'pay'", severity: .warning),
        finding("step op publish names a sql op", opsCase("{id: w, kind: sql, label: W, target: db}", flows: opsFlow("{call: api, steps: [{publish: q, op: w}]}")),
                line: 15, path: "\(nested).op", "'w' is a sql op; a publish step performs a publish op", severity: .warning),
        finding("step op call names a consume op", opsCase("{id: c, kind: consume, label: C, target: q}", flows: opsFlow("{call: api, steps: [{call: pay, op: c}]}")),
                line: 15, path: "\(nested).op", "'c' is a consume op, which a call step does not perform", severity: .warning),
        finding("step op targets another node", opsCase("{id: w, kind: sql, label: W, target: db}", flows: opsFlow("{call: api, steps: [{call: cache, op: w}]}")),
                line: 15, path: "\(nested).op", "'w' targets 'db' but this step calls 'cache'", severity: .warning),
        finding("step op publishes elsewhere", opsCase("{id: p, kind: publish, label: P, target: t}", flows: opsFlow("{call: api, steps: [{publish: q, op: p}]}")),
                line: 15, path: "\(nested).op", "'p' targets 't' but this step publishes to 'q'", severity: .warning),
        finding("step op inbound on a downstream call", opsCase("{id: e, kind: http, label: E}", flows: opsFlow("{call: api, steps: [{call: db, op: e}]}")),
                line: 15, path: "\(nested).op", "'e' is an inbound op of 'api'; name it on the step that calls 'api'", severity: .warning),
        finding("step op outbound op of the target", opsCase("{id: w, kind: sql, label: W, target: db}", flows: opsFlow("{call: api, op: w}")),
                line: 15, path: "\(step).op", "'w' is an outbound op of 'api'; name it on a step that 'api' performs", severity: .warning),
        CheckCase(name: "parser resolves flow ops on the consumer or the source") {
            let (manifest, diagnostics) = load(opsCase(
                "{id: serve, kind: http, label: Serve}, {id: jobs, kind: consume, label: Jobs, target: q}, {id: put, kind: publish, label: Put, target: q}",
                flows: """
                flows:
                  - {id: f, from: web, steps: [{call: api, steps: [{publish: q, op: put}]}]}
                  - {id: g, on: q, by: api, op: jobs}
                  - {id: h, on: q, by: api, op: api/jobs}
                """))
            check(diagnostics.allSatisfy { $0.message.contains("implicit edge 'q->api'") }, "flow ops: \(diagnostics)")
            check(manifest?.root.flow("g")?.op == "jobs" && manifest?.root.flow("h")?.op == "api/jobs", "flow op was not decoded")
        },
        finding("flow op unknown", opsCase("{id: jobs, kind: consume, label: Jobs, target: q}", flows: "flows: [{id: g, on: q, by: api, op: job}]"),
                line: 15, path: "flows.g.op", "unknown op 'job' on 'api'; did you mean 'jobs'"),
        finding("flow op on a consumer is not a consume op", opsCase("{id: w, kind: sql, label: W, target: db}", flows: "flows: [{id: g, on: q, by: api, op: w}]"),
                line: 15, path: "flows.g.op", "'w' is a sql op; a consumer flow performs a consume op", severity: .warning),
        finding("flow op consumes another buffer", opsCase("{id: c, kind: consume, label: C, target: t}", flows: "flows: [{id: g, on: q, by: api, op: c}]"),
                line: 15, path: "flows.g.op", "'c' consumes from 't' but this flow is on 'q'", severity: .warning),
        finding("flow op on another node", opsCase("{id: c, kind: consume, label: C, target: q}", flows: "flows: [{id: g, on: q, by: pay, op: api/c}]"),
                line: 15, path: "flows.g.op", "a consumer flow's op belongs to its consumer 'pay'", severity: .warning),
        finding("flow op consume on a source flow", opsCase("{id: c, kind: consume, label: C, target: q}", flows: "flows: [{id: f, from: web, op: api/c}]"),
                line: 15, path: "flows.f.op", "name it on a consumer flow", severity: .warning),
        CheckCase(name: "parser library warns about unknown op detail manifests") {
            try withTempDirectory { root in
                try writeManifest(header + """
                    nodes:
                      - id: a
                        kind: service
                        ops:
                          - { id: x, kind: http, label: X, detail: absent }
                          - id: y
                            kind: http
                            label: Y
                            inside:
                              nodes:
                                - id: b
                                  kind: service
                                  ops: [{ id: z, kind: http, label: Z, detail: missing }]
                    """, at: root.appendingPathComponent("test.yaml"))
                let library = Library(builtIn: nil, dirs: [root])
                let warnings = library.entry("test")?.diagnostics ?? []
                check(warnings.count == 2 && warnings.allSatisfy { $0.severity == .warning && $0.message.contains("unknown detail manifest") },
                      "op detail warnings: \(warnings)")
                check(warnings.map(\.path) == ["nodes.a.ops.x.detail", "nodes.a.ops.y.inside.nodes.b.ops.z.detail"] &&
                      warnings.map(\.line) == [8, 16], "op detail paths: \(warnings)")
                try writeManifest(header.replacingOccurrences(of: "id: test", with: "id: absent") + "nodes: []",
                                  at: root.appendingPathComponent("absent.yaml"))
                library.reload()
                check(library.entry("test")?.diagnostics.count == 1, "a known op detail still warns")
            }
        },
    ]
}
