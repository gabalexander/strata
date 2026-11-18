import Foundation
import StrataCore

enum PaletteGroup: String, CaseIterable {
    case recent = "Recent"
    case commands = "Commands"
    case notes = "Notes"
    case library = "Simulators and maps"
    case nodes = "Nodes in this simulator"
    case glossary = "Glossary"
}

struct PaletteEntry: Identifiable {
    let id: String
    let group: PaletteGroup
    let title: String
    let symbol: String
    var subtitle: String?
    var shortcut: String?
    var keywords = ""
    let action: @MainActor () -> Void
}

@MainActor
struct PaletteResults {
    let catalog: ShellCatalog
    let switching: Bool
    private var model: AppModel { catalog.model }
    private static let packs = GlossaryPacks.available.sorted()
    private static let packTerms = packs.flatMap { pack in GlossaryPacks.load(pack).map { (pack, $0) } }

    func entries() -> [PaletteEntry] {
        let notes = catalog.notePaths.map { path in
            PaletteEntry(id: "note/\(path)", group: .notes, title: ShellCatalog.title(path), symbol: "note.text",
                         subtitle: (path as NSString).deletingLastPathComponent.nilIfEmpty, keywords: path) {
                model.open(.note(path))
            }
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        let library = catalog.entries.filter { $0.manifest != nil }.map { entry in
            PaletteEntry(id: "sim/\(entry.id)", group: .library, title: entry.title, symbol: entry.shellSymbol,
                         subtitle: entry.shellKind, keywords: ([entry.id, entry.category ?? ""] + entry.tags).joined(separator: " ")) {
                model.open(.sim(entry.id, path: []))
            }
        }
        if switching { return notes + library }

        let commands = ShellCommand.allCases.filter { $0 != .palette && $0.isEnabled(in: model) }.map { command in
            PaletteEntry(id: "command/\(command)", group: .commands, title: command.title,
                         symbol: command.symbol, shortcut: command.shortcut) { command.perform(on: model) }
        }
        return commands + screenCommands(model.screenCommands) + notes + library + nodes + glossary
    }

    private func screenCommands(_ items: [MenuItem], path: [String] = []) -> [PaletteEntry] {
        items.enumerated().flatMap { offset, item -> [PaletteEntry] in
            guard item.enabled, !item.isHeader, !item.isSeparator else { return [] }
            if !item.submenu.isEmpty { return screenCommands(item.submenu, path: path + [item.title]) }
            guard let action = item.action else { return [] }
            let parent = path.joined(separator: " › ")
            return [PaletteEntry(id: "screen/\(model.route)/\(parent)/\(item.title)/\(offset)", group: .commands,
                                 title: item.title, symbol: item.icon ?? "command",
                                 subtitle: parent.nilIfEmpty, shortcut: item.shortcut, keywords: parent, action: action)]
        }
    }

    private var currentManifest: Manifest? {
        guard case .sim(let id, _) = model.route else { return nil }
        return catalog.entries.first { $0.id == id }?.manifest
    }

    private var nodes: [PaletteEntry] {
        guard case .sim(let id, let path) = model.route,
              let level = currentManifest?.level(at: path) else { return [] }
        return level.nodes.filter(\.canDeepDive).map { node in
            PaletteEntry(id: "node/\(([id] + path + [node.id]).joined(separator: "/"))",
                         group: .nodes, title: node.label, symbol: node.icon ?? node.kind.symbol,
                         subtitle: "Deep dive", keywords: node.id) {
                if node.inside != nil { model.open(.sim(id, path: path + [node.id])) }
                else if let detail = node.detail { model.open(.sim(detail, path: [])) }
            }
        }
    }

    private var glossary: [PaletteEntry] {
        let current = currentManifest
        let local = current.map { manifest in manifest.terms.map { (manifest.id, $0) } } ?? []
        return (local + Self.packTerms).enumerated().map { offset, pair in
            let (pack, term) = pair
            let isLocal = offset < local.count
            return PaletteEntry(id: "term/\(isLocal ? "local/" : "")\(pack)/\(term.id)",
                                group: .glossary, title: term.term, symbol: "character.book.closed",
                                subtitle: pack, keywords: ([term.id, pack] + (term.match ?? [])).joined(separator: " ")) {
                var manifest = Manifest(id: "glossary", title: "Glossary", root: Level(),
                                        source: .bundled(URL(fileURLWithPath: "/")))
                if isLocal, let current {
                    manifest = current
                    manifest.glossaries += Self.packs.filter { !current.glossaries.contains($0) }
                } else {
                    manifest.glossaries = [pack] + Self.packs.filter { $0 != pack }
                }
                model.overlays.showTerm(term, anchor: .zero, pinned: true, index: TermIndex(manifest: manifest))
            }
        }
    }

    struct Section {
        let group: PaletteGroup
        let entries: [PaletteEntry]
    }

    static func search(_ entries: [PaletteEntry], query: String, recent: [String]) -> [Section] {
        let tokens = normalize(query).split(whereSeparator: \.isWhitespace).map(Array.init)
        let recentRanks = Dictionary(uniqueKeysWithValues: recent.enumerated().map { ($0.element, $0.offset) })
        let rows = entries.enumerated().compactMap { index, entry -> (PaletteEntry, Int, Int)? in
            guard !tokens.isEmpty else { return (entry, 0, index) }
            let title = Array(normalize(entry.title))
            let extra = Array(normalize(entry.keywords))
            var total = 0
            for token in tokens {
                let titleScore = score(token, in: title).map { $0 + 20 }
                let extraScore = score(token, in: extra)
                guard let match = [titleScore, extraScore].compactMap({ $0 }).max() else { return nil }
                total += match
            }
            return (entry, total, index)
        }
        let groups = Dictionary(grouping: rows) { entry, _, _ in
            tokens.isEmpty && recentRanks[entry.id] != nil ? PaletteGroup.recent : entry.group
        }
        let order = PaletteGroup.allCases.enumerated().compactMap { offset, group -> (Int, PaletteGroup, Int)? in
            guard let best = groups[group]?.map(\.1).max() else { return nil }
            return (offset, group, best)
        }.sorted { lhs, rhs in
            lhs.2 == rhs.2 ? lhs.0 < rhs.0 : lhs.2 > rhs.2
        }
        return order.map { _, group, _ in
            let sorted = groups[group, default: []].sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                let first = recentRanks[a.0.id] ?? .max
                let second = recentRanks[b.0.id] ?? .max
                return first == second ? a.2 < b.2 : first < second
            }
            let limit = tokens.isEmpty || groups.count > 1 ? 7 : 36
            return Section(group: group, entries: sorted.prefix(limit).map(\.0))
        }
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    /// Find the best subsequence, rewarding word starts and consecutive matches.
    private static func score(_ query: [Character], in text: [Character]) -> Int? {
        guard text.count >= query.count else { return nil }
        var previous = Array(repeating: Int.min, count: text.count)
        for (index, character) in query.enumerated() {
            var next = Array(repeating: Int.min, count: text.count)
            var best = Int.min
            for column in text.indices {
                if column > 0 {
                    if best != Int.min { best -= 1 }
                    best = max(best, previous[column - 1])
                }
                guard text[column] == character else { continue }
                let boundary = column == 0 || !text[column - 1].isLetter && !text[column - 1].isNumber
                let bonus = boundary ? 7 : 0
                if index == 0 {
                    next[column] = 10 + bonus + (column == 0 ? 8 : 0) - min(column, 30)
                } else if best != Int.min {
                    let contiguous = previous[column - 1]
                    let spaced = best + bonus
                    next[column] = 10 + max(spaced, contiguous == Int.min ? Int.min : contiguous + 10)
                }
            }
            previous = next
        }
        guard let best = previous.max(), best != Int.min else { return nil }
        return best + (query == text ? 16 : 0)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
