import Foundation

// Ask the map (docs/architecture.md, Ask): answers cite what they mention as markdown links with the
// `strata:` scheme, and the app turns each into a click that selects or opens it. This file parses
// those links and resolves them against the manifest; the UI maps an `AskTarget` to its action.
//
//   strata:node/pacing                    a node; a deep dive's node takes the level path first
//   strata:node/orders/handler            (level [orders], node handler)
//   strata:op/pacing/list-running         an operation: [level path…/] node / op
//   strata:how/reaper-tick/reaper-tick    a mechanism: [level path…/] node [/ op] / mechanism, or its id alone
//   strata:enum/campaign-status/3200      an enum value (a code or a name), or the whole enum
//   strata:table/call                     a table, or table/<database node>/<table>
//   strata:level/orders                   a deep-dive level (also strata:dive/…)
//   strata:flow/place-order               a flow; strata:scenario/db-outage a scenario

/// A `strata:` link as written, before it is checked against a manifest.
public enum AskLink: Sendable, Hashable {
    case node([String])
    case op([String])
    case how([String])
    case enumeration(String, value: String?)
    case table([String])
    case level([String])
    case flow([String])
    case scenario([String])

    public static let scheme = "strata"

    /// Parses `strata:kind/a/b`; also tolerates `strata://kind/a/b` and percent-encoded segments
    /// (`orders%23insert-order` for an op's own level). nil for anything else.
    public static func parse(_ text: String) -> AskLink? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix(scheme + ":") else { return nil }
        let rest = trimmed.dropFirst(scheme.count + 1)
        let parts = rest.split(separator: "/", omittingEmptySubsequences: true).map { part in
            String(part).removingPercentEncoding ?? String(part)
        }
        guard let kind = parts.first?.lowercased() else { return nil }
        let args = Array(parts.dropFirst())
        switch kind {
        case "node": return args.isEmpty ? nil : .node(args)
        case "op", "operation": return args.count < 2 ? nil : .op(args)
        case "how", "mechanism": return args.isEmpty ? nil : .how(args)
        case "enum":
            guard let id = args.first else { return nil }
            return .enumeration(id, value: args.count > 1 ? args.dropFirst().joined(separator: "/") : nil)
        case "table": return args.isEmpty ? nil : .table(args)
        case "level", "dive": return .level(args)
        case "flow": return args.isEmpty ? nil : .flow(args)
        case "scenario": return args.isEmpty ? nil : .scenario(args)
        default: return nil
        }
    }
}

/// What a resolved link opens in the app. Paths are level paths as `Manifest.level(at:)` takes them.
public enum AskTarget: Sendable, Hashable {
    case node(path: [String], node: String)
    case op(path: [String], node: String, op: String)
    case mechanism(path: [String], node: String, op: String?, mechanism: String)
    case enumeration(id: String, value: String?)
    case table(path: [String], node: String, table: String)
    case level(path: [String])
    case flow(path: [String], flow: String)
    case scenario(path: [String], scenario: String)

    /// The level the target lives on; nil for an enum, which belongs to the whole manifest.
    public var path: [String]? {
        switch self {
        case .node(let path, _), .op(let path, _, _), .mechanism(let path, _, _, _), .table(let path, _, _),
             .level(let path), .flow(let path, _), .scenario(let path, _): path
        case .enumeration: nil
        }
    }

    /// The canonical link for this target, in the syntax the system prompt teaches.
    public var link: String {
        func join(_ parts: [String]) -> String {
            parts.map { $0.addingPercentEncoding(withAllowedCharacters: AskTarget.segment) ?? $0 }.joined(separator: "/")
        }
        switch self {
        case .node(let path, let node): return "strata:node/" + join(path + [node])
        case .op(let path, let node, let op): return "strata:op/" + join(path + [node, op])
        case .mechanism(let path, let node, let op, let mechanism):
            return "strata:how/" + join(path + [node] + (op.map { [$0] } ?? []) + [mechanism])
        case .enumeration(let id, let value): return "strata:enum/" + join([id] + (value.map { [$0] } ?? []))
        case .table(let path, let node, let table): return "strata:table/" + join(path + [node, table])
        case .level(let path): return "strata:level/" + join(path)
        case .flow(let path, let flow): return "strata:flow/" + join(path + [flow])
        case .scenario(let path, let scenario): return "strata:scenario/" + join(path + [scenario])
        }
    }

    private static let segment: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-_.~")
        return set
    }()
}

public extension Manifest {
    /// Resolves a link: the exact path first, then (so a slightly wrong path still works) the shallowest
    /// level that has the id, in document order. nil when nothing in this manifest matches.
    func resolve(_ link: AskLink) -> AskTarget? {
        switch link {
        case .node(let args):
            let id = args[args.count - 1], path = Array(args.dropLast())
            if level(at: path)?.node(id) != nil { return .node(path: path, node: id) }
            return askLevels.first { $0.level.node(id) != nil }.map { .node(path: $0.path, node: id) }

        case .op(let args):
            let n = args.count, opID = args[n - 1], nodeID = args[n - 2], path = Array(args.dropLast(2))
            if level(at: path)?.node(nodeID)?.ops.contains(where: { $0.id == opID }) == true {
                return .op(path: path, node: nodeID, op: opID)
            }
            for (path, level) in askLevels {
                if level.node(nodeID)?.ops.contains(where: { $0.id == opID }) == true { return .op(path: path, node: nodeID, op: opID) }
            }
            // An op named on the wrong node (an inner process for its owner's op): the op id alone.
            for (path, level) in askLevels {
                if let node = level.nodes.first(where: { $0.ops.contains { $0.id == opID } }) {
                    return .op(path: path, node: node.id, op: opID)
                }
            }
            return nil

        case .how(let args):
            let n = args.count, mechanism = args[n - 1]
            if n >= 2, let node = level(at: Array(args.dropLast(2)))?.node(args[n - 2]),
               node.how.contains(where: { $0.id == mechanism }) {
                return .mechanism(path: Array(args.dropLast(2)), node: node.id, op: nil, mechanism: mechanism)
            }
            if n >= 3, let op = level(at: Array(args.dropLast(3)))?.node(args[n - 3])?.ops.first(where: { $0.id == args[n - 2] }),
               op.how.contains(where: { $0.id == mechanism }) {
                return .mechanism(path: Array(args.dropLast(3)), node: args[n - 3], op: op.id, mechanism: mechanism)
            }
            let sites = mechanisms().filter { $0.mechanism.id == mechanism }
            let site = sites.first { args.dropLast().contains($0.node) } ?? sites.first
            return site.map { .mechanism(path: $0.path, node: $0.node, op: $0.op, mechanism: mechanism) }

        case .enumeration(let id, let value):
            guard let def = enumDef(id) else { return nil }
            return .enumeration(id: id, value: value.flatMap { def.resolve($0)?.value })

        case .table(let args):
            var parts = args
            // `table/db.orders` reads as node `db`, table `orders`.
            if parts.count == 1, let dot = parts[0].firstIndex(of: ".") {
                let nodeID = String(parts[0][..<dot])
                if askLevels.contains(where: { $0.level.node(nodeID) != nil }) {
                    parts = [nodeID, String(parts[0][parts[0].index(after: dot)...])]
                }
            }
            let table = parts[parts.count - 1]
            if parts.count >= 2 {
                let nodeID = parts[parts.count - 2], path = Array(parts.dropLast(2))
                if level(at: path)?.node(nodeID)?.schema.contains(where: { $0.name == table }) == true {
                    return .table(path: path, node: nodeID, table: table)
                }
                for (path, level) in askLevels where level.node(nodeID)?.schema.contains(where: { $0.name == table }) == true {
                    return .table(path: path, node: nodeID, table: table)
                }
            }
            for (path, level) in askLevels {
                if let node = level.nodes.first(where: { $0.schema.contains { $0.name == table } }) {
                    return .table(path: path, node: node.id, table: table)
                }
            }
            return nil

        case .level(let args):
            if level(at: args) != nil { return .level(path: args) }
            guard let last = args.last else { return nil }
            return askLevels.first { $0.path.last == last }.map { .level(path: $0.path) }

        case .flow(let args):
            let id = args[args.count - 1], path = Array(args.dropLast())
            if level(at: path)?.flow(id) != nil { return .flow(path: path, flow: id) }
            return askLevels.first { $0.level.flow(id) != nil }.map { .flow(path: $0.path, flow: id) }

        case .scenario(let args):
            let id = args[args.count - 1], path = Array(args.dropLast())
            if level(at: path)?.scenarios.contains(where: { $0.id == id }) == true { return .scenario(path: path, scenario: id) }
            return askLevels.first { $0.level.scenarios.contains { $0.id == id } }.map { .scenario(path: $0.path, scenario: id) }
        }
    }

    /// Parses and resolves a link written in an answer.
    func askTarget(_ link: String) -> AskTarget? { AskLink.parse(link).flatMap(resolve) }

    /// Every level, shallowest first and in document order within a depth, so a fallback lookup
    /// prefers the overview over a deep dive.
    private var askLevels: [(path: [String], level: Level)] {
        everyLevel().enumerated().sorted { a, b in
            a.element.path.count == b.element.path.count ? a.offset < b.offset : a.element.path.count < b.element.path.count
        }.map(\.element)
    }
}

/// Finds the `[label](strata:…)` links in an answer.
public enum AskLinks {
    public struct Found: Sendable, Hashable {
        public let range: Range<String.Index>
        public let label: String
        public let url: String
    }

    public static func find(in text: String) -> [Found] {
        let pattern = #/\[([^\[\]\n]*)\]\(\s*<?(strata:[^)\s>]*)>?\s*\)/#
        return text.matches(of: pattern).map { Found(range: $0.range, label: String($0.1), url: String($0.2)) }
    }

    /// The answer with each `strata:` link that doesn't resolve replaced by its label, so a broken
    /// citation reads as plain text instead of a dead link. Links that resolve are rewritten to their
    /// canonical form.
    public static func rewrite(_ text: String, in manifest: Manifest) -> String {
        var result = text
        for found in find(in: text).reversed() {
            if let target = manifest.askTarget(found.url) {
                result.replaceSubrange(found.range, with: "[\(found.label)](\(target.link))")
            } else {
                result.replaceSubrange(found.range, with: found.label)
            }
        }
        return result
    }
}
