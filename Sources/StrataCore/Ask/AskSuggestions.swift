import Foundation

/// Questions the Ask tab offers before you type, made from the map: about the selected node when
/// there is one, else about the level's most shared dependency, its busiest table, a status column,
/// a mechanism and a flow. Deterministic.
public enum AskSuggestions {
    public static func make(_ manifest: Manifest, focus: AskFocus, limit: Int = 4) -> [String] {
        guard let level = manifest.level(at: focus.path) else { return [] }
        var out: [String] = []
        func add(_ question: String?) {
            guard let question, !out.contains(question) else { return }
            out.append(question)
        }
        if let id = focus.node, let node = level.node(id) {
            nodeQuestions(node, level: level).forEach(add)
        }
        mapQuestions(manifest, level: level, path: focus.path, selected: focus.node).forEach(add)
        return Array(out.prefix(limit))
    }

    private static let stores: Set<NodeKind> = [.database, .cache, .search, .store, .queue, .topic, .external, .llm, .vector]

    static func nodeQuestions(_ node: Node, level: Level) -> [String] {
        let name = node.label
        var out: [String] = []
        switch node.kind {
        case .database, .search:
            out.append("What breaks if \(name) is down for 30 s?")
            out.append("Which queries hit \(name)?")
        case .cache:
            out.append("What happens if \(name) is down for 30 s?")
            out.append("Which keys live in \(name), and who reads them?")
        case .queue, .topic:
            out.append("Who publishes to \(name), and who consumes it?")
            out.append("What happens if \(name)'s consumers fall behind?")
        case .external, .llm, .vector, .store:
            out.append("What happens if \(name) is slow or down?")
        case .client, .user, .cron, .port, .note:
            break
        default:
            out.append("What breaks if \(name) is down?")
            if node.ops.contains(where: { $0.kind == .sql && $0.access != .read }) { out.append("Which tables does \(name) write?") }
            else { out.append("What does \(name) call, and what calls it?") }
        }
        if let mechanism = node.how.first ?? node.ops.lazy.compactMap({ $0.how.first }).first {
            out.append("How does \(sentence(mechanism.title)) work?")
        }
        if node.inside != nil { out.append("What runs inside \(name)?") }
        return out
    }

    static func mapQuestions(_ manifest: Manifest, level: Level, path: [String], selected: String? = nil) -> [String] {
        var out: [String] = []
        // The dependency most nodes call.
        let callers = Dictionary(grouping: level.edges.filter { !$0.implicit }, by: \.to).mapValues(\.count)
        // Ties go to the store whose outage hurts most: databases, then caches, then the rest.
        let rank: [NodeKind: Int] = [.database: 3, .cache: 2, .queue: 1, .topic: 1]
        let shared = level.nodes.filter { stores.contains($0.kind) && callers[$0.id, default: 0] > 0 && $0.id != selected }
            .enumerated().max { a, b in
                let x = (callers[a.element.id, default: 0], rank[a.element.kind, default: 0])
                let y = (callers[b.element.id, default: 0], rank[b.element.kind, default: 0])
                return x == y ? a.offset > b.offset : x < y
            }?.element
        if let shared { out.append("What happens if \(shared.label) is down for 30 s?") }

        // A status column and one of its middle values.
        if let def = manifest.enums.first(where: { !$0.transitions.isEmpty }) {
            if let column = manifest.enumColumns().first(where: { $0.enumID == def.id }) {
                out.append("Who writes \(column.column.table).\(column.column.column)?")
            }
            let stuck = def.values.first { value in
                !value.terminal && def.transitions.contains { $0.to == value.value } && def.transitions.contains { $0.from == value.value }
            } ?? def.values.first { value in !value.terminal && def.transitions.contains { $0.from == value.value } }
            if let stuck { out.append("Why would \(subject(def)) stay in \(stuck.name) (\(stuck.value))?") }
        }

        // The table the most ops name.
        var touches: [String: Int] = [:]
        var order: [String] = []
        for (_, each) in manifest.everyLevel() {
            for node in each.nodes {
                for op in node.ops {
                    for table in op.tables {
                        if touches[table] == nil { order.append(table) }
                        touches[table, default: 0] += 1
                    }
                }
            }
        }
        if let table = order.enumerated().max(by: { a, b in
            let (x, y) = (touches[a.element, default: 0], touches[b.element, default: 0])
            return x == y ? a.offset > b.offset : x < y
        })?.element {
            out.append("Which queries hit the \(table) table?")
        }

        if let mechanism = manifest.mechanisms().first(where: { $0.path == path }) ?? manifest.mechanisms().first {
            out.append("How does \(sentence(mechanism.mechanism.title)) work?")
        }
        if let flow = level.flows.first(where: { !$0.isConsumer }) ?? level.flows.first {
            out.append("Walk me through \(sentence(flow.label)).")
        }
        return out
    }

    /// "Order status" → "an order"; anything else → "a value".
    static func subject(_ def: EnumDef) -> String {
        let label = def.label.lowercased()
        guard label.hasSuffix(" status"), label.count > 7 else { return "a value" }
        let noun = String(label.dropLast(7))
        return ("aeiou".contains(noun.first ?? "x") ? "an " : "a ") + noun
    }

    /// Lowercases the first letter of a title unless it starts an acronym ("Roster heartbeats" →
    /// "roster heartbeats", "VOS pacing" stays).
    static func sentence(_ title: String) -> String {
        guard let first = title.first, first.isUppercase else { return title }
        let second = title.dropFirst().first
        if let second, second.isUppercase { return title }
        return first.lowercased() + title.dropFirst()
    }
}
