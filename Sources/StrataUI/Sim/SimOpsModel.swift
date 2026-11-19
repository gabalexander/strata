import Foundation
import StrataCore

// Operations as the inspector, the stage and the palette see them (docs/manifest.md, Operations):
// who owns an op, what it talks to, which ops reach it through `calls:` or nested flow steps, and the
// short text each row shows. Pure values, built once per level.

/// One operation on one node of a level.
struct OpRef: Hashable, Sendable {
    let node: String
    let op: String
}

/// What the stage brightens for an operation: its node, what it talks to, the edges between, and the
/// `calls:` chain. Everything else is drawn dimmed.
struct StageHighlight: Equatable, Sendable {
    var nodes: Set<String> = []
    var edges: Set<String> = []
    /// Pressure overlays (SimPressureStage): a colour per node or edge in place of the accent.
    var tints: [String: StageTint] = [:]
    var edgeTints: [String: StageTint] = [:]
    /// Heat mode tints every node and dims nothing.
    var dimsRest = true
}

/// Inspector groups, in display order.
enum OpGroup: CaseIterable {
    case endpoints, consumes, queries, cache, publishes, calls

    var title: String {
        switch self {
        case .endpoints: "Endpoints"
        case .consumes: "Consumes"
        case .queries: "Queries"
        case .cache: "Cache"
        case .publishes: "Publishes"
        case .calls: "Calls"
        }
    }

    static func of(_ op: StrataCore.Operation) -> OpGroup {
        switch op.kind {
        case .consume: .consumes
        case .sql, .search: .queries
        case .cache: .cache
        case .publish: .publishes
        case .rpc, .http, .call, .storage, .llm: op.direction == .inbound ? .endpoints : .calls
        }
    }
}

struct SimOpsIndex {
    struct Entry {
        let node: Node
        let op: StrataCore.Operation
        /// The node this op talks to: its target, or for messages the buffer named by `topic`. For an
        /// inherited op, the inner node `InheritedOps` maps it to.
        let peer: String?
        /// An op of the node this deep-dive level is inside (`InheritedOps`): `node` is that owner,
        /// which isn't on this level, and the ref's node is `..`.
        var inherited = false
        /// The inner process whose code file is an inherited op's (who performs it).
        var performer: String?
        var ref: OpRef { OpRef(node: inherited ? InheritedOps.ownerKey : node.id, op: op.id) }
    }

    let level: Level
    /// The ops of the node this deep-dive level is inside, mapped onto it. nil at the root.
    let inheritance: InheritedOps?
    /// Every op of the level, in node then op order, then the inherited ops in op order.
    let all: [Entry]
    /// The inherited ops alone, in op order.
    let inherited: [Entry]
    private let byRef: [OpRef: Entry]
    /// Inherited ops named by flow steps: the hops (caller → callee) of each step that performs one.
    private(set) var hops: [OpRef: [Hop]] = [:]
    /// Each node's outgoing edges on this level (implicit flow edges included).
    private let outgoing: [String: Set<String>]
    /// Each node's incoming edges on this level.
    private let incoming: [String: [String]]

    struct Hop: Hashable {
        let from: String
        let to: String?
    }
    /// `calls:` reversed: the ops that reach an endpoint (or, for a publish, the consumer it feeds).
    private(set) var linkedCallers: [OpRef: [OpRef]] = [:]
    /// The op an op's `calls:` reaches (`Level.resolveCalls`).
    private(set) var linked: [OpRef: OpRef] = [:]
    /// From flows: the ops performed while handling this one (steps nested under a step that performs
    /// it, or the steps of a flow whose `op:` it is).
    private(set) var nested: [OpRef: [OpRef]] = [:]
    private(set) var nestedIn: [OpRef: [OpRef]] = [:]
    /// Flow ids that name this op, on the flow or on a step (`Level.opReferences`).
    let flows: [OpRef: [String]]

    init(level: Level, inherited inheritance: InheritedOps? = nil) {
        self.level = level
        self.inheritance = inheritance
        var entries: [Entry] = []
        for node in level.nodes {
            for op in node.ops { entries.append(Entry(node: node, op: op, peer: Self.peer(of: op, in: level))) }
        }
        let inherited = (inheritance?.entries ?? []).compactMap { mapped -> Entry? in
            guard let owner = inheritance?.owner else { return nil }
            return Entry(node: owner, op: mapped.op, peer: mapped.peer, inherited: true, performer: mapped.performer)
        }
        self.inherited = inherited
        entries += inherited
        all = entries
        byRef = Dictionary(entries.map { ($0.ref, $0) }, uniquingKeysWith: { first, _ in first })
        flows = Dictionary(level.opReferences(owner: inheritance?.owner).compactMap { key, ids in
            Self.ref(key).map { ($0, ids) }
        }, uniquingKeysWith: { first, _ in first })
        outgoing = level.edges.reduce(into: [:]) { $0[$1.from, default: []].insert($1.to) }
        incoming = level.edges.reduce(into: [:]) { $0[$1.to, default: []].append($1.from) }
        for entry in entries {
            guard let target = level.resolveCalls(entry.op).map({ OpRef(node: $0.node, op: $0.op.id) }) else { continue }
            linked[entry.ref] = target
            linkedCallers[target, default: []].append(entry.ref)
        }
        for flow in level.flows {
            // A flow's own `op:` is resolved on its `by` (consumers) or `from` node, as the engine does.
            let root = flow.op.flatMap { resolve($0, caller: flow.by ?? flow.from, target: nil) }
            guard let start = flow.from ?? flow.by else { continue }
            if let root { hop(root, flow.by ?? start, nil) }
            walk(flow.steps, at: start, parent: root)
        }
    }

    func entry(_ ref: OpRef) -> Entry? { byRef[ref] }
    func ops(of node: String) -> [Entry] { all.filter { !$0.inherited && $0.node.id == node } }

    /// Ops on other nodes that talk to `node`: the reverse view of a database, cache or buffer. Inherited
    /// ops mapped to `node` count too.
    func targeting(_ node: String) -> [Entry] { all.filter { $0.peer == node && $0.ref.node != node } }

    /// The inherited ops a process on this level takes part in: those its flow steps perform, else
    /// those it performs by code, serves, or reaches over one of its edges.
    func inherited(through node: String) -> [Entry] {
        inherited.filter { entry in
            if entry.peer == node || entry.performer == node { return true }
            if let hops = hops[entry.ref], !hops.isEmpty { return hops.contains { $0.from == node } }
            guard entry.performer == nil, let peer = entry.peer else { return false }
            return outgoing[node]?.contains(peer) == true
        }
    }

    /// How many inherited ops map to each node: the ops badge on its card.
    var inheritedCounts: [String: Int] { inheritance?.counts ?? [:] }

    /// Who reaches this op: `calls:` links and the ops whose handling performs it.
    func callers(of ref: OpRef) -> [OpRef] { unique((linkedCallers[ref] ?? []) + (nestedIn[ref] ?? [])) }

    /// What this op reaches: its `calls:` target and the ops performed while handling it.
    func reaches(_ ref: OpRef) -> [OpRef] { unique((linked[ref].map { [$0] } ?? []) + (nested[ref] ?? [])) }

    /// The request path through an op: everything that leads to it and everything it leads to.
    func chain(_ ref: OpRef) -> [OpRef] {
        var seen: Set<OpRef> = [ref]
        var order = [ref]
        func follow(_ start: OpRef, _ next: (OpRef) -> [OpRef]) {
            var frontier = [start]
            for _ in 0..<8 where !frontier.isEmpty {
                frontier = frontier.flatMap(next).filter { seen.insert($0).inserted }
                order += frontier
            }
        }
        follow(ref, callers)
        follow(ref, reaches)
        return order
    }

    func highlight(_ ref: OpRef) -> StageHighlight {
        var result = StageHighlight()
        func connect(_ a: String, _ b: String) {
            result.nodes.formUnion([a, b])
            result.edges.insert("\(a)->\(b)")
            result.edges.insert("\(b)->\(a)")
        }
        for link in chain(ref) {
            guard let entry = byRef[link] else { continue }
            if entry.inherited {
                // The owner isn't on this level: light the steps that perform the op, else the process
                // that performs it (or every node with an edge into its peer) and the peer.
                if let hops = hops[link], !hops.isEmpty {
                    for hop in hops {
                        if let to = hop.to { connect(hop.from, to) } else { result.nodes.insert(hop.from) }
                    }
                } else if let peer = entry.peer {
                    result.nodes.insert(peer)
                    let sources = entry.performer.map { [$0] } ?? incoming[peer] ?? []
                    for source in sources { connect(source, peer) }
                } else if let performer = entry.performer {
                    result.nodes.insert(performer)
                }
                continue
            }
            result.nodes.insert(entry.node.id)
            if let peer = entry.peer {
                result.nodes.insert(peer)
                result.edges.insert("\(entry.node.id)->\(peer)")
                result.edges.insert("\(peer)->\(entry.node.id)")
            }
        }
        return result
    }

    /// `Level.resolveOp` as a ref; in a deep dive, an op of the node it is inside resolves to `../op`.
    private func resolve(_ reference: String, caller: String?, target: String?) -> OpRef? {
        level.resolveOp(reference, caller: caller, target: target, owner: inheritance?.owner).map { OpRef(node: $0.node, op: $0.op.id) }
    }

    private static func ref(_ key: String) -> OpRef? {
        guard let slash = key.firstIndex(of: "/") else { return nil }
        return OpRef(node: String(key[..<slash]), op: String(key[key.index(after: slash)...]))
    }

    /// Walks steps the way `Level.opReferences` does, remembering which op each one runs inside.
    private mutating func walk(_ steps: [Step], at node: String, parent: OpRef?) {
        for step in steps {
            switch step.action {
            case .call(let target, let inner, let miss):
                let ref = step.op.flatMap { resolve($0, caller: node, target: target) }
                if let ref { record(ref, parent: parent); hop(ref, node, target) }
                // Steps nested in the call run at the target, while handling the endpoint it reached.
                let handler = ref.map { ref in byRef[ref]?.op.direction == .inbound ? ref : linked[ref] ?? ref }
                walk(inner, at: target, parent: handler ?? parent)
                walk(miss, at: node, parent: parent)
            case .publish(let target):
                if let ref = step.op.flatMap({ resolve($0, caller: node, target: target) }) { record(ref, parent: parent); hop(ref, node, target) }
            case .work:
                if let ref = step.op.flatMap({ resolve($0, caller: node, target: nil) }) { record(ref, parent: parent); hop(ref, node, nil) }
            case .parallel(let inner):
                if let ref = step.op.flatMap({ resolve($0, caller: node, target: nil) }) { record(ref, parent: parent); hop(ref, node, nil) }
                walk(inner, at: node, parent: parent)
            }
        }
    }

    /// Remembers where a step performs an inherited op, for its path on the stage.
    private mutating func hop(_ ref: OpRef, _ from: String, _ to: String?) {
        guard ref.node == InheritedOps.ownerKey else { return }
        let hop = Hop(from: from, to: to)
        if !(hops[ref]?.contains(hop) ?? false) { hops[ref, default: []].append(hop) }
    }

    private mutating func record(_ ref: OpRef, parent: OpRef?) {
        guard let parent, parent != ref else { return }
        if !(nested[parent]?.contains(ref) ?? false) { nested[parent, default: []].append(ref) }
        if !(nestedIn[ref]?.contains(parent) ?? false) { nestedIn[ref, default: []].append(parent) }
    }

    private func unique(_ refs: [OpRef]) -> [OpRef] {
        var seen: Set<OpRef> = []
        return refs.filter { seen.insert($0).inserted }
    }

    private static func peer(of op: StrataCore.Operation, in level: Level) -> String? {
        if let target = op.target, level.node(target) != nil { return target }
        guard op.kind == .publish || op.kind == .consume, let topic = op.topic else { return nil }
        let buffers = level.nodes.filter { $0.kind.role == .buffer }
        return (buffers.first { $0.id == topic } ?? buffers.first { $0.label == topic }
                ?? level.nodes.first { $0.id == topic })?.id
    }
}

// MARK: - Text

enum SimOpsText {
    /// The access an op declares, or the one its query, command or method implies.
    static func access(_ op: StrataCore.Operation) -> OpAccess? {
        if let access = op.access { return access }
        switch op.kind {
        case .publish: return .write
        case .consume: return .read
        case .sql, .search:
            guard let word = firstWord(op.query.map(stripComments) ?? "") else { return op.kind == .search ? .read : nil }
            if ["SELECT", "SHOW", "EXPLAIN", "VALUES", "GET", "SEARCH"].contains(word) { return .read }
            if ["INSERT", "UPDATE", "DELETE", "UPSERT", "MERGE", "CREATE", "ALTER", "DROP", "TRUNCATE", "COPY",
                "PUT", "POST", "INDEX"].contains(word) { return .write }
            return word == "BEGIN" || word == "WITH" ? inferWrite(op.query ?? "") : nil
        case .cache:
            guard let word = firstWord(op.command ?? "") else { return nil }
            if ["GET", "MGET", "HGET", "HMGET", "HGETALL", "EXISTS", "TTL", "PTTL", "SMEMBERS", "SISMEMBER", "SCARD",
                "ZRANGE", "ZREVRANGE", "ZSCORE", "ZCARD", "LRANGE", "LLEN", "SCAN", "KEYS", "STRLEN", "XRANGE", "XREAD"]
                .contains(word) { return .read }
            if ["GETDEL", "GETSET", "GETEX"].contains(word) { return .readWrite }
            if ["EVAL", "EVALSHA", "FCALL", "MULTI"].contains(word) { return nil }
            return .write
        case .http, .storage:
            guard let word = firstWord(op.method ?? "") else { return nil }
            if ["GET", "HEAD", "OPTIONS"].contains(word) { return .read }
            if ["POST", "PUT", "PATCH", "DELETE"].contains(word) { return .write }
            return nil
        case .rpc, .llm, .call: return nil
        }
    }

    static func badge(_ access: OpAccess) -> String {
        switch access {
        case .read: "R"
        case .write: "W"
        case .readWrite: "RW"
        }
    }

    static func accessName(_ access: OpAccess) -> String {
        switch access {
        case .read: "read"
        case .write: "write"
        case .readWrite: "read-write"
        }
    }

    /// The compact second line of a row: `orders db · write · orders, outbox`, `GET price:{sku} · ttl 5m`.
    /// Without `namingPeer` it leaves out the node the op talks to, for rows grouped under that node.
    static func summary(_ entry: SimOpsIndex.Entry, in level: Level, namingPeer: Bool = true) -> String {
        let op = entry.op
        let peer = namingPeer ? entry.peer.flatMap { level.node($0)?.label } ?? op.target : nil
        var parts: [String] = []
        switch op.kind {
        case .sql, .search:
            parts = [peer, access(op).map(accessName), op.tables.isEmpty ? nil : op.tables.joined(separator: ", ")]
                .compactMap { $0 }
            if parts.count < 3, op.tx == true { parts.append("tx") }
        case .cache:
            let command = [op.command, op.key].compactMap { $0 }.joined(separator: " ")
            parts = [command.isEmpty ? peer : command, op.ttl.map { "ttl \(duration($0))" }].compactMap { $0 }
        case .publish, .consume:
            parts = [op.topic ?? peer, op.key.map { "key \($0)" },
                     op.kind == .consume ? op.group.map { "group \($0)" } : nil].compactMap { $0 }
        case .rpc, .http, .call, .storage, .llm:
            let call = [op.method, op.path].compactMap { $0 }.joined(separator: " ")
            if op.direction == .outbound, let peer { parts.append("→ \(peer)") }
            if !call.isEmpty, call != op.label { parts.append(call) }
            if let streaming = op.streaming, streaming != "unary" { parts.append("\(streaming) stream") }
            if parts.count < 2, !op.status.isEmpty { parts.append("status " + op.status.map(statusCode).joined(separator: ", ")) }
        }
        if parts.isEmpty { parts = [op.kind.rawValue] }
        return parts.joined(separator: " · ")
    }

    /// The second line of a row in a reverse view, which already names the peer (the selected node)
    /// and groups by table, key pattern or role: only what is left (`tx · row locks`, `GET · ttl 5m`).
    static func reverseSummary(_ entry: SimOpsIndex.Entry) -> String {
        let op = entry.op
        let parts: [String?] = switch op.kind {
        case .sql, .search: [op.tx == true ? "tx" : nil, op.locks.map { "\($0) locks" }]
        case .cache: [op.command, op.ttl.map { "ttl \(duration($0))" }]
        case .publish, .consume: [op.key.map { "key \($0)" }, op.group.map { "group \($0)" }]
        case .rpc, .http, .call, .storage, .llm:
            [[op.method, op.path].compactMap { $0 }.joined(separator: " ")].filter { !$0.isEmpty && $0 != op.label }
        }
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    /// `10/s · 8 ms`: a row's live rate and p99, short enough to leave the label its room (the detail
    /// shows them precisely).
    static func rate(_ metrics: OpMetrics) -> String {
        guard metrics.referenced else { return "—" }
        let rate = SimFormat.number(metrics.rate >= 10 ? metrics.rate.rounded() : metrics.rate)
        return "\(rate)/s · \(latency(metrics.p99))"
    }

    /// `900 µs`, `8 ms`, `1.4 s`.
    static func latency(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        if seconds < 0.001 { return "\(Int((seconds * 1_000_000).rounded())) µs" }
        if seconds < 1 { return "\(Int((seconds * 1000).rounded())) ms" }
        return "\(seconds.formatted(.number.precision(.fractionLength(0...1)))) s"
    }

    /// `orders-svc · INSERT order + outbox`.
    static func title(_ entry: SimOpsIndex.Entry) -> String { "\(entry.node.label) · \(entry.op.label)" }

    static func kindName(_ kind: OpKind) -> String {
        switch kind {
        case .sql: "SQL"
        case .cache: "Cache"
        case .publish: "Publish"
        case .consume: "Consume"
        case .rpc: "RPC"
        case .http: "HTTP"
        case .search: "Search"
        case .storage: "Storage"
        case .llm: "LLM"
        case .call: "Call"
        }
    }

    /// `5m`, `30s`, `1h`, `250ms`.
    static func duration(_ seconds: Double) -> String {
        if seconds <= 0 { return "none" }
        let whole = seconds.rounded() == seconds
        if whole, Int(seconds) % 86_400 == 0 { return "\(Int(seconds) / 86_400)d" }
        if whole, Int(seconds) % 3_600 == 0 { return "\(Int(seconds) / 3_600)h" }
        if whole, Int(seconds) % 60 == 0 { return "\(Int(seconds) / 60)m" }
        if seconds >= 1 { return "\(SimFormat.number(seconds))s" }
        return "\(SimFormat.number(seconds * 1000))ms"
    }

    /// The leading code of a status line: `201 created` → `201`.
    static func statusCode(_ status: String) -> String {
        String(status.split(separator: " ").first ?? Substring(status))
    }

    /// The first line of a payload, squeezed, for previews.
    static func preview(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }

    /// What "Copy" copies from an op: its query, payload, request or command.
    static func copyable(_ op: StrataCore.Operation) -> (title: String, text: String)? {
        if let query = op.query { return ("Copy query", query) }
        if let payload = op.payload { return ("Copy payload", payload) }
        if let request = op.request { return ("Copy request", request) }
        if let command = op.command { return ("Copy command", [command, op.key].compactMap { $0 }.joined(separator: " ")) }
        if let method = op.method { return ("Copy method", [method, op.path].compactMap { $0 }.joined(separator: " ")) }
        return nil
    }

    private static func firstWord(_ text: String) -> String? {
        text.split(whereSeparator: { !$0.isLetter }).first.map { $0.uppercased() }
    }

    private static func stripComments(_ query: String) -> String {
        query.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }.joined(separator: "\n")
    }

    private static func inferWrite(_ query: String) -> OpAccess? {
        let words = Set(query.uppercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        let writes = !words.isDisjoint(with: ["INSERT", "UPDATE", "DELETE", "MERGE", "UPSERT"])
        let reads = words.contains("SELECT")
        return writes ? (reads ? .readWrite : .write) : reads ? .read : nil
    }
}

// MARK: - Deep dives into an op

/// An op with `inside:` is a level of its own. Its path element is `node#op` (node and op ids never
/// contain `#`), so `.sim("checkout", path: ["orders#insert-order"])` opens the inside of orders-svc's
/// `insert-order`, and `Manifest.level(at:)` follows it like a node id.
enum SimOpsPath {
    static func element(_ ref: OpRef) -> String { "\(ref.node)#\(ref.op)" }

    static func ref(_ element: String) -> OpRef? {
        guard let hash = element.firstIndex(of: "#") else { return nil }
        return OpRef(node: String(element[..<hash]), op: String(element[element.index(after: hash)...]))
    }

    /// The breadcrumb for one path element inside `level`: a node label, or `orders-svc · INSERT order`.
    static func crumb(_ element: String, in level: Level?) -> String {
        guard let ref = ref(element) else { return level?.node(element)?.label ?? element }
        guard let node = level?.node(ref.node) else { return element }
        return "\(node.label) · \(node.ops.first { $0.id == ref.op }?.label ?? ref.op)"
    }

    /// What `rate: parent` follows inside an op: the op's measured rate, when a flow step performs it.
    @MainActor
    static func measuredRate(_ element: String, in sim: Simulation) -> Double? {
        guard let ref = ref(element) else { return nil }
        let metrics = sim.opMetrics(node: ref.node, op: ref.op)
        return metrics.referenced ? metrics.rate : nil
    }

    /// The node the stage zooms into for a path element (the op's node for `node#op`).
    static func node(_ element: String) -> String { ref(element)?.node ?? element }

    /// A stand-in node for the existing deep-dive route: its id is the `node#op` path element and it
    /// carries the op's `inside:` or `detail:`.
    static func diveNode(_ entry: SimOpsIndex.Entry) -> Node? {
        // An inherited op's own level hangs off the owner, one level up: open it from there.
        guard !entry.inherited, entry.op.inside != nil || entry.op.detail != nil else { return nil }
        var node = Node(id: element(entry.ref), kind: entry.node.kind, label: entry.op.label)
        node.inside = entry.op.inside
        node.detail = entry.op.detail
        return node
    }
}
