import Foundation
import Observation

// PLACEHOLDER. The manifest agent implements loading and live reload. Keep the API.

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
        public var manifest: Manifest?        // nil when it failed to load
        public init(id: String, title: String, kind: ManifestKind, category: String?, summary: String?, tags: [String],
                    url: URL, builtIn: Bool, diagnostics: [Diagnostic], manifest: Manifest?) {
            self.id = id; self.title = title; self.kind = kind; self.category = category; self.summary = summary
            self.tags = tags; self.url = url; self.builtIn = builtIn; self.diagnostics = diagnostics; self.manifest = manifest
        }
    }

    /// Sorted by kind, category, title. A user file with the same id as a built-in replaces it.
    public private(set) var entries: [Entry] = []
    /// Bumps whenever entries change (live reload).
    public private(set) var revision = 0

    public let builtIn: URL?
    public let dirs: [URL]

    public init(builtIn: URL? = StrataResources.url("Examples"), dirs: [URL] = [StrataPaths.sims]) {
        self.builtIn = builtIn; self.dirs = dirs
    }

    /// Test/snapshot hook: a library holding exactly these manifests.
    public init(manifests: [Manifest]) {
        builtIn = nil; dirs = []
        entries = manifests.map { m in
            Entry(id: m.id, title: m.title, kind: m.kind, category: m.category, summary: m.summary, tags: m.tags,
                  url: URL(fileURLWithPath: "/dev/null"), builtIn: true, diagnostics: [], manifest: m)
        }
    }

    public func manifest(_ id: String) -> Manifest? { entries.first { $0.id == id }?.manifest }
    public func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }

    /// Re-reads every directory.
    public func reload() {}
    /// Starts watching the directories; changed files reload within ~300 ms.
    public func startWatching() {}
    /// Copies a built-in manifest into ~/.strata/sims so it can be edited. Returns the new file.
    public func duplicate(_ id: String) -> URL? { nil }
}
