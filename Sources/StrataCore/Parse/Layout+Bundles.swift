import Foundation

/// One drawn link standing for several edges into the same node over the same protocol family
/// (docs/design.md, Edges): `sql · 8` from a group's box to Postgres instead of eight lines. Display only:
/// the edges stay in the manifest and the simulation, and tokens on them travel along the bundle.
public struct EdgeBundle: Sendable, Equatable, Identifiable {
    /// `bundle:<target>:<family>:<group, or * for a trunk>`.
    public let id: String
    public let target: String
    /// The protocol family (`sql` for sql, postgres, mysql…), which decides what may share a line.
    public let family: String
    /// The pill's word: the protocol every member names when they agree, else the family.
    public let word: String
    /// The group whose box the link leaves from; nil for a trunk the lines join near their sources.
    public let group: String?
    /// Member edge ids, in the level's order, and their sources.
    public let edges: [String]
    public let sources: [String]

    /// `sql · 8`, or with fewer members while some are drawn on their own.
    public func label(count: Int? = nil) -> String { "\(word) · \(count ?? edges.count)" }
}

/// Which edges collapse into one link, and which come back out (docs/design.md, Edges).
///
/// - **Who.** Edges into one store or external API (database, cache, store, search, vector, external) over
///   one protocol family. Edges without a protocol keep their own line, and so do edges into anything
///   else: the request path stays drawn edge by edge.
/// - **From a group's box.** The callers inside one top-level group that doesn't hold the target collapse
///   when there are at least `minimum` of them: one link from the box of the deepest group they all share.
/// - **Trunk.** The callers left over (ungrouped, or too few in their group) collapse when there are at
///   least `minimum` of them: their lines join one trunk just past the last of them.
/// - **Back out.** A member edge leaves its bundle while its source is in focus (hovered or selected) or
///   the edge is lit (an op path, a pressure overlay, a flow); a bundle whose target is in focus, or that
///   would keep fewer than two members, draws every member on its own.
public enum EdgeBundling {
    public static let minimum = 3
    /// Datastores: what "Quiet data links" draws thinner and fainter.
    public static let dataKinds: Set<NodeKind> = [.database, .cache, .store, .search, .vector]
    /// What a bundle may end on: shared dependencies rather than steps of the request path.
    public static let targetKinds: Set<NodeKind> = dataKinds.union([.external])

    /// The family a protocol belongs to, so `postgres` and `sql` share a line; nil without a protocol.
    public static func family(_ protocol: String?) -> String? {
        guard let raw = `protocol`?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }
        switch raw {
        case "sql", "postgres", "postgresql", "pg", "psql", "mysql", "mariadb", "sqlite", "jdbc", "tds", "mssql", "cloudsql": return "sql"
        case "redis", "valkey", "resp", "resp3", "rediss": return "redis"
        case "http", "https", "http2", "http/2", "h2", "rest", "json", "graphql": return "http"
        case "grpc", "grpcs", "grpc-web", "protobuf": return "grpc"
        case "amqp", "amqps", "rabbitmq": return "amqp"
        case "kafka", "kafka-tls": return "kafka"
        case "s3", "gcs", "blob", "object": return "s3"
        default: return raw
        }
    }

    /// The level's bundles, in a stable order: by target, then family, then group.
    public static func bundles(in level: Level) -> [EdgeBundle] {
        let nodes = Dictionary(level.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let parents = Dictionary(level.groups.map { ($0.id, $0.parent) }, uniquingKeysWith: { first, _ in first })
        func path(_ node: String) -> [String] {
            var result: [String] = []
            var current = nodes[node]?.group
            while let group = current, parents.keys.contains(group), !result.contains(group) {
                result.insert(group, at: 0)
                current = parents[group] ?? nil
            }
            return result
        }
        // Candidate edges by target and family, in level order.
        var keys: [[String]] = []
        var members: [[String]: [Edge]] = [:]
        var seen: Set<String> = []
        for edge in level.edges where edge.from != edge.to && seen.insert(edge.id).inserted {
            guard let target = nodes[edge.to], targetKinds.contains(target.kind), nodes[edge.from] != nil,
                  let family = family(edge.protocol) else { continue }
            let key = [edge.to, family]
            if members[key] == nil { keys.append(key) }
            members[key, default: []].append(edge)
        }
        let order = Dictionary(level.nodes.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var result: [EdgeBundle] = []
        for key in keys.sorted(by: { (order[$0[0]] ?? 0, $0[1]) < (order[$1[0]] ?? 0, $1[1]) }) {
            let edges = members[key]!
            guard edges.count >= minimum else { continue }
            let target = key[0], family = key[1]
            let around = Set(path(target))
            // Callers by the outermost group they are in that does not hold the target.
            var clusters: [String: [Edge]] = [:]
            var loose: [Edge] = []
            for edge in edges {
                if let outer = path(edge.from).first(where: { !around.contains($0) }) {
                    clusters[outer, default: []].append(edge)
                } else {
                    loose.append(edge)
                }
            }
            var bundles: [EdgeBundle] = []
            for outer in clusters.keys.sorted() {
                let cluster = clusters[outer]!
                guard cluster.count >= minimum else { loose += cluster; continue }
                // The deepest group every caller in the cluster shares.
                var common = path(cluster[0].from)
                for edge in cluster.dropFirst() {
                    let other = path(edge.from)
                    common = Array(zip(common, other).prefix { $0 == $1 }.map(\.0))
                }
                let group = common.last(where: { !around.contains($0) }) ?? outer
                bundles.append(make(target: target, family: family, group: group, cluster))
            }
            if loose.count >= minimum {
                let index = Dictionary(edges.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
                bundles.append(make(target: target, family: family, group: nil, loose.sorted { index[$0.id]! < index[$1.id]! }))
            }
            result += bundles
        }
        return result
    }

    private static func make(target: String, family: String, group: String?, _ edges: [Edge]) -> EdgeBundle {
        let words = Set(edges.compactMap { $0.protocol?.lowercased() })
        return EdgeBundle(id: "bundle:\(target):\(family):\(group ?? "*")", target: target, family: family,
                          word: words.count == 1 ? words.first! : family, group: group,
                          edges: edges.map(\.id), sources: edges.map(\.from))
    }

    /// An edge into a datastore: "Quiet data links" draws it thinner and fainter, its pill on demand.
    public static func isDataLink(_ edge: Edge, in level: Level) -> Bool {
        level.node(edge.to).map { dataKinds.contains($0.kind) } ?? false
    }

    /// What the stage draws for `bundles` while `focus` nodes are hovered or selected and `lit` edges are
    /// highlighted: each bundle still drawn with the members it keeps, and the member edges drawn alone.
    public struct Drawn: Sendable, Equatable {
        /// Bundle id → the members it still stands for (two or more).
        public var bundles: [String: [String]] = [:]
        /// Member edges drawn on their own line.
        public var loose: Set<String> = []
        public init() {}
    }

    public static func drawn(_ bundles: [EdgeBundle], focus: Set<String>, lit: Set<String>) -> Drawn {
        var drawn = Drawn()
        for bundle in bundles {
            if focus.contains(bundle.target) {
                drawn.loose.formUnion(bundle.edges)
                continue
            }
            var kept: [String] = []
            for (edge, source) in zip(bundle.edges, bundle.sources) {
                if focus.contains(source) || lit.contains(edge) { drawn.loose.insert(edge) } else { kept.append(edge) }
            }
            if kept.count >= 2 { drawn.bundles[bundle.id] = kept } else { drawn.loose.formUnion(kept) }
        }
        return drawn
    }

    /// How many links the stage draws for `level`: its edges, with each drawn bundle counting once for
    /// the members it keeps.
    public static func drawnLinks(_ level: Level, bundles: [EdgeBundle], focus: Set<String> = [], lit: Set<String> = []) -> Int {
        let drawn = drawn(bundles, focus: focus, lit: lit)
        let folded = drawn.bundles.values.reduce(0) { $0 + $1.count }
        return Set(level.edges.map(\.id)).count - folded + drawn.bundles.count
    }
}

extension Level {
    /// The edges `flow` travels: its calls and publishes, and for a consumer the edge from its buffer.
    public func edgeIDs(of flow: Flow) -> Set<String> {
        var result: Set<String> = []
        func walk(_ steps: [Step], from node: String) {
            for step in steps {
                switch step.action {
                case .call(let target, let inner, let miss):
                    result.insert("\(node)->\(target)")
                    walk(inner, from: target)
                    walk(miss, from: target)
                case .publish(let target):
                    result.insert("\(node)->\(target)")
                case .parallel(let branches):
                    walk(branches, from: node)
                case .work:
                    continue
                }
            }
        }
        if let buffer = flow.on, let consumer = flow.by {
            result.insert("\(buffer)->\(consumer)")
            walk(flow.steps, from: consumer)
        } else if let source = flow.from {
            walk(flow.steps, from: source)
        }
        return result
    }
}
