import Foundation

// The ops of the node a deep dive is inside ("inherited ops"), each mapped to the inner node it talks
// to (docs/manifest.md, Operations, In a deep dive). Additive helpers next to the contract types, so
// the validator, the engine, the CLI and the UI map them the same way.

/// A deep-dive level's view of its owner's ops: the node whose `inside:` it is keeps its ops on the
/// overview, and each op is matched to the inner node it talks to (its peer).
public struct InheritedOps: Sendable {
    /// The node part of an inherited op's `node/op` key (`../insert-order`). Never a node id, which can't
    /// start with a dot; a step can name an inherited op explicitly the same way.
    public static let ownerKey = ".."

    /// Why an op maps to its peer, in the order the rules are tried.
    public enum Rule: String, Sendable, CaseIterable {
        /// The op's `target` is an inner node id (or, for a message without one, its `topic` names
        /// an inner queue or topic).
        case target
        /// An inner node's `code:` names the op's `code:`: its entries in order, with the line, then
        /// by file. For an outbound op, a process here is who performs it, not its peer.
        case code
        /// The only inner node labelled like the overview target (a port drawn for that database).
        case label
        /// The only inner node the op's kind talks to: a database for `sql`, a cache or store for
        /// `cache` and `storage`, a queue or topic for messages, narrowed by the target's tech and
        /// name; when the owner's ops of that family name several targets, only a node named like
        /// this one's. For `rpc`, `http`, `call` and `llm`, the only port or external named like the
        /// target.
        case kind
    }

    public struct Entry: Sendable {
        public let op: Operation
        /// The inner node this op talks to: a database, cache, store, buffer or port. For an op the
        /// owner serves (no target), the inner node that serves it. nil when no rule matches.
        public let peer: String?
        public let rule: Rule?
        /// The inner process (service, worker, cron, function) whose `code:` file is the op's, when
        /// that process isn't the peer: who performs an outbound op.
        public let performer: String?
    }

    public let owner: Node
    /// The level the owner sits on, where its targets and their schemas are.
    public let ownerLevel: Level
    /// One per owner op, in op order.
    public let entries: [Entry]

    public init(owner: Node, ownerLevel: Level, inside level: Level) {
        self.owner = owner
        self.ownerLevel = ownerLevel
        let inner = level.nodes.filter { $0.kind != .note }
        entries = owner.ops.map { Self.map($0, inner: inner, ownerLevel: ownerLevel, siblings: owner.ops) }
    }

    public func entry(_ op: String) -> Entry? { entries.first { $0.op.id == op } }

    public func peer(of op: String) -> String? { entry(op)?.peer }

    /// The ops mapped to an inner node, in op order.
    public func ops(mappedTo node: String) -> [Entry] { entries.filter { $0.peer == node } }

    /// How many ops map to each inner node.
    public var counts: [String: Int] {
        entries.reduce(into: [:]) { counts, entry in if let peer = entry.peer { counts[peer, default: 0] += 1 } }
    }

    // MARK: Rules

    private static func map(_ op: Operation, inner: [Node], ownerLevel: Level, siblings: [Operation]) -> Entry {
        let target = op.target.flatMap(ownerLevel.node)
        let outbound = op.direction == .outbound
        let process = { (node: Node) in Node.componentKinds.contains(node.kind) }
        // An outbound op's code in a process says who performs it, not what it talks to.
        let performer = outbound ? byCode(op, among: inner.filter(process)) : nil
        func entry(_ peer: Node?, _ rule: Rule?) -> Entry {
            Entry(op: op, peer: peer?.id, rule: peer == nil ? nil : rule, performer: performer?.id == peer?.id ? nil : performer?.id)
        }

        if let id = op.target, let node = inner.first(where: { $0.id == id }) { return entry(node, .target) }
        if op.kind == .consume || op.kind == .publish, op.target == nil, let topic = op.topic,
           let node = only(inner.filter { $0.kind.role == .buffer && names($0).contains(topic.lowercased()) }) {
            return entry(node, .target)
        }
        let peers = outbound ? inner.filter { !process($0) } : inner
        if let node = byCode(op, among: peers) { return entry(node, .code) }
        if let label = target?.label.lowercased(), let node = only(peers.filter({ $0.label.lowercased() == label })) {
            return entry(node, .label)
        }
        // Several overview targets of one family (two databases) can't all be the one database here.
        let targets = Set(siblings.filter { family($0.kind) == family(op.kind) }.compactMap(\.target))
        if let node = byKind(op, inner: inner, target: target, ambiguous: targets.count > 1) { return entry(node, .kind) }
        return entry(nil, nil)
    }

    /// The node whose `code:` names the op's code: its `code:` entries in order (the first is the most
    /// specific), each matched exactly with its line, then by file (preferring the one node of a kind
    /// the op talks to), until one names a single node.
    private static func byCode(_ op: Operation, among nodes: [Node]) -> Node? {
        for path in op.code {
            let exact = path.trimmingCharacters(in: .whitespaces)
            if let node = only(nodes.filter({ $0.code.contains { $0.trimmingCharacters(in: .whitespaces) == exact } })) { return node }
            let file = codeFile(path)
            let matches = nodes.filter { $0.code.contains { codeFile($0) == file } }
            if let node = only(matches) ?? only(matches.filter({ fits(op, $0) })) { return node }
        }
        return nil
    }

    /// The only inner node of a kind this op talks to, narrowed by the overview target's name and tech
    /// when several fit. `ambiguous`: the owner's ops of this family name several targets, so a node
    /// must be named like this op's.
    private static func byKind(_ op: Operation, inner: [Node], target: Node?, ambiguous: Bool) -> Node? {
        let fitting = inner.filter { fits(op, $0) }
        let alike = fitting.filter { named($0, like: op.target, target) }
        switch op.kind {
        case .rpc, .http, .call, .llm:
            // Ports stand for the outside world; only one named like the target says which.
            guard op.direction == .outbound, op.target != nil else { return nil }
            return only(alike)
        case .publish, .consume:
            if let topic = op.topic?.lowercased(), let node = only(fitting.filter({ names($0).contains(topic) })) { return node }
            return ambiguous ? only(alike) : only(fitting) ?? only(alike)
        case .sql, .search, .cache, .storage:
            if op.direction == .inbound, op.target == nil { return nil }
            let tech = fitting.filter { sameTech($0, target) }
            return ambiguous ? only(alike) ?? only(tech.filter { node in alike.contains { $0.id == node.id } }) : only(fitting) ?? only(tech) ?? only(alike)
        }
    }

    /// Op kinds that talk to the same kinds of node.
    private static func family(_ kind: OpKind) -> Int {
        switch kind {
        case .sql, .search: 0
        case .cache, .storage: 1
        case .publish, .consume: 2
        case .rpc, .http, .call, .llm: 3
        }
    }

    /// Whether an inner node is the kind of node this op talks to.
    private static func fits(_ op: Operation, _ node: Node) -> Bool {
        switch op.kind {
        case .sql: [.database, .search].contains(node.kind)
        case .search: [.search, .database, .vector].contains(node.kind)
        case .cache, .storage: [.cache, .store].contains(node.kind)
        case .publish, .consume: node.kind.role == .buffer
        case .llm: [.llm, .port, .external].contains(node.kind)
        case .rpc, .http, .call: [.port, .external].contains(node.kind)
        }
    }

    /// The inner node's tech names the overview target (`Redis` for a target labelled Redis), or the
    /// other way round.
    private static func sameTech(_ node: Node, _ target: Node?) -> Bool {
        guard let target else { return false }
        if let tech = node.tech?.lowercased(), names(target).contains(tech) { return true }
        if let tech = target.tech?.lowercased(), names(node).contains(tech) { return true }
        return false
    }

    /// The inner node's id or label names the target: equal, or one's words contain the other's
    /// (`payments API` for `payments`, `mailer-port` for `mailer`).
    private static func named(_ node: Node, like id: String?, _ target: Node?) -> Bool {
        let theirs = ([id, target?.label].compactMap { $0 }).map(words).filter { !$0.isEmpty }
        let ours = [node.id, node.label].map(words).filter { !$0.isEmpty }
        return ours.contains { mine in theirs.contains { mine.isSubset(of: $0) || $0.isSubset(of: mine) } }
    }

    private static func names(_ node: Node) -> Set<String> {
        Set([node.id, node.label, node.tech].compactMap { $0?.lowercased() })
    }

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    private static func only(_ nodes: [Node]) -> Node? { nodes.count == 1 ? nodes[0] : nil }

    /// `services/orders/repo/orders.go:88` → `services/orders/repo/orders.go`.
    public static func codeFile(_ path: String) -> String {
        var file = path.trimmingCharacters(in: .whitespaces)
        if let hash = file.range(of: "#L") { file = String(file[..<hash.lowerBound]) }
        while let colon = file.lastIndex(of: ":"), !file[file.index(after: colon)...].isEmpty,
              file[file.index(after: colon)...].allSatisfy({ $0.isNumber || $0 == "-" }) {
            file = String(file[..<colon])
        }
        if file.hasPrefix("./") { file.removeFirst(2) }
        return file
    }
}

public extension Manifest {
    /// The node whose `inside:` level `path` ends in, and the level that node sits on. nil at the root,
    /// for an op's own level (`node#op`), and for a path that doesn't resolve.
    func deepDiveOwner(at path: [String]) -> (node: Node, level: Level)? {
        guard let last = path.last, !last.contains("#"), let level = level(at: Array(path.dropLast())),
              let node = level.node(last), node.inside != nil else { return nil }
        return (node, level)
    }

    /// The owner's ops mapped onto the deep-dive level at `path`. nil when `path` isn't a node's
    /// `inside:` level or that node has no ops.
    func inheritedOps(at path: [String]) -> InheritedOps? {
        guard let owner = deepDiveOwner(at: path), !owner.node.ops.isEmpty, let inside = owner.node.inside else { return nil }
        return InheritedOps(owner: owner.node, ownerLevel: owner.level, inside: inside)
    }
}
