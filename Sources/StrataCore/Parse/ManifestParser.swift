import Foundation

public enum ManifestParser {
    /// Parses a YAML or JSON manifest. Warnings preserve a usable manifest.
    public static func parse(_ text: String, source: ManifestSource) -> (Manifest?, [Diagnostic]) {
        let result = parseDocument(text, source: source)
        return (result.manifest, result.diagnostics)
    }

    static func parseDocument(_ text: String, source: ManifestSource) -> (manifest: Manifest?, document: YAMLNode?, diagnostics: [Diagnostic]) {
        do {
            let document = try YAML.parse(text)
            let findings = Findings()
            let root = Field(document, findings: findings)
            let manifest = load(root, source: source)
            return (manifest, document, sorted(findings.diagnostics))
        } catch let error as Diagnostic {
            return (nil, nil, [error])
        } catch {
            return (nil, nil, [Diagnostic(.error, error.localizedDescription)])
        }
    }

    /// Parses either a library reference with embed settings or a whole inline manifest.
    public static func parseEmbed(_ text: String, note: String, index: Int) -> (Embed?, [Diagnostic]) {
        do {
            let findings = Findings()
            let root = Field(try YAML.parse(text), findings: findings)
            let inline = root["nodes"].present
            let target: Embed.Target?
            if inline {
                target = load(root, source: .inline(note: note, index: index), inline: true).map(Embed.Target.inline)
            } else if root.mapping(Decode.embedKeys.union(["sim"])) {
                target = root["sim"].id(required: true).map(Embed.Target.library)
            } else {
                target = nil
            }
            var view: [String] = []
            if root["view"].node?.elements != nil {
                view = root["view"].items().compactMap { $0.id() }
            } else if let path = root["view"].scalar({ raw in try raw.components(separatedBy: "/").map(Syntax.id) }) {
                view = path
            }
            let scenario = root["scenario"].id()
            let height = root["height"].number(min: 1) ?? 420
            let autoplay = root["autoplay"].bool() ?? true
            if case .inline(let manifest) = target {
                if let level = manifest.level(at: view) {
                    if let scenario, !level.scenarios.contains(where: { $0.id == scenario }) {
                        root["scenario"].diagnose("unknown scenario '\(scenario)' at the selected level")
                    }
                } else {
                    root["view"].diagnose("unknown deep-dive path '\(view.joined(separator: "/"))'")
                }
            }
            let diagnostics = sorted(findings.diagnostics)
            guard !findings.hasErrors, let target else { return (nil, diagnostics) }
            var embed = Embed(target: target)
            embed.view = view
            embed.scenario = scenario
            embed.height = height
            embed.autoplay = autoplay
            return (embed, diagnostics)
        } catch let error as Diagnostic {
            return (nil, [error])
        } catch {
            return (nil, [Diagnostic(.error, error.localizedDescription)])
        }
    }

    private static func load(_ root: Field, source: ManifestSource, inline: Bool = false) -> Manifest? {
        guard var manifest = Decode.manifest(root, source: source, inline: inline), !root.findings.hasErrors else { return nil }
        Validate.manifest(&manifest, at: root)
        return root.findings.hasErrors ? nil : manifest
    }

    static func sorted(_ diagnostics: [Diagnostic]) -> [Diagnostic] {
        diagnostics.enumerated().sorted { ($0.element.line ?? 0, $0.offset) < ($1.element.line ?? 0, $1.offset) }.map(\.element)
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
