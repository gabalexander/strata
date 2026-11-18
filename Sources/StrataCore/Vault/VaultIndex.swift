import CryptoKit
import Foundation

public struct NoteSearchGroup: Identifiable, Sendable {
    public let path: String
    public let hits: [SearchHit]
    public var id: String { path }
}

/// A value snapshot of the vault. Workers reconcile a copy before publishing it.
struct VaultIndex: Sendable {
    let root: URL
    private var files: FileManager { .default }
    private(set) var items: [VaultItem] = []
    private(set) var notes: [String: IndexedNote] = [:]
    private(set) var folders: Set<String> = []
    private var unreadable: Set<String> = []
    private(set) var versions: [String: NoteVersion] = [:]
    private(set) var pathsByName: [String: Set<String>] = [:]
    private var sourcesByTarget: [String: Set<String>] = [:]
    private(set) var orderedPaths: [String] = []

    init(root: URL) { self.root = root }

    func search(_ input: String, checkCancellation: () throws -> Void) rethrows -> [NoteSearchGroup] {
        try checkCancellation()
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var titleMatches: [NoteSearchGroup] = []
        var bodyMatches: [NoteSearchGroup] = []
        let batchSize = 128
        for path in orderedPaths {
            try checkCancellation()
            guard let note = notes[path] else { continue }
            var hits: [SearchHit] = []
            for start in stride(from: 0, to: note.lines.count, by: batchSize) {
                try checkCancellation()
                for line in start..<min(start + batchSize, note.lines.count) {
                    guard note.lines[line].range(of: query, options: .caseInsensitive) != nil else { continue }
                    hits.append(SearchHit(path: path, line: line + 1, excerpt: note.excerpt(at: line, matching: query)))
                }
            }
            if Self.title(path).range(of: query, options: .caseInsensitive) != nil {
                if hits.isEmpty { hits.append(SearchHit(path: path, line: 1, excerpt: note.excerpt(at: 0))) }
                titleMatches.append(NoteSearchGroup(path: path, hits: hits))
            } else if !hits.isEmpty {
                bodyMatches.append(NoteSearchGroup(path: path, hits: hits))
            }
        }
        return titleMatches + bodyMatches
    }

    func containsNote(_ path: String) -> Bool {
        notes[path] != nil || unreadable.contains(path)
    }

    static func readNote(at url: URL) -> NoteRead {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let modified = attributes[.modificationDate] as? Date else { return .unreadable }
            var encoding = String.Encoding.utf8
            let text = try String(contentsOf: url, usedEncoding: &encoding)
            let after = try FileManager.default.attributesOfItem(atPath: url.path)
            guard after[.modificationDate] as? Date == modified,
                  after[.systemFileNumber] as? NSNumber == attributes[.systemFileNumber] as? NSNumber else { return .unreadable }
            let version = NoteVersion(contentHash: Data(SHA256.hash(data: Data(text.utf8))), modifiedAt: modified)
            return .readable(text, version: version, encoding: encoding)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return .missing
        } catch {
            return .unreadable
        }
    }

    /// Copies the seed notes (Resources/Vault) into an empty or missing vault directory.
    func seedIfEmpty(from seed: URL) {
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
    }

    func resolveTarget(_ target: String) -> String? {
        Self.resolveTarget(target, contains: containsNote, pathsByName: pathsByName)
    }

    static func resolveTarget(_ target: String, contains: (String) -> Bool,
                                      pathsByName: [String: Set<String>]) -> String? {
        guard !target.isEmpty else { return nil }
        let exact = isMarkdown(target) ? target : target + ".md"
        if contains(exact) { return exact }
        guard !target.contains("/") else { return nil }
        return pathsByName[title(target).lowercased()]?.min {
            let firstDepth = $0.split(separator: "/").count
            let secondDepth = $1.split(separator: "/").count
            return firstDepth == secondDepth ? alphabetical($0, $1) : firstDepth < secondDepth
        }
    }

    func sources(for path: String) -> Set<String> {
        let fullPath = String(path.dropLast(3)).lowercased()
        return (sourcesByTarget[fullPath] ?? []).union(sourcesByTarget[Self.title(path).lowercased()] ?? [])
    }

    func backlinkRange(from source: String, to path: String) -> NSRange? {
        notes[source]?.links.first { resolveTarget($0.target) == path }?.range
    }

    private mutating func replaceNote(at path: String, with state: NoteRead) -> Bool {
        let wasUnreadable = unreadable.contains(path)
        let previousVersion = versions[path]
        let sameText = previousVersion?.contentHash == state.version?.contentHash
        versions[path] = state.version
        guard !sameText || wasUnreadable != (state == .unreadable) else { return previousVersion != state.version }
        let name = Self.title(path).lowercased()
        if let old = notes.removeValue(forKey: path) {
            for key in Set(old.links.map { Self.linkKey($0.target) }) {
                sourcesByTarget[key]?.remove(path)
                if sourcesByTarget[key]?.isEmpty == true { sourcesByTarget[key] = nil }
            }
        }
        unreadable.remove(path)
        if state == .missing {
            pathsByName[name]?.remove(path)
            if pathsByName[name]?.isEmpty == true { pathsByName[name] = nil }
        } else {
            pathsByName[name, default: []].insert(path)
            if let text = state.text {
                let note = IndexedNote(text, path: path)
                notes[path] = note
                for key in Set(note.links.map { Self.linkKey($0.target) }) {
                    sourcesByTarget[key, default: []].insert(path)
                }
            } else {
                unreadable.insert(path)
            }
        }
        return true
    }

    mutating func reload() -> Bool {
        let listing = scan(root)
        return reconcile(listing.notes, removed: Set(orderedPaths).subtracting(listing.notes.keys), folders: listing.folders)
    }

    mutating func refresh(paths: Set<String>) -> Bool {
        if Set(paths.map { $0.lowercased() }).count < paths.count { return reload() }
        var nextFolders = folders
        var changed: [String: NoteRead] = [:]
        var removed: Set<String> = []
        for path in paths.sorted() {
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
                removed.formUnion(orderedPaths.filter { ($0 == path || $0.hasPrefix(path + "/")) && listing.notes[$0] == nil })
                changed.merge(listing.notes) { _, new in new }
            } else if Self.isMarkdown(path) {
                if type?.isRegularFile == true, let url = itemURL(path) {
                    changed[path] = Self.readNote(at: url)
                    var parent = Self.parent(path)
                    while !parent.isEmpty {
                        nextFolders.insert(parent)
                        parent = Self.parent(parent)
                    }
                } else { removed.insert(path) }
            }
        }
        return reconcile(changed, removed: removed.subtracting(changed.keys), folders: nextFolders)
    }

    private mutating func reconcile(_ changed: [String: NoteRead], removed: Set<String>, folders nextFolders: Set<String>) -> Bool {
        var structureChanged = folders != nextFolders
        var contentChanged = false
        for path in removed {
            if replaceNote(at: path, with: .missing) { structureChanged = true }
        }
        for (path, content) in changed {
            if containsNote(path) != (content != .missing) { structureChanged = true }
            if replaceNote(at: path, with: content) { contentChanged = true }
        }
        if structureChanged {
            folders = nextFolders
            orderedPaths = Set(notes.keys).union(unreadable).sorted(by: Self.alphabetical)
            rebuildTree()
        }
        return structureChanged || contentChanged
    }

    private func scan(_ directory: URL) -> (folders: Set<String>, notes: [String: NoteRead]) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let contents = files.enumerator(at: directory, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles) else {
            return ([], [:])
        }
        var folders: Set<String> = []
        var found: [String: NoteRead] = [:]
        for case let url as URL in contents {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true, let path = relativePath(of: url) else {
                contents.skipDescendants()
                continue
            }
            if values.isDirectory == true { folders.insert(path) }
            else if values.isRegularFile == true, Self.isMarkdown(path) { found[path] = Self.readNote(at: url) }
        }
        return (folders, found)
    }

    private mutating func rebuildTree() {
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

    func itemURL(_ path: String) -> URL? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("\0") }) else { return nil }
        var url = root
        for part in parts {
            url.appendPathComponent(String(part))
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return nil }
        }
        return url
    }

    func relativePath(of url: URL) -> String? {
        let value = url.standardizedFileURL.path
        let prefix = root.path + "/"
        if value.hasPrefix(prefix) { return String(value.dropFirst(prefix.count)) }
        let canonical = root.resolvingSymlinksInPath().path + "/"
        if value.hasPrefix(canonical) { return String(value.dropFirst(canonical.count)) }
        return nil
    }

    static func alphabetical(_ lhs: String, _ rhs: String) -> Bool {
        let order = lhs.localizedStandardCompare(rhs)
        return order == .orderedSame ? lhs < rhs : order == .orderedAscending
    }

    static func isMarkdown(_ path: String) -> Bool { (path as NSString).pathExtension.lowercased() == "md" }
    static func parent(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
    static func title(_ path: String) -> String { linkKey((path as NSString).lastPathComponent, folded: false) }
    static func join(_ folder: String, _ name: String) -> String { folder.isEmpty ? name : folder + "/" + name }

    static func linkKey(_ target: String, folded: Bool = true) -> String {
        let key = isMarkdown(target) ? String(target.dropLast(3)) : target
        return folded ? key.lowercased() : key
    }

}
