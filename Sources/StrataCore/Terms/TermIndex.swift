import Foundation

// PLACEHOLDER. The manifest agent implements glossary packs and auto-linking. Keep the API.

/// Built-in glossary packs (Resources/Glossaries/<pack>.json: an array of Term).
public enum GlossaryPacks {
    public static func load(_ pack: String) -> [Term] { [] }
    public static var available: [String] { [] }
}

/// The terms visible to one manifest: its own, then its imported packs, in order.
public struct TermIndex: Sendable {
    public private(set) var terms: [Term] = []
    public init(terms: [Term]) { self.terms = terms }
    public init(manifest: Manifest) { self.terms = manifest.terms }

    /// By id, or `pack/id`.
    public func term(_ id: String) -> Term? { terms.first { $0.id == id } }

    /// Non-overlapping glossary matches in `text` (each term at most once, first occurrence;
    /// whole words; longest phrase wins), for auto-linking in markdown.
    public func matches(in text: String) -> [(range: Range<String.Index>, term: Term)] { [] }
}
