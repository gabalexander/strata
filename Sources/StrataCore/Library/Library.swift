import Foundation
import Observation

@MainActor
@Observable
public final class Library {
    public struct Entry: Identifiable, Sendable {
        public var id: String
        public var title: String
        public var kind: ManifestKind
        public var category: String?
        public var summary: String?
        public var tags: [String]
        public var url: URL
        public var builtIn: Bool
        public var diagnostics: [Diagnostic]
        public var manifest: Manifest?
        public init(id: String, title: String, kind: ManifestKind, category: String?, summary: String?, tags: [String],
                    url: URL, builtIn: Bool, diagnostics: [Diagnostic], manifest: Manifest?) {
            self.id = id; self.title = title; self.kind = kind; self.category = category; self.summary = summary
            self.tags = tags; self.url = url; self.builtIn = builtIn; self.diagnostics = diagnostics; self.manifest = manifest
        }
    }

    /// Sorted by kind, category, title. A user file with the same id as a built-in replaces it.
    public private(set) var entries: [Entry] = []
    public private(set) var revision = 0
    public let builtIn: URL?
    public let dirs: [URL]

    @ObservationIgnored private var byID: [String: Entry] = [:]
    @ObservationIgnored private var bundled: [String: URL] = [:]
    @ObservationIgnored private var inventory: LibraryInventory?
    @ObservationIgnored private var watchers: LibraryWatchers?

    public init(builtIn: URL? = StrataResources.url("Examples"), dirs: [URL] = [StrataPaths.sims]) {
        self.builtIn = builtIn
        self.dirs = dirs
        reload()
    }

    /// Test/snapshot hook: a library holding exactly these manifests.
    public init(manifests: [Manifest]) {
        builtIn = nil
        dirs = []
        entries = manifests.map { manifest in
            Entry(id: manifest.id, title: manifest.title, kind: manifest.kind, category: manifest.category,
                  summary: manifest.summary, tags: manifest.tags, url: URL(fileURLWithPath: "/dev/null"),
                  builtIn: true, diagnostics: [], manifest: manifest)
        }.sorted(by: Self.precedes)
        byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func manifest(_ id: String) -> Manifest? { entry(id)?.manifest }
    public func entry(_ id: String) -> Entry? {
        _ = revision
        return byID[id]
    }

    /// Re-reads every directory.
    public func reload() {
        if dirs.contains(where: { $0.standardizedFileURL == StrataPaths.sims.standardizedFileURL }) {
            try? FileManager.default.createDirectory(at: StrataPaths.sims, withIntermediateDirectories: true)
        }
        let inventory = LibraryInventory(builtIn: builtIn, dirs: dirs)
        self.inventory = inventory
        var files = inventory.builtIn.map { LibraryFile($0, builtIn: true) }
        let originals = Self.selectWinners(in: &files)
        bundled = originals.mapValues { files[$0].entry.url }

        let lastBuiltIn = files.endIndex
        files += inventory.users.map { LibraryFile($0, builtIn: false) }
        let users = Self.selectWinners(in: &files, startingAt: lastBuiltIn)
        let selected = originals.merging(users) { _, user in user }
        let overrides = Set(users.keys.compactMap { originals[$0] })
        let known = Set(selected.compactMap { files[$0.value].entry.manifest == nil ? nil : $0.key })

        for index in files.indices where !overrides.contains(index) { files[index].checkDetails(known: known) }
        byID = selected.mapValues { files[$0].entry }
        entries = files.enumerated().compactMap { overrides.contains($0.offset) ? nil : $0.element.entry }.sorted(by: Self.precedes)
        for entry in entries where byID[entry.id] == nil { byID[entry.id] = entry }
        revision += 1
    }

    /// Validates explicit files and directories using this library to resolve `detail` references.
    public func validate(_ urls: [URL]) -> [Entry] {
        var files: [LibraryFile] = []
        var seen: Set<URL> = []
        for requested in urls {
            let url = requested.standardizedFileURL
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                do {
                    for file in try LibraryInventory.manifests(in: url) where seen.insert(file).inserted {
                        files.append(LibraryFile(file, builtIn: false))
                    }
                } catch {
                    files.append(LibraryFile(failureAt: url, message: "could not read directory: \(error.localizedDescription)"))
                }
            } else if seen.insert(url).inserted {
                files.append(LibraryFile(url, builtIn: false))
            }
        }
        let winners = Self.selectWinners(in: &files)
        var known = Set(byID.compactMap { $0.value.manifest == nil ? nil : $0.key })
        for (id, index) in winners {
            if files[index].entry.manifest != nil { known.insert(id) } else { known.remove(id) }
        }
        for index in files.indices { files[index].checkDetails(known: known) }
        return files.map(\.entry)
    }

    /// Starts watching directories. An mtime scan also catches in-place writes.
    public func startWatching() {
        guard watchers == nil else { return }
        let directories = ([builtIn].compactMap { $0 } + dirs).map(\.standardizedFileURL)
        let watchers = LibraryWatchers(directories: directories) { [weak self] in self?.rescan() }
        self.watchers = watchers
        watchers.start()
        rescan()
    }

    private func rescan() {
        let current = LibraryInventory(builtIn: builtIn, dirs: dirs)
        guard current != inventory else { return }
        reload()
    }

    /// Copies a built-in manifest into ~/.strata/sims so it can be edited. Returns the new file.
    public func duplicate(_ id: String) -> URL? {
        guard let source = bundled[id], let data = try? Data(contentsOf: source),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let directory = StrataPaths.sims
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var used = Set(entries.filter { !$0.builtIn }.map(\.id))
            // The default directory can change between a watcher tick and this command.
            for file in try LibraryInventory.manifests(in: directory) {
                used.insert(file.deletingPathExtension().lastPathComponent)
                if let text = try? String(contentsOf: file, encoding: .utf8),
                   let document = try? YAML.parse(text), let declared = document["id"]?.scalar {
                    used.insert(declared)
                }
            }
            var suffix = 1
            while true {
                let candidate = suffix == 1 ? id : "\(id)-\(suffix)"
                suffix += 1
                if used.contains(candidate) || (candidate != id && bundled[candidate] != nil) { continue }
                let destination = directory.appendingPathComponent(candidate).appendingPathExtension("yaml")
                let copy = candidate == id ? data : try LibraryFile.copy(text, replacingIDWith: candidate)
                do {
                    try copy.write(to: destination, options: .withoutOverwriting)
                    reload()
                    return destination
                } catch let error as CocoaError where error.code == .fileWriteFileExists {
                    continue
                }
            }
        } catch {
            return nil
        }
    }

    private static func selectWinners(in files: inout [LibraryFile], startingAt start: Int = 0) -> [String: Int] {
        var winners: [String: Int] = [:]
        for index in start..<files.endIndex {
            guard let id = files[index].declaredID else { continue }
            if let first = winners[id] {
                let path = files[first].entry.url.path
                files[index].markDuplicate(first: path)
            } else {
                winners[id] = index
            }
        }
        return winners
    }

    private static func precedes(_ left: Entry, _ right: Entry) -> Bool {
        (left.kind.rawValue, left.category ?? "", left.title.localizedLowercase, left.id, left.url.path)
        < (right.kind.rawValue, right.category ?? "", right.title.localizedLowercase, right.id, right.url.path)
    }
}
