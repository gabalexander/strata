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

public struct NoteVersion: Codable, Equatable, Sendable {
    let contentHash: Data
    let modifiedAt: Date
}

public enum NoteRead: Equatable, Sendable {
    case missing
    case unreadable
    case readable(String, version: NoteVersion, encoding: String.Encoding)

    public var text: String? {
        if case .readable(let text, _, _) = self { return text }
        return nil
    }

    public var version: NoteVersion? {
        if case .readable(_, let version, _) = self { return version }
        return nil
    }
}

public enum NoteSave: Sendable {
    case saved(NoteRead)
    case changed(NoteRead)
    case failed
}

@MainActor
@Observable
public final class Vault {
    public let root: URL
    /// Folders first, then notes, alphabetical; only .md files and folders (hidden files skipped).
    public var items: [VaultItem] {
        _ = revision
        return index.items
    }
    public private(set) var revision = 0

    @ObservationIgnored private let files = FileManager.default
    @ObservationIgnored private var watcher: VaultWatcher?

    @ObservationIgnored private var index: VaultIndex
    @ObservationIgnored private var indexing = false
    @ObservationIgnored private var pendingScan = false
    @ObservationIgnored private var pendingPaths: Set<String> = []
    @ObservationIgnored private var mutationGeneration = 0

    public convenience init(root: URL) { self.init(root: root, loadImmediately: true) }

    public init(root: URL, loadImmediately: Bool) {
        self.root = root.standardizedFileURL
        index = VaultIndex(root: self.root)
        if loadImmediately { reload() }
    }

    public var allNotes: [String] {
        _ = revision
        return index.orderedPaths
    }

    public func read(_ path: String) -> String? { readNote(path).text }

    /// Inspects disk directly, including notes the watcher has not indexed yet.
    public func readNote(_ path: String) -> NoteRead {
        _ = revision
        guard VaultIndex.isMarkdown(path), let url = index.itemURL(path) else { return .unreadable }
        return VaultIndex.readNote(at: url)
    }

    /// Saves an editor draft only if the current file still matches the editor's base.
    public func saveEdit(_ path: String, text: String, basedOn base: NoteVersion) -> NoteSave {
        guard VaultIndex.isMarkdown(path), let url = index.itemURL(path) else { return .failed }
        let disk = VaultIndex.readNote(at: url)
        guard disk != .unreadable else { return .failed }
        guard disk.version == base else { return .changed(disk) }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return .failed
        }
        let saved = VaultIndex.readNote(at: url)
        refresh(paths: [path])
        guard saved != .unreadable else { return .failed }
        return saved.text == text ? .saved(saved) : .changed(saved)
    }

    /// Creates a note at exactly this path, failing if anything already exists there.
    @discardableResult public func createNote(at path: String, text: String = "") -> Bool {
        guard VaultIndex.isMarkdown(path), let url = index.itemURL(path) else { return false }
        do {
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        } catch { return false }
        refresh(paths: [path])
        return true
    }

    public func write(_ path: String, _ text: String) {
        _ = save(path, text)
    }

    /// Saves atomically and updates the index before returning.
    @discardableResult public func save(_ path: String, _ text: String) -> Bool {
        guard VaultIndex.isMarkdown(path), let url = index.itemURL(path) else { return false }
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
        reload()
        let isFolder = index.folders.contains(path)
        guard isFolder || index.containsNote(path),
              let name = Self.cleanName(newName, stripExtension: !isFolder) else { return nil }
        return relocate(path, to: VaultIndex.join(VaultIndex.parent(path), name + (isFolder ? "" : ".md")))
    }

    /// Moves an item to a different vault folder and rewrites links to its notes.
    @discardableResult public func move(_ path: String, toFolder folder: String?) -> String? {
        reload()
        let directory = folder ?? ""
        guard directory.isEmpty || index.folders.contains(directory),
              let name = path.split(separator: "/").last else { return nil }
        return relocate(path, to: VaultIndex.join(directory, String(name)))
    }

    /// Moves to the macOS Trash (recoverable).
    public func trash(_ path: String) { _ = try? moveToTrash(path) }

    @discardableResult public func moveToTrash(_ path: String) throws -> URL? {
        guard index.containsNote(path) || index.folders.contains(path), let url = index.itemURL(path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        var destination: NSURL?
        try files.trashItem(at: url, resultingItemURL: &destination)
        refresh(paths: [path])
        return destination as URL?
    }

    public func reveal(_ path: String) {
        guard let url = index.itemURL(path), files.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Resolves the exact vault path first, then the case-insensitive note name.
    /// The caller can check the library when there is no matching note.
    public func resolve(link: String) -> String? {
        _ = revision
        let target = link.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let name = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return index.resolveTarget(name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func backlinks(to path: String) -> [String] {
        _ = revision
        guard index.containsNote(path) else { return [] }
        return index.sources(for: path).filter { $0 != path && index.backlinkRange(from: $0, to: path) != nil }
            .sorted(by: VaultIndex.alphabetical)
    }

    public func backlinkExcerpt(from source: String, to path: String) -> String? {
        _ = revision
        guard let note = index.notes[source], let hit = index.backlinkRange(from: source, to: path) else { return nil }
        let text = note.text as NSString
        return text.substring(with: text.lineRange(for: hit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Wiki links in source order, including aliases and heading fragments.
    public func outgoingLinks(from path: String) -> [NoteSyntax.WikiLink] {
        _ = revision
        return index.notes[path]?.links ?? []
    }

    /// Library IDs referenced by strata fences in source order.
    public func embeddedSimIDs(in path: String) -> [String] {
        _ = revision
        return index.notes[path]?.embeds ?? []
    }

    public func search(_ query: String) -> [SearchHit] {
        _ = revision
        return index.search(query, checkCancellation: {}).flatMap(\.hits)
    }

    /// Searches a snapshot in bounded batches. Cancelling the caller cancels the worker.
    public func searchNotes(_ query: String) async throws -> [NoteSearchGroup] {
        let snapshot = index
        let worker = Task.detached(priority: .userInitiated) {
            try snapshot.search(query, checkCancellation: { try Task.checkCancellation() })
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }

    /// The personal note attached to a node of a sim: "Sims/<sim>/<level path…>/<node>.md".
    public func nodeNotePath(sim: String, levelPath: [String], node: String) -> String {
        (["Sims", sim] + levelPath + [node]).joined(separator: "/") + ".md"
    }

    public func hasNote(_ path: String) -> Bool {
        _ = revision
        return index.containsNote(path)
    }

    /// Lines from the current vault index, or nil if the note is absent from the index.
    public func indexedLines(at path: String) -> [String]? {
        _ = revision
        return index.notes[path]?.lines
    }

    /// Resolves a local attachment relative to its note, keeping access within the vault.
    public func attachmentURL(_ path: String, relativeTo note: String) -> URL? {
        let decoded = path.removingPercentEncoding ?? path
        guard !decoded.hasPrefix("/"), URLComponents(string: decoded)?.scheme == nil else { return nil }
        let url = root.appendingPathComponent(VaultIndex.join(VaultIndex.parent(note), decoded)).standardizedFileURL
        guard let relative = index.relativePath(of: url), let safe = index.itemURL(relative),
              (try? safe.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return safe
    }

    /// Copies the bundled notes into an empty vault and indexes them immediately.
    public func seedIfEmpty(from seed: URL? = StrataResources.url("Vault")) {
        guard let seed else { return }
        index.seedIfEmpty(from: seed)
        reload()
    }

    /// Starts watching and loads the first index on a worker, optionally seeding an empty vault.
    public func startWatching() { startWatching(seedFrom: nil) }

    public func startWatching(seedFrom seed: URL?) {
        guard watcher == nil else { return }
        try? files.createDirectory(at: root, withIntermediateDirectories: true)
        let watchedRoot = root.resolvingSymlinksInPath()
        var roots = [watchedRoot.path, root.path]
        if let canonical = realpath(watchedRoot.path, nil) {
            roots.append(String(cString: canonical))
            free(canonical)
        }
        let prefixes = Set(roots.map { $0 + "/" }).sorted { $0.count > $1.count }
        watcher = VaultWatcher(root: watchedRoot) { [weak self] paths, fullScan in
            guard let self else { return }
            if fullScan {
                self.pendingScan = true
            } else {
                self.pendingPaths.formUnion(paths.compactMap { path in
                    prefixes.first(where: path.hasPrefix).map { String(path.dropFirst($0.count)) }
                })
            }
            self.indexPendingChanges()
        }
        pendingScan = true
        indexPendingChanges(seedFrom: seed)
    }

    private func indexPendingChanges(seedFrom seed: URL? = nil) {
        guard !indexing, pendingScan || !pendingPaths.isEmpty else { return }
        let fullScan = pendingScan
        let paths = pendingPaths
        pendingScan = false
        pendingPaths = []
        indexing = true
        let generation = mutationGeneration
        let base = index
        Task { @MainActor [weak self] in
            let (updated, changed) = await Task.detached(priority: .utility) {
                var updated = base
                if let seed { updated.seedIfEmpty(from: seed) }
                let changed = fullScan ? updated.reload() : updated.refresh(paths: paths)
                return (updated, changed)
            }.value
            guard let self else { return }
            self.indexing = false
            if self.mutationGeneration == generation {
                if changed {
                    self.index = updated
                    self.revision += 1
                }
            } else {
                // A local write published a newer index while the scan was in flight.
                self.pendingScan = self.pendingScan || fullScan
                self.pendingPaths.formUnion(paths)
            }
            self.indexPendingChanges()
        }
    }

    private func reload() {
        mutationGeneration += 1
        if index.reload() { revision += 1 }
    }

    private func refresh(paths: [String]) {
        mutationGeneration += 1
        if index.refresh(paths: Set(paths)) { revision += 1 }
    }

    private func relocate(_ path: String, to newPath: String) -> String? {
        guard index.containsNote(path) || index.folders.contains(path),
              let oldURL = index.itemURL(path), let newURL = index.itemURL(newPath),
              !newPath.hasPrefix(path + "/") else { return nil }
        guard path != newPath else { return path }

        let caseChange = path.caseInsensitiveCompare(newPath) == .orderedSame
            && files.fileExists(atPath: newURL.path)
            && (try? files.contentsOfDirectory(atPath: newURL.deletingLastPathComponent().path)
                .contains(newURL.lastPathComponent)) == false
        guard caseChange || !files.fileExists(atPath: newURL.path) else { return nil }

        let moves = Dictionary(uniqueKeysWithValues: index.orderedPaths.compactMap { note -> (String, String)? in
            guard note == path || note.hasPrefix(path + "/") else { return nil }
            return (note, newPath + note.dropFirst(path.count))
        })

        let projectedPaths = Set(index.orderedPaths).subtracting(moves.keys).union(moves.values)
        var projectedNames = index.pathsByName
        for old in moves.keys { projectedNames[VaultIndex.title(old).lowercased()]?.remove(old) }
        for new in moves.values { projectedNames[VaultIndex.title(new).lowercased(), default: []].insert(new) }
        func projectedTarget(_ target: String) -> String? {
            VaultIndex.resolveTarget(target, contains: projectedPaths.contains, pathsByName: projectedNames)
        }

        var affected: Set<String> = []
        for (old, new) in moves {
            affected.formUnion(index.sources(for: old))
            affected.formUnion(index.sources(for: new))
        }

        var rewrites: [(path: String, version: NoteVersion, after: Data)] = []
        for source in affected.sorted() {
            guard let note = index.notes[source],
                  case .readable(let current, let version, let encoding) = readNote(source),
                  version == index.versions[source] else { return nil }
            let edited = NSMutableString(string: current)
            for link in note.links.reversed() {
                guard let destination = index.resolveTarget(link.target) else { continue }
                let desired = moves[destination] ?? destination
                guard desired != destination || projectedTarget(link.target) != desired else { continue }

                let name = VaultIndex.title(desired)
                let suffix = VaultIndex.isMarkdown(link.target) ? String(desired.suffix(3)) : ""
                let short = name + suffix
                let full = VaultIndex.linkKey(desired, folded: false) + suffix
                let shortIsSafe = !link.target.contains("/") && projectedNames[name.lowercased()]?.count == 1
                    && projectedTarget(short) == desired
                let target = shortIsSafe ? short : (projectedTarget(full) == desired ? full : desired)
                guard NoteSyntax.wikiLinks(in: "[[\(target)]]").first?.target == target,
                      projectedTarget(target) == desired else { return nil }
                edited.replaceCharacters(in: link.targetRange, with: target)
            }
            let after = edited as String
            if !after.utf8.elementsEqual(current.utf8) {
                rewrites.append((source, version, after.data(using: encoding) ?? Data(after.utf8)))
            }
        }

        var moved = false
        var applied: [(url: URL, before: Data, after: Data)] = []
        do {
            try moveItem(from: oldURL, to: newURL, caseChange: caseChange)
            moved = true
            for rewrite in rewrites {
                guard let url = index.itemURL(moves[rewrite.path] ?? rewrite.path) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let before = try Data(contentsOf: url)
                guard VaultIndex.readNote(at: url).version == rewrite.version else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try rewrite.after.write(to: url, options: .atomic)
                applied.append((url, before, rewrite.after))
            }
        } catch {
            for rewrite in applied.reversed() where (try? Data(contentsOf: rewrite.url)) == rewrite.after {
                try? rewrite.before.write(to: rewrite.url, options: .atomic)
            }
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

    private func createUnique(in folder: String?, base: String, suffix: String, create: (URL) throws -> Void) -> String {
        let folder = folder ?? ""
        guard let parent = folder.isEmpty ? root : index.itemURL(folder) else { return "" }
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
                let path = VaultIndex.join(folder, name)
                refresh(paths: [path])
                return path
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            } catch { return "" }
        }
        return ""
    }

    private static func cleanName(_ name: String, stripExtension: Bool) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = stripExtension ? VaultIndex.linkKey(name, folded: false) : name
        guard !base.isEmpty, !base.hasPrefix("."), !base.contains("/"),
              base.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return base
    }
}
