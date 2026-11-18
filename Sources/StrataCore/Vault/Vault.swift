import AppKit
import Foundation
import Observation

public struct VaultItem: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public var path: String          // relative to the vault root, "/"-separated, e.g. "Work/checkout.md"
    public var name: String          // display name (no .md)
    public var isFolder: Bool
    public var children: [VaultItem]
    public init(path: String, name: String, isFolder: Bool, children: [VaultItem] = []) {
        self.path = path; self.name = name; self.isFolder = isFolder; self.children = children
    }
}

public struct SearchHit: Identifiable, Sendable, Hashable {
    public var id: String { "\(path):\(line)" }
    public var path: String
    public var line: Int
    public var excerpt: String
    public init(path: String, line: Int, excerpt: String) { self.path = path; self.line = line; self.excerpt = excerpt }
}

@MainActor
@Observable
public final class Vault {
    public let root: URL
    /// Folders first, then notes, alphabetical; only .md files and folders (hidden files skipped).
    public private(set) var items: [VaultItem] = []
    public private(set) var revision = 0

    @ObservationIgnored private let files = FileManager.default
    @ObservationIgnored private var notes: [String: IndexedNote] = [:]
    @ObservationIgnored private var folders: Set<String> = []
    @ObservationIgnored private var pathsByName: [String: Set<String>] = [:]
    @ObservationIgnored private var sourcesByTarget: [String: Set<String>] = [:]
    @ObservationIgnored private var orderedPaths: [String] = []
    @ObservationIgnored private var watcher: VaultWatcher?

    public init(root: URL) {
        self.root = root.standardizedFileURL
        reload()
    }

    public var allNotes: [String] {
        _ = revision
        return orderedPaths
    }

    public func read(_ path: String) -> String? {
        _ = revision
        guard Self.isMarkdown(path), let url = itemURL(path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    public func write(_ path: String, _ text: String) {
        _ = save(path, text)
    }

    /// Saves atomically and updates the index before returning.
    @discardableResult public func save(_ path: String, _ text: String) -> Bool {
        guard Self.isMarkdown(path), let url = itemURL(path) else { return false }
        do {
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch { return false }
        refresh(paths: [path])
        return true
    }

    /// Creates "<folder>/<name>.md" (unique name if taken) and returns its path.
    /// An empty result means the file could not be created.
    @discardableResult public func createNote(in folder: String?, name: String, text: String = "") -> String {
        let base = Self.cleanName(name, stripExtension: true) ?? "Untitled"
        let data = Data(text.utf8)
        return createUnique(in: folder, base: base, suffix: ".md") {
            try data.write(to: $0, options: .withoutOverwriting)
        }
    }

    @discardableResult public func createFolder(in folder: String?, name: String) -> String {
        let base = Self.cleanName(name, stripExtension: false) ?? "New folder"
        return createUnique(in: folder, base: base, suffix: "") {
            try files.createDirectory(at: $0, withIntermediateDirectories: false)
        }
    }

    /// Returns the new path, or nil if the rename failed. Updates [[links]] to the note.
    @discardableResult public func rename(_ path: String, to newName: String) -> String? {
        let isFolder = folders.contains(path)
        guard isFolder || notes[path] != nil,
              let name = Self.cleanName(newName, stripExtension: !isFolder) else { return nil }
        return relocate(path, to: Self.join(Self.parent(path), name + (isFolder ? "" : ".md")))
    }

    /// Moves an item to a different vault folder and rewrites links to its notes.
    @discardableResult public func move(_ path: String, toFolder folder: String?) -> String? {
        let directory = folder ?? ""
        guard directory.isEmpty || folders.contains(directory),
              let name = path.split(separator: "/").last else { return nil }
        return relocate(path, to: Self.join(directory, String(name)))
    }

    /// Moves to the macOS Trash (recoverable).
    public func trash(_ path: String) { _ = try? moveToTrash(path) }

    @discardableResult public func moveToTrash(_ path: String) throws -> URL? {
        guard notes[path] != nil || folders.contains(path), let url = itemURL(path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        var destination: NSURL?
        try files.trashItem(at: url, resultingItemURL: &destination)
        refresh(paths: [path])
        return destination as URL?
    }

    public func reveal(_ path: String) {
        guard let url = itemURL(path), files.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Resolves the exact vault path first, then the case-insensitive note name.
    /// The caller can check the library when there is no matching note.
    public func resolve(link: String) -> String? {
        _ = revision
        let target = link.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let name = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return resolveTarget(name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func backlinks(to path: String) -> [String] {
        _ = revision
        guard notes[path] != nil else { return [] }
        return sources(for: path).filter { $0 != path && backlinkRange(from: $0, to: path) != nil }
            .sorted(by: Self.alphabetical)
    }

    public func backlinkExcerpt(from source: String, to path: String) -> String? {
        _ = revision
        guard let note = notes[source], let hit = backlinkRange(from: source, to: path) else { return nil }
        let text = note.text as NSString
        return text.substring(with: text.lineRange(for: hit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Wiki links in source order, including aliases and heading fragments.
    public func outgoingLinks(from path: String) -> [NoteSyntax.WikiLink] {
        _ = revision
        return notes[path]?.links ?? []
    }

    /// Library IDs referenced by strata fences in source order.
    public func embeddedSimIDs(in path: String) -> [String] {
        _ = revision
        return notes[path]?.embeds ?? []
    }

    public func search(_ query: String) -> [SearchHit] {
        _ = revision
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var titleMatches: [SearchHit] = []
        var bodyMatches: [SearchHit] = []
        for path in orderedPaths {
            guard let note = notes[path] else { continue }
            let hits = note.lines.indices.compactMap { index -> SearchHit? in
                guard note.lines[index].range(of: query, options: .caseInsensitive) != nil else { return nil }
                return SearchHit(path: path, line: index + 1, excerpt: note.excerpt(at: index, matching: query))
            }
            if Self.title(path).range(of: query, options: .caseInsensitive) != nil {
                titleMatches += hits.isEmpty ? [SearchHit(path: path, line: 1, excerpt: note.excerpt(at: 0))] : hits
            } else {
                bodyMatches += hits
            }
        }
        return titleMatches + bodyMatches
    }

    /// The personal note attached to a node of a sim: "Sims/<sim>/<level path…>/<node>.md".
    public func nodeNotePath(sim: String, levelPath: [String], node: String) -> String {
        (["Sims", sim] + levelPath + [node]).joined(separator: "/") + ".md"
    }

    public func hasNote(_ path: String) -> Bool {
        _ = revision
        return notes[path] != nil
    }

    /// Resolves a local attachment relative to its note, keeping access within the vault.
    public func attachmentURL(_ path: String, relativeTo note: String) -> URL? {
        let decoded = path.removingPercentEncoding ?? path
        guard !decoded.hasPrefix("/"), URLComponents(string: decoded)?.scheme == nil else { return nil }
        let url = root.appendingPathComponent(Self.join(Self.parent(note), decoded)).standardizedFileURL
        guard let relative = relativePath(of: url), let safe = itemURL(relative),
              (try? safe.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return safe
    }

    /// Copies the seed notes (Resources/Vault) into an empty or missing vault directory.
    public func seedIfEmpty(from seed: URL? = StrataResources.url("Vault")) {
        guard let seed else { return }
        if files.fileExists(atPath: root.path) {
            guard let contents = try? files.contentsOfDirectory(atPath: root.path), contents.isEmpty else { return }
        }
        do {
            for url in try files.contentsOfDirectory(at: seed, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                try files.createDirectory(at: root, withIntermediateDirectories: true)
                let destination = root.appendingPathComponent(url.lastPathComponent)
                try files.copyItem(at: url, to: destination)
            }
        } catch {
            // Index any files already copied if the seed could only be installed in part.
        }
        reload()
    }

    /// Starts watching the vault for outside changes (an agent editing a note).
    public func startWatching() {
        guard watcher == nil else { return }
        try? files.createDirectory(at: root, withIntermediateDirectories: true)
        let watchedRoot = root.resolvingSymlinksInPath()
        var roots = [watchedRoot.path, root.path]
        if let canonical = realpath(watchedRoot.path, nil) {
            roots.append(String(cString: canonical))
            free(canonical)
        }
        let prefixes = Set(roots.map { $0 + "/" })
        watcher = VaultWatcher(root: watchedRoot) { [weak self] paths, fullScan in
            guard let self else { return }
            if fullScan { self.reload() }
            else {
                self.refresh(paths: paths.compactMap { path in
                    prefixes.first(where: path.hasPrefix).map { String(path.dropFirst($0.count)) }
                })
            }
        }
        reload()
    }

    private func relocate(_ path: String, to newPath: String) -> String? {
        guard notes[path] != nil || folders.contains(path),
              let oldURL = itemURL(path), let newURL = itemURL(newPath),
              !newPath.hasPrefix(path + "/") else { return nil }
        guard path != newPath else { return path }

        let caseChange = path.caseInsensitiveCompare(newPath) == .orderedSame
            && files.fileExists(atPath: newURL.path)
            && (try? files.contentsOfDirectory(atPath: newURL.deletingLastPathComponent().path)
                .contains(newURL.lastPathComponent)) == false
        guard caseChange || !files.fileExists(atPath: newURL.path) else { return nil }

        let moves = Dictionary(uniqueKeysWithValues: orderedPaths.compactMap { note -> (String, String)? in
            guard note == path || note.hasPrefix(path + "/") else { return nil }
            return (note, newPath + note.dropFirst(path.count))
        })

        let affected = moves.keys.reduce(into: Set<String>()) { $0.formUnion(sources(for: $1)) }
        var rewrites: [(path: String, before: String, after: String)] = []
        for source in affected {
            guard let current = read(source) else { return nil }
            let note = notes[source].flatMap { $0.text == current ? $0 : nil } ?? IndexedNote(current, path: source)
            let edited = NSMutableString(string: current)
            for link in note.links.reversed() {
                guard let destination = resolveTarget(link.target), let replacement = moves[destination] else { continue }
                let fullPath = String(replacement.dropLast(3))
                let name = Self.title(replacement)
                let usePath = link.target.contains("/") || (pathsByName[name.lowercased()] ?? [])
                    .contains(where: { $0 != destination && moves[$0] == nil })
                let newTarget = (usePath ? fullPath : name) + (Self.isMarkdown(link.target) ? ".md" : "")
                edited.replaceCharacters(in: link.targetRange, with: newTarget)
            }
            let after = edited as String
            if after != current { rewrites.append((source, current, after)) }
        }

        var moved = false
        var applied: [(url: URL, before: String)] = []
        do {
            try moveItem(from: oldURL, to: newURL, caseChange: caseChange)
            moved = true
            for rewrite in rewrites {
                guard let url = itemURL(moves[rewrite.path] ?? rewrite.path),
                      try String(contentsOf: url, encoding: .utf8) == rewrite.before else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try rewrite.after.write(to: url, atomically: true, encoding: .utf8)
                applied.append((url, rewrite.before))
            }
        } catch {
            for rewrite in applied.reversed() { try? rewrite.before.write(to: rewrite.url, atomically: true, encoding: .utf8) }
            if moved { try? moveItem(from: newURL, to: oldURL, caseChange: caseChange) }
            reload()
            return nil
        }
        if caseChange { reload() }
        else { refresh(paths: [path, newPath] + rewrites.map(\.path)) }
        return newPath
    }

    private func moveItem(from source: URL, to destination: URL, caseChange: Bool) throws {
        guard caseChange else {
            try files.moveItem(at: source, to: destination)
            return
        }
        let temporary = source.deletingLastPathComponent().appendingPathComponent(".strata-\(UUID().uuidString)")
        try files.moveItem(at: source, to: temporary)
        do { try files.moveItem(at: temporary, to: destination) }
        catch {
            try? files.moveItem(at: temporary, to: source)
            throw error
        }
    }

    private func resolveTarget(_ target: String) -> String? {
        guard !target.isEmpty else { return nil }
        let exact = Self.isMarkdown(target) ? target : target + ".md"
        if notes[exact] != nil { return exact }
        guard !target.contains("/") else { return nil }
        return pathsByName[Self.title(target).lowercased()]?.min {
            let firstDepth = $0.split(separator: "/").count
            let secondDepth = $1.split(separator: "/").count
            return firstDepth == secondDepth ? Self.alphabetical($0, $1) : firstDepth < secondDepth
        }
    }

    private func sources(for path: String) -> Set<String> {
        let fullPath = String(path.dropLast(3)).lowercased()
        return (sourcesByTarget[fullPath] ?? []).union(sourcesByTarget[Self.title(path).lowercased()] ?? [])
    }

    private func backlinkRange(from source: String, to path: String) -> NSRange? {
        notes[source]?.links.first { resolveTarget($0.target) == path }?.range
    }

    private func replaceNote(at path: String, with text: String?) -> Bool {
        guard notes[path]?.text != text else { return false }
        let name = Self.title(path).lowercased()
        if let old = notes.removeValue(forKey: path) {
            for key in Set(old.links.map { Self.linkKey($0.target) }) {
                sourcesByTarget[key]?.remove(path)
                if sourcesByTarget[key]?.isEmpty == true { sourcesByTarget[key] = nil }
            }
            pathsByName[name]?.remove(path)
            if pathsByName[name]?.isEmpty == true { pathsByName[name] = nil }
        }
        if let text {
            let note = IndexedNote(text, path: path)
            notes[path] = note
            pathsByName[name, default: []].insert(path)
            for key in Set(note.links.map { Self.linkKey($0.target) }) {
                sourcesByTarget[key, default: []].insert(path)
            }
        }
        return true
    }

    private func reload() {
        let listing = scan(root)
        reconcile(listing.notes, removed: Set(notes.keys).subtracting(listing.notes.keys), folders: listing.folders)
    }

    private func refresh(paths: [String]) {
        let distinct = Set(paths)
        if Set(distinct.map { $0.lowercased() }).count < distinct.count {
            reload()
            return
        }
        var nextFolders = folders
        var changed: [String: String] = [:]
        var removed: Set<String> = []
        for path in distinct.sorted() {
            let type = try? itemURL(path)?.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if type?.isDirectory == true || folders.contains(path) {
                let listing = itemURL(path).flatMap { type?.isDirectory == true ? scan($0) : nil } ?? (folders: [], notes: [:])
                nextFolders.subtract(folders.filter { $0 == path || $0.hasPrefix(path + "/") })
                nextFolders.formUnion(listing.folders)
                if type?.isDirectory == true {
                    var folder = path
                    while !folder.isEmpty {
                        nextFolders.insert(folder)
                        folder = Self.parent(folder)
                    }
                }
                removed.formUnion(notes.keys.filter { ($0 == path || $0.hasPrefix(path + "/")) && listing.notes[$0] == nil })
                changed.merge(listing.notes) { _, new in new }
            } else if Self.isMarkdown(path) {
                if type?.isRegularFile == true, let url = itemURL(path), let current = try? String(contentsOf: url, encoding: .utf8) {
                    changed[path] = current
                    var parent = Self.parent(path)
                    while !parent.isEmpty {
                        nextFolders.insert(parent)
                        parent = Self.parent(parent)
                    }
                } else { removed.insert(path) }
            }
        }
        reconcile(changed, removed: removed.subtracting(changed.keys), folders: nextFolders)
    }

    private func reconcile(_ changed: [String: String], removed: Set<String>, folders nextFolders: Set<String>) {
        var structureChanged = folders != nextFolders || !removed.isDisjoint(with: notes.keys)
        var contentChanged = false
        for path in removed {
            if replaceNote(at: path, with: nil) { contentChanged = true }
        }
        for (path, content) in changed {
            if notes[path] == nil { structureChanged = true }
            if replaceNote(at: path, with: content) { contentChanged = true }
        }
        if structureChanged {
            folders = nextFolders
            orderedPaths = notes.keys.sorted(by: Self.alphabetical)
            rebuildTree()
        }
        if structureChanged || contentChanged { revision += 1 }
    }

    private func scan(_ directory: URL) -> (folders: Set<String>, notes: [String: String]) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let contents = files.enumerator(at: directory, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles) else {
            return ([], [:])
        }
        var folders: Set<String> = []
        var found: [String: String] = [:]
        for case let url as URL in contents {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true, let path = relativePath(of: url) else {
                contents.skipDescendants()
                continue
            }
            if values.isDirectory == true { folders.insert(path) }
            else if values.isRegularFile == true, Self.isMarkdown(path),
                    let text = try? String(contentsOf: url, encoding: .utf8) { found[path] = text }
        }
        return (folders, found)
    }

    private func rebuildTree() {
        let children = Dictionary(grouping: Array(folders) + orderedPaths, by: Self.parent)
        func build(_ parent: String) -> [VaultItem] {
            (children[parent] ?? []).sorted {
                let firstIsFolder = folders.contains($0)
                let secondIsFolder = folders.contains($1)
                if firstIsFolder != secondIsFolder { return firstIsFolder }
                return Self.alphabetical($0, $1)
            }.map { path in
                if folders.contains(path) {
                    return VaultItem(path: path, name: (path as NSString).lastPathComponent, isFolder: true, children: build(path))
                }
                return VaultItem(path: path, name: Self.title(path), isFolder: false)
            }
        }
        items = build("")
    }

    private func createUnique(in folder: String?, base: String, suffix: String, create: (URL) throws -> Void) -> String {
        let folder = folder ?? ""
        guard let parent = folder.isEmpty ? root : itemURL(folder) else { return "" }
        do { try files.createDirectory(at: parent, withIntermediateDirectories: true) }
        catch { return "" }

        for number in 1...Int.max {
            let name = (number == 1 ? base : "\(base) \(number)") + suffix
            let url = parent.appendingPathComponent(name)
            if files.fileExists(atPath: url.path) || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                continue
            }
            do {
                try create(url)
                let path = Self.join(folder, name)
                refresh(paths: [path])
                return path
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            } catch { return "" }
        }
        return ""
    }

    private func itemURL(_ path: String) -> URL? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("\0") }) else { return nil }
        var url = root
        for part in parts {
            url.appendPathComponent(String(part))
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return nil }
        }
        return url
    }

    private func relativePath(of url: URL) -> String? {
        let value = url.standardizedFileURL.path
        for directory in [root.path, root.resolvingSymlinksInPath().path] where value.hasPrefix(directory + "/") {
            return String(value.dropFirst(directory.count + 1))
        }
        return nil
    }

    private static func alphabetical(_ lhs: String, _ rhs: String) -> Bool {
        let order = lhs.localizedStandardCompare(rhs)
        return order == .orderedSame ? lhs < rhs : order == .orderedAscending
    }

    private static func isMarkdown(_ path: String) -> Bool { (path as NSString).pathExtension.lowercased() == "md" }
    private static func parent(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
    private static func title(_ path: String) -> String { linkKey((path as NSString).lastPathComponent, folded: false) }
    private static func join(_ folder: String, _ name: String) -> String { folder.isEmpty ? name : folder + "/" + name }

    private static func linkKey(_ target: String, folded: Bool = true) -> String {
        let key = isMarkdown(target) ? String(target.dropLast(3)) : target
        return folded ? key.lowercased() : key
    }

    private static func cleanName(_ name: String, stripExtension: Bool) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = stripExtension ? linkKey(name, folded: false) : name
        guard !base.isEmpty, !base.hasPrefix("."), !base.contains("/"),
              base.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return base
    }
}
