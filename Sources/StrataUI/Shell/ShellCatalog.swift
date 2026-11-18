import Foundation
import StrataCore

@MainActor
struct ShellCatalog {
    let model: AppModel
    var fixtureEntries: [Library.Entry]?
    var fixtureNotes: [String: String]?
    var fixturePaletteQuery = ""

    var entries: [Library.Entry] { fixtureEntries ?? model.library.entries }
    var notePaths: [String] { fixtureNotes.map { $0.keys.sorted() } ?? model.vault.allNotes }

    func read(_ path: String) -> String? {
        if let fixtureNotes { return fixtureNotes[path] }
        return model.vault.read(path)
    }

    func resolveNote(_ link: String) -> String? {
        if let fixtureNotes {
            let path = link.hasSuffix(".md") ? link : link + ".md"
            return fixtureNotes[path] != nil ? path : notePaths.first { Self.title($0) == link }
        }
        return model.vault.resolve(link: link)
    }

    var maps: [Library.Entry] {
        entries.filter { $0.kind == .architecture }.sorted { first, second in
            if first.builtIn != second.builtIn { return !first.builtIn }
            return Self.byTitle(first, second)
        }
    }
    var simulators: [Library.Entry] { entries.filter { $0.kind == .sim } }

    var simulatorGroups: [(category: String, entries: [Library.Entry])] {
        let groups = Dictionary(grouping: simulators) { Self.category($0) }
        return groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map {
            ($0, groups[$0, default: []].sorted(by: Self.byTitle))
        }
    }

    var recentNotes: [String] {
        let notes = notePaths
        let paths = Set(notes)
        let visited = ([model.route] + model.backStack.reversed()).compactMap { route -> String? in
            if case .note(let path) = route, paths.contains(path) { return path }
            return nil
        }
        let dates: [(path: String, modified: Date)] = notes.map { path in
            let url = model.vault.root.appendingPathComponent(path)
            let properties = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            return (path, properties?.contentModificationDate ?? Date.distantPast)
        }
        let edited = dates.sorted { a, b in
            a.modified == b.modified ? a.path < b.path : a.modified > b.modified
        }.map(\.path)
        var seen = Set<String>()
        return Array((visited + edited).filter { seen.insert($0).inserted }.prefix(4))
    }

    static func title(_ note: String) -> String {
        ((note as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    static func category(_ entry: Library.Entry) -> String {
        guard let category = entry.category, !category.isEmpty else { return "Other" }
        return category.prefix(1).uppercased() + category.dropFirst()
    }

    private static func byTitle(_ lhs: Library.Entry, _ rhs: Library.Entry) -> Bool {
        lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
}

extension Library.Entry {
    struct ShellIdentity: Hashable {
        let id: String
        let url: URL
    }

    var shellIdentity: ShellIdentity { ShellIdentity(id: id, url: url) }
    var shellSymbol: String { kind == .architecture ? "square.stack.3d.up" : "waveform.path" }
    var shellKind: String { kind == .architecture ? "Architecture map" : "Simulator" }
    var firstError: Diagnostic? { diagnostics.first { $0.severity == .error } }
}
