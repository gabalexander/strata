import Foundation
import StrataCore

// `strata ops <file|id> [--json]`: every operation per level and node, so an agent can review
// what it extracted from a codebase and which flow steps give each op live numbers.

/// One op as `strata ops --json` prints it. `level` is "" for the root, node ids joined by "/" for
/// deep dives, and `node#op` for an op's own `inside:` level.
struct OpListing: Encodable {
    struct Fact: Encodable { let key: String; let value: String }
    /// For an op of a node with `inside:`: the inner node of that deep dive it maps to (`InheritedOps`).
    struct DeepDive: Encodable {
        /// The inner node it talks to (or that serves it); nil when no rule matched.
        let peer: String?
        /// target, code, kind or label.
        let rule: String?
        /// The inner process whose code file is the op's.
        let performer: String?
        /// Flows of the deep dive whose steps name it.
        let flows: [String]
    }
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
    /// Flows that name this op, on the flow or on a step (its live numbers come from them).
    let flows: [String]
    let deepDive: DeepDive?
    let line: Int?

    init(level: String, node: String, op: StrataCore.Operation, flows: [String], deepDive: DeepDive? = nil) {
        self.level = level; self.node = node; id = op.id; kind = op.kind.rawValue
        direction = op.direction.rawValue; label = op.label; target = op.target; access = op.access?.rawValue
        tables = op.tables; indexes = op.indexes; tx = op.tx; locks = op.locks; query = op.query
        command = op.command; key = op.key; ttl = op.ttl; topic = op.topic; group = op.group; payload = op.payload
        method = op.method; path = op.path; request = op.request; response = op.response; streaming = op.streaming
        status = op.status; calls = op.calls; code = op.code; risks = op.risks; tags = op.tags
        facts = op.facts.map { Fact(key: $0.key, value: $0.value) }; doc = op.doc; detail = op.detail
        inside = op.inside != nil; self.flows = flows; self.deepDive = deepDive; line = op.line
    }
}

@MainActor
func listOps(_ args: Arguments) throws -> Int32 {
    let entry = try loadEntry(args.positional[0], command: "ops")
    guard let manifest = entry.manifest else { return 1 }
    var listings: [OpListing] = []
    var levels: [String] = []
    collectOps(manifest.root, path: "", into: &listings, levels: &levels)
    if args.flags.contains("--json") {
        try printJSON(listings)
    } else {
        print(renderOps(listings, levels: levels, manifest: manifest))
    }
    return 0
}

/// `levels`: every level path with ops of its own, or inherited from the node it is inside, in order.
private func collectOps(_ level: Level, path: String, into listings: inout [OpListing], levels: inout [String]) {
    let references = level.opReferences()
    let inheriting = path.split(separator: "/").last.map { !$0.contains("#") } ?? false
    if level.nodes.contains(where: { !$0.ops.isEmpty }) || inheriting { levels.append(path) }
    for node in level.nodes {
        let inherited = node.inside.map { InheritedOps(owner: node, ownerLevel: level, inside: $0) }
        let insideReferences = node.inside?.opReferences(owner: node) ?? [:]
        for op in node.ops {
            let deepDive = inherited?.entry(op.id).map { entry in
                OpListing.DeepDive(peer: entry.peer, rule: entry.rule?.rawValue, performer: entry.performer,
                                   flows: insideReferences["\(InheritedOps.ownerKey)/\(op.id)"] ?? [])
            }
            listings.append(OpListing(level: path, node: node.id, op: op, flows: references["\(node.id)/\(op.id)"] ?? [],
                                      deepDive: deepDive))
        }
    }
    for node in level.nodes {
        let nodePath = path.isEmpty ? node.id : "\(path)/\(node.id)"
        if let inside = node.inside { collectOps(inside, path: nodePath, into: &listings, levels: &levels) }
        for op in node.ops {
            if let inside = op.inside { collectOps(inside, path: "\(nodePath)#\(op.id)", into: &listings, levels: &levels) }
        }
    }
}

private func renderOps(_ listings: [OpListing], levels: [String], manifest: Manifest) -> String {
    guard !listings.isEmpty else { return "No operations in \(manifest.id)." }
    var sections: [String] = []
    var inheritedCount = 0, mappedCount = 0
    for level in levels {
        let title = level.isEmpty ? "\(manifest.id) (root)" : "\(manifest.id) › \(level)"
        var rows = [["NODE", "OP", "KIND", "DIR", "TARGET", "LABEL", "DETAIL", "CODE", "FLOWS"]]
        for op in listings where op.level == level {
            rows.append([op.node, op.id, op.kind, op.direction, op.target ?? "–", op.label, opDetail(op),
                         op.code.isEmpty ? "–" : op.code.joined(separator: ", "),
                         op.flows.isEmpty ? "–" : op.flows.joined(separator: ", ")])
        }
        if rows.count > 1 { sections.append(title + "\n" + alignedTable(rows)) }
        // A deep dive: the ops of the node it is inside, by the inner node each talks to.
        let parts = level.split(separator: "/").map(String.init)
        guard let ownerID = parts.last, !ownerID.contains("#") else { continue }
        let parent = parts.dropLast().joined(separator: "/")
        let inherited = listings.filter { $0.level == parent && $0.node == ownerID && $0.deepDive != nil }
        guard !inherited.isEmpty else { continue }
        var mapping = [["OP", "KIND", "TARGET", "PEER", "RULE", "BY", "FLOWS"]]
        for op in inherited {
            let dive = op.deepDive
            let flows = dive?.flows ?? []
            mapping.append([op.id, op.kind, op.target ?? "–", dive?.peer ?? "–", dive?.rule ?? "–", dive?.performer ?? "–",
                            flows.isEmpty ? "–" : flows.joined(separator: ", ")])
        }
        let mapped = inherited.filter { $0.deepDive?.peer != nil }.count
        inheritedCount += inherited.count
        mappedCount += mapped
        sections.append("\(title): ops of \(ownerID) by the inner node each talks to, \(mapped) of \(inherited.count) mapped\n"
                        + alignedTable(mapping))
    }
    let nodes = Set(listings.map { "\($0.level)\u{0}\($0.node)" }).count
    let named = listings.filter { !$0.flows.isEmpty }.count
    let ownLevels = Set(listings.map(\.level)).count
    func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
    var summary = "\(count(listings.count, "op")) on \(count(nodes, "node")) in \(count(ownLevels, "level")); \(named) named by flows"
    if inheritedCount > 0 { summary += "; \(mappedCount) of \(inheritedCount) mapped into deep dives" }
    sections.append(summary)
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

func durationText(_ seconds: Double) -> String {
    func trimmed(_ value: Double) -> String { Value.number((value * 1000).rounded() / 1000).description }
    if seconds >= 60, seconds.truncatingRemainder(dividingBy: 60) == 0 { return "\(Int(seconds / 60))m" }
    return seconds >= 1 ? trimmed(seconds) + "s" : trimmed(seconds * 1000) + "ms"
}

func alignedTable(_ rows: [[String]]) -> String {
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
