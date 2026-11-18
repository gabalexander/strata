import Foundation
import StrataCore

// `strata ops <file|id> [--json]`: every operation per level and node, so an agent can review
// what it extracted from a codebase and which flow steps give each op live numbers.

/// One op as `strata ops --json` prints it. `level` is "" for the root, node ids joined by "/" for
/// deep dives, and `node#op` for an op's own `inside:` level.
struct OpListing: Encodable {
    struct Fact: Encodable { let key: String; let value: String }
    let level: String
    let node: String
    let id: String
    let kind: String
    let direction: String
    let label: String
    let target: String?
    let access: String?
    let tables: [String]
    let indexes: [String]
    let tx: Bool?
    let locks: String?
    let query: String?
    let command: String?
    let key: String?
    let ttl: Double?
    let topic: String?
    let group: String?
    let payload: String?
    let method: String?
    let path: String?
    let request: String?
    let response: String?
    let streaming: String?
    let status: [String]
    let calls: String?
    let code: [String]
    let risks: [String]
    let tags: [String]
    let facts: [Fact]
    let doc: String?
    let detail: String?
    let inside: Bool
    /// Flows with a step that names this op (its live numbers come from them).
    let flows: [String]
    let line: Int?

    init(level: String, node: String, op: StrataCore.Operation, flows: [String]) {
        self.level = level; self.node = node; id = op.id; kind = op.kind.rawValue
        direction = op.direction.rawValue; label = op.label; target = op.target; access = op.access?.rawValue
        tables = op.tables; indexes = op.indexes; tx = op.tx; locks = op.locks; query = op.query
        command = op.command; key = op.key; ttl = op.ttl; topic = op.topic; group = op.group; payload = op.payload
        method = op.method; path = op.path; request = op.request; response = op.response; streaming = op.streaming
        status = op.status; calls = op.calls; code = op.code; risks = op.risks; tags = op.tags
        facts = op.facts.map { Fact(key: $0.key, value: $0.value) }; doc = op.doc; detail = op.detail
        inside = op.inside != nil; self.flows = flows; line = op.line
    }
}

@MainActor
func listOps(_ args: Arguments) throws -> Int32 {
    let entry = try loadEntry(args.positional[0], command: "ops")
    guard let manifest = entry.manifest else { return 1 }
    var listings: [OpListing] = []
    collectOps(manifest.root, path: "", into: &listings)
    if args.flags.contains("--json") {
        try printJSON(listings)
    } else {
        print(renderOps(listings, manifest: manifest))
    }
    return 0
}

private func collectOps(_ level: Level, path: String, into listings: inout [OpListing]) {
    let references = stepReferences(level)
    for node in level.nodes {
        for op in node.ops {
            listings.append(OpListing(level: path, node: node.id, op: op, flows: references["\(node.id)/\(op.id)"] ?? []))
        }
    }
    for node in level.nodes {
        let nodePath = path.isEmpty ? node.id : "\(path)/\(node.id)"
        if let inside = node.inside { collectOps(inside, path: nodePath, into: &listings) }
        for op in node.ops {
            if let inside = op.inside { collectOps(inside, path: "\(nodePath)#\(op.id)", into: &listings) }
        }
    }
}

/// "node/op" → ids of the flows whose steps name that op, resolved as the engine does.
private func stepReferences(_ level: Level) -> [String: [String]] {
    var result: [String: [String]] = [:]
    func walk(_ steps: [Step], caller: String?, flow: String) {
        for step in steps {
            var target: String?
            switch step.action {
            case .call(let callee, let inner, let miss):
                target = callee
                walk(inner, caller: callee, flow: flow)
                walk(miss, caller: caller, flow: flow)
            case .publish(let buffer): target = buffer
            case .parallel(let branches): walk(branches, caller: caller, flow: flow)
            case .work: break
            }
            if let reference = step.op, let resolved = level.resolveOp(reference, caller: caller, target: target) {
                let key = "\(resolved.node)/\(resolved.op.id)"
                if result[key]?.contains(flow) != true { result[key, default: []].append(flow) }
            }
        }
    }
    for flow in level.flows { walk(flow.steps, caller: flow.from ?? flow.by, flow: flow.id) }
    return result
}

private func renderOps(_ listings: [OpListing], manifest: Manifest) -> String {
    guard !listings.isEmpty else { return "No operations in \(manifest.id)." }
    var levels: [String] = []
    for listing in listings where !levels.contains(listing.level) { levels.append(listing.level) }
    var sections: [String] = []
    for level in levels {
        var rows = [["NODE", "OP", "KIND", "DIR", "TARGET", "LABEL", "DETAIL", "CODE", "FLOWS"]]
        for op in listings where op.level == level {
            rows.append([op.node, op.id, op.kind, op.direction, op.target ?? "–", op.label, opDetail(op),
                         op.code.isEmpty ? "–" : op.code.joined(separator: ", "),
                         op.flows.isEmpty ? "–" : op.flows.joined(separator: ", ")])
        }
        sections.append((level.isEmpty ? "\(manifest.id) (root)" : "\(manifest.id) › \(level)") + "\n" + alignedTable(rows))
    }
    let nodes = Set(listings.map { "\($0.level)\u{0}\($0.node)" }).count
    let named = listings.filter { !$0.flows.isEmpty }.count
    func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
    sections.append("\(count(listings.count, "op")) on \(count(nodes, "node")) in \(count(levels.count, "level")); \(named) named by flow steps")
    return sections.joined(separator: "\n\n")
}

/// The kind-specific fields worth scanning: method and path, command and key, tables, topic, links.
private func opDetail(_ op: OpListing) -> String {
    let messaging = op.kind == "publish" || op.kind == "consume"
    var parts: [String] = []
    if let method = op.method { parts.append(method) }
    if let path = op.path { parts.append(path) }
    if let command = op.command { parts.append(command) }
    if let access = op.access { parts.append(access) }
    if !op.tables.isEmpty { parts.append(op.tables.joined(separator: ", ")) }
    if let topic = op.topic { parts.append(topic) }
    if let key = op.key { parts.append(messaging ? "key \(key)" : key) }
    if let group = op.group { parts.append("group \(group)") }
    if let ttl = op.ttl { parts.append("ttl \(durationText(ttl))") }
    if op.tx == true { parts.append("tx") }
    if let locks = op.locks { parts.append("locks \(locks)") }
    if let streaming = op.streaming, streaming != "unary" { parts.append("\(streaming) stream") }
    if let calls = op.calls { parts.append("→ \(calls)") }
    if op.inside { parts.append("+ inside") }
    if let detail = op.detail { parts.append("+ detail \(detail)") }
    return parts.isEmpty ? "–" : parts.joined(separator: " ")
}

private func durationText(_ seconds: Double) -> String {
    func trimmed(_ value: Double) -> String { Value.number((value * 1000).rounded() / 1000).description }
    if seconds >= 60, seconds.truncatingRemainder(dividingBy: 60) == 0 { return "\(Int(seconds / 60))m" }
    return seconds >= 1 ? trimmed(seconds) + "s" : trimmed(seconds * 1000) + "ms"
}

private func alignedTable(_ rows: [[String]]) -> String {
    let cleaned = rows.map { row in
        row.map { $0.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ") }
    }
    let widths = cleaned[0].indices.map { column in cleaned.map { $0[column].count }.max() ?? 0 }
    return cleaned.map { row in
        row.enumerated().map { index, cell in
            index == row.count - 1 ? cell : cell + String(repeating: " ", count: widths[index] - cell.count)
        }.joined(separator: "  ")
    }.joined(separator: "\n")
}
