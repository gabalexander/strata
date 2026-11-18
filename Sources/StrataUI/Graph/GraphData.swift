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
        let notes = catalog.notePaths
        let simulators = catalog.entries.filter { $0.manifest != nil }
        let noteNodes = notes.map { Node(route: .note($0), title: ShellCatalog.title($0), symbol: "note.text") }
        let simNodes = simulators.map { Node(route: .sim($0.id, path: []), title: $0.title, symbol: $0.shellSymbol) }
        let nodes = noteNodes + simNodes
        let byRoute = Dictionary(nodes.enumerated().map { ($0.element.route, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var edges = Set<Edge>()
        for (index, note) in notes.enumerated() {
            guard let text = catalog.read(note) else { continue }
            let references = GraphReferences(text, note: note)
            for link in references.links {
                let resolved = catalog.resolveNote(link).flatMap { byRoute[.note($0)] }
                if let target = resolved ?? byRoute[.sim(link, path: [])], target != index {
                    edges.insert(Edge(index, target))
                }
            }
            for sim in references.embeds {
                if let target = byRoute[.sim(sim, path: [])] { edges.insert(Edge(index, target)) }
            }
        }
        self.init(nodes: nodes, edges: edges.sorted())
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

private struct GraphReferences {
    private struct Fence {
        let marker: Character
        let count: Int
        let isStrata: Bool
        var lines: [Substring] = []
    }

    private static let wikiLink = #/\[\[([^\]\n]+)\]\]/#
    var links: Set<String> = []
    var embeds: Set<String> = []

    init(_ text: String, note: String) {
        var fence: Fence?
        var embedIndex = 0
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.drop(while: \.isWhitespace)
            if var open = fence {
                let marks = trimmed.prefix { $0 == open.marker }
                if marks.count >= open.count, trimmed.dropFirst(marks.count).allSatisfy(\.isWhitespace) {
                    if open.isStrata {
                        let (embed, _) = ManifestParser.parseEmbed(open.lines.joined(separator: "\n"), note: note, index: embedIndex)
                        if case .library(let id) = embed?.target { embeds.insert(id) }
                        embedIndex += 1
                    }
                    fence = nil
                } else if open.isStrata {
                    open.lines.append(line)
                    fence = open
                }
                continue
            }

            if let marker = trimmed.first, marker == "`" || marker == "~" {
                let marks = trimmed.prefix { $0 == marker }
                if marks.count >= 3 {
                    let info = trimmed.dropFirst(marks.count).trimmingCharacters(in: .whitespaces)
                    fence = Fence(marker: marker, count: marks.count, isStrata: info == "strata")
                    continue
                }
            }

            for match in line.matches(of: Self.wikiLink) {
                let target = match.1.prefix { $0 != "|" && $0 != "#" }.trimmingCharacters(in: .whitespaces)
                if !target.isEmpty { links.insert(target) }
            }
        }
    }
}
