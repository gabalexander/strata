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
        var seen = Set<String>()
        return Array((visited + recentlyEdited(notes)).filter { seen.insert($0).inserted }.prefix(4))
    }

    private struct EditedKey: Equatable {
        let root: URL
        let revision: Int
        let notes: [String]
    }
    private static var edited: (key: EditedKey, paths: [String])?

    /// The four most recently modified notes. Reading every note's modification date is a disk call
    /// per note, so the answer is kept until the vault changes instead of redone on every render.
    private func recentlyEdited(_ notes: [String]) -> [String] {
        let key = EditedKey(root: model.vault.root, revision: model.vault.revision, notes: notes)
        if let edited = Self.edited, edited.key == key { return edited.paths }
        let dates: [(path: String, modified: Date)] = notes.map { path in
            let url = model.vault.root.appendingPathComponent(path)
            let properties = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            return (path, properties?.contentModificationDate ?? Date.distantPast)
        }
        let paths = Array(dates.sorted { a, b in
            a.modified == b.modified ? a.path < b.path : a.modified > b.modified
        }.map(\.path).prefix(4))
        Self.edited = (key, paths)
        return paths
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
