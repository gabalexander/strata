import Foundation

/// Which op fields fit which kinds (docs/manifest.md, Operations: "Fields by kind").
enum OpFields {
    static let common: Set<String> = ["id", "kind", "label", "direction", "target", "doc", "code", "risks", "tags",
                                      "facts", "inside", "detail"]
    private static let data: Set<String> = ["query", "tables", "indexes", "access", "tx", "locks"]
    private static let endpoint: Set<String> = ["method", "path", "request", "response", "streaming", "status", "calls"]

    static let byKind: [OpKind: Set<String>] = [
        .sql: data,
        .search: data,
        .cache: ["command", "key", "ttl", "access"],
        // `calls` on a publish names the consume op that handles the message.
        .publish: ["topic", "key", "group", "payload", "calls"],
        .consume: ["topic", "key", "group", "payload"],
        .rpc: endpoint,
        .http: endpoint,
        .llm: endpoint,
        .call: endpoint,
        .storage: ["key", "path", "access", "method", "ttl", "payload"],
    ]

    static let all: Set<String> = byKind.values.reduce(common) { $0.union($1) }

    /// The kinds a kind-specific field is meant for, in declaration order ("sql or search").
    static func kinds(using key: String) -> String {
        let names = OpKind.allCases.filter { byKind[$0]?.contains(key) == true }.map(\.rawValue)
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " or " + names.last!
    }
}

extension Decode {
    static let streamingModes = ["unary", "server", "client", "bidi"]

    static func operation(_ field: Field) -> Operation? {
        guard field.mapping(OpFields.all) else { return nil }
        let id = field["id"].id(required: true)
        let kind = field["kind"].choice(OpKind.self, required: true)
        let label = field["label"].text(required: true, nonempty: true)
        guard let id, let kind else { return nil }
        var op = Operation(id: id, kind: kind, label: label ?? id)
        op.line = field.line
        op.target = field["target"].id()
        op.access = field["access"].choice(OpAccess.self)
        op.doc = field["doc"].text()
        op.code = field["code"].textList(orOne: true)
        op.risks = field["risks"].textList(orOne: true)
        op.tags = field["tags"].textList(orOne: true)
        op.query = field["query"].text()
        op.tables = field["tables"].textList(orOne: true)
        op.indexes = field["indexes"].textList(orOne: true)
        op.tx = field["tx"].bool()
        op.locks = field["locks"].text()
        op.command = field["command"].text()
        op.key = field["key"].anyText()
        op.ttl = field["ttl"].duration()
        op.topic = field["topic"].text()
        op.group = field["group"].text()
        op.payload = field["payload"].structuredText()
        op.method = field["method"].text()
        op.path = field["path"].text()
        op.request = field["request"].structuredText()
        op.response = field["response"].structuredText()
        op.streaming = field["streaming"].scalar { raw in
            guard streamingModes.contains(raw) else {
                let suggestion = closestKey(to: raw, in: streamingModes).map { "; did you mean '\($0)'?" } ?? ""
                throw InvalidValue("expected one of \(streamingModes.joined(separator: ", "))\(suggestion)")
            }
            return raw
        }
        op.status = field["status"].anyTextList()
        op.calls = field["calls"].scalar { try Syntax.opReference($0, qualified: true) }
        op.facts = facts(field["facts"])
        if field["inside"].present { op.inside = decodeLevel(field["inside"]) }
        op.detail = field["detail"].id()
        if field["inside"].present, field["detail"].present { field["detail"].diagnose("use either inside or detail for a deep dive") }
        op.direction = field["direction"].scalar { raw in
            guard let direction = OpDirection(rawValue: raw) else { throw InvalidValue("expected in or out") }
            return direction
        } ?? inferredDirection(kind: kind, target: op.target)
        return op
    }

    /// A consumer is inbound; otherwise an op with a target is outbound, and one without is something the node serves.
    static func inferredDirection(kind: OpKind, target: String?) -> OpDirection {
        if kind == .consume { return .inbound }
        return target == nil ? .inbound : .outbound
    }

    /// A mapping of fact names to scalar values, in source order.
    static func facts(_ field: Field) -> [(key: String, value: String)] {
        guard field.present else { return [] }
        guard let pairs = field.node?.fields else {
            field.diagnose("expected a mapping of fact names to values")
            return []
        }
        return pairs.compactMap { pair in field[pair.key].anyText().map { (key: pair.key, value: $0) } }
    }
}
