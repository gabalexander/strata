import Foundation

// PLACEHOLDER. The manifest agent replaces this with the YAML subset parser, decoding, validation
// and auto-layout (docs/manifest.md). Keep these signatures.

public enum ManifestParser {
    /// Parses a manifest file's text (YAML subset or JSON). The manifest is nil only when errors
    /// make it unusable; warnings never block. After parsing, every node of every level has `at`
    /// (auto-layout fills the missing ones) and implicit edges exist for flow hops.
    public static func parse(_ text: String, source: ManifestSource) -> (Manifest?, [Diagnostic]) {
        (nil, [Diagnostic(.error, "parser not implemented yet")])
    }

    /// A ```strata block from a note: either `sim: <id>` (+ view/scenario/height/autoplay) or an inline manifest.
    public static func parseEmbed(_ text: String, note: String, index: Int) -> (Embed?, [Diagnostic]) {
        (nil, [Diagnostic(.error, "parser not implemented yet")])
    }

    /// One command line, e.g. "kill db", "rate place-order 50/s".
    public static func parseCommand(_ line: String) -> Result<Command, Diagnostic> {
        .failure(Diagnostic(.error, "parser not implemented yet"))
    }
}

/// What a ```strata block in a note asks for.
public struct Embed: Sendable {
    public enum Target: Sendable { case library(String), inline(Manifest) }
    public var target: Target
    public var view: [String] = []
    public var scenario: String?
    public var height: Double = 420
    public var autoplay = true
    public init(target: Target) { self.target = target }
}

public enum ConfigLoader {
    /// Reads ~/.strata/config.yaml (missing file = defaults).
    public static func load(_ url: URL = StrataPaths.config) -> (StrataConfig, [Diagnostic]) { (StrataConfig(), []) }
}
