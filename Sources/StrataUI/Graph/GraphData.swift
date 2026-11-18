import Foundation
import StrataCore

struct GraphData {
    struct Node {
        let route: Route
        let title: String
        let symbol: String

        var isNote: Bool {
            if case .note = route { return true }
            return false
        }
    }

    struct Edge: Hashable, Comparable {
        let a: Int
        let b: Int

        init(_ a: Int, _ b: Int) {
            self.a = min(a, b)
            self.b = max(a, b)
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.a, lhs.b) < (rhs.a, rhs.b)
        }
    }

    let nodes: [Node]
    let edges: [Edge]
    let neighbours: [Set<Int>]

    init(nodes: [Node] = [], edges: [Edge] = []) {
        self.nodes = nodes
        self.edges = edges
        var adjacent = Array(repeating: Set<Int>(), count: nodes.count)
        for edge in edges {
            adjacent[edge.a].insert(edge.b)
            adjacent[edge.b].insert(edge.a)
        }
        neighbours = adjacent
    }

    @MainActor
    init(catalog: ShellCatalog) {
        let vault = catalog.model.vault
        let notes = vault.allNotes
        let simulators = catalog.entries.filter { $0.manifest != nil }
        let noteNodes = notes.map { Node(route: .note($0), title: ShellCatalog.title($0), symbol: "note.text") }
        let simNodes = simulators.map { Node(route: .sim($0.id, path: []), title: $0.title, symbol: $0.shellSymbol) }
        let nodes = noteNodes + simNodes
        let byRoute = Dictionary(nodes.enumerated().map { ($0.element.route, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var edges = Set<Edge>()
        for (index, note) in notes.enumerated() {
            for link in vault.outgoingLinks(from: note) {
                let resolved = vault.resolve(link: link.target).flatMap { byRoute[.note($0)] }
                if let target = resolved ?? byRoute[.sim(link.target, path: [])], target != index {
                    edges.insert(Edge(index, target))
                }
            }
            for sim in vault.embeddedSimIDs(in: note) {
                if let target = byRoute[.sim(sim, path: [])] { edges.insert(Edge(index, target)) }
            }
        }
        self.init(nodes: nodes, edges: edges.sorted())
    }

    func hasSameLinks(as other: GraphData) -> Bool {
        if nodes.elementsEqual(other.nodes, by: { $0.route == $1.route }) { return edges == other.edges }
        return linksByRoute == other.linksByRoute
    }

    private var linksByRoute: Set<Set<Route>> {
        Set(edges.map { [nodes[$0.a].route, nodes[$0.b].route] })
    }

    func filtered(notes: Bool, sims: Bool, orphans: Bool) -> GraphData {
        guard !nodes.isEmpty else { return self }
        let include = nodes.map { $0.isNote ? notes : sims }
        let linked = edges.filter { include[$0.a] && include[$0.b] }
        var degree = Set<Int>()
        if !orphans {
            for edge in linked {
                degree.insert(edge.a)
                degree.insert(edge.b)
            }
        }
        var remap: [Int: Int] = [:]
        var visible: [Node] = []
        for i in nodes.indices where include[i] && (orphans || degree.contains(i)) {
            remap[i] = visible.count
            visible.append(nodes[i])
        }
        return GraphData(nodes: visible, edges: linked.compactMap { edge in
            guard let a = remap[edge.a], let b = remap[edge.b] else { return nil }
            return Edge(a, b)
        })
    }
}
