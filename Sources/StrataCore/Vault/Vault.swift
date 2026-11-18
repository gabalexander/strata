import Foundation
import Observation

// PLACEHOLDER. The notes agent implements the vault. Keep the API.

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

    public init(root: URL) { self.root = root }

    public var allNotes: [String] { [] }
    public func read(_ path: String) -> String? { nil }
    public func write(_ path: String, _ text: String) {}
    /// Creates "<folder>/<name>.md" (unique name if taken) and returns its path.
    @discardableResult public func createNote(in folder: String?, name: String, text: String = "") -> String { name + ".md" }
    @discardableResult public func createFolder(in folder: String?, name: String) -> String { name }
    /// Returns the new path, or nil if the rename failed. Updates [[links]] to the note.
    @discardableResult public func rename(_ path: String, to newName: String) -> String? { nil }
    /// Moves to the macOS Trash (recoverable).
    public func trash(_ path: String) {}
    public func reveal(_ path: String) {}

    /// Resolves [[target]] (a note name or path, or a sim id) the way Obsidian does: exact path, then name.
    public func resolve(link: String) -> String? { nil }
    public func backlinks(to path: String) -> [String] { [] }
    public func search(_ query: String) -> [SearchHit] { [] }

    /// The personal note attached to a node of a sim: "Sims/<sim>/<level path…>/<node>.md".
    public func nodeNotePath(sim: String, levelPath: [String], node: String) -> String {
        (["Sims", sim] + levelPath + [node]).joined(separator: "/") + ".md"
    }
    public func hasNote(_ path: String) -> Bool { false }

    /// Copies the seed notes (Resources/Vault) into an empty or missing vault directory.
    public func seedIfEmpty(from seed: URL? = StrataResources.url("Vault")) {}

    /// Starts watching the vault for outside changes (an agent editing a note).
    public func startWatching() {}
}
