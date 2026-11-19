import Foundation

public enum ConfigLoader {
    /// Reads ~/.strata/config.yaml (missing file = defaults).
    public static func load(_ url: URL = StrataPaths.config) -> (StrataConfig, [Diagnostic]) {
        var config = StrataConfig()
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let findings = Findings()
            let root = Field(try YAML.parse(text), findings: findings)
            if root.mapping(["vault", "simDirs", "hotkey", "editor", "menubar", "hideFromScreenShare", "ask"]) {
                config.vault = root["vault"].text(nonempty: true)
                config.simDirs = root["simDirs"].items().compactMap { $0.text(nonempty: true) }
                config.hotkey = root["hotkey"].text(nonempty: true) ?? config.hotkey
                config.editor = root["editor"].text(nonempty: true)
                config.menubar = root["menubar"].bool() ?? config.menubar
                config.hideFromScreenShare = root["hideFromScreenShare"].bool() ?? config.hideFromScreenShare
                let ask = root["ask"]
                if ask.present, ask.mapping(["enabled", "model", "claude"]) {
                    config.ask.enabled = ask["enabled"].bool() ?? config.ask.enabled
                    config.ask.model = ask["model"].text(nonempty: true)
                    config.ask.claude = ask["claude"].text(nonempty: true)
                }
            }
            return (config, ManifestParser.sorted(findings.diagnostics))
        } catch let error as Diagnostic {
            return (config, [error])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return (config, [])
        } catch {
            return (config, [Diagnostic(.error, "could not read config: \(error.localizedDescription)", line: 1)])
        }
    }
}
