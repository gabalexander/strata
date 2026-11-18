import Foundation

/// ~/.strata/config.yaml. Every key is optional. Parsing lives in Parse/ (ConfigLoader).
public struct StrataConfig: Sendable, Equatable {
    public var vault: String?                 // vault directory (default ~/.strata/vault)
    public var simDirs: [String] = []          // extra manifest directories, besides ~/.strata/sims
    public var hotkey = "ctrl+option+s"        // show/hide the window
    public var editor: String?                 // command for "Open code", e.g. "code -g" or "cursor -g"; default: VS Code if present, else Finder
    public var menubar = true                  // show the menu bar icon
    public var hideFromScreenShare = true      // windows are excluded from screen capture and sharing
    public init() {}

    public var vaultURL: URL { vault.map { URL(fileURLWithPath: StrataPaths.expand($0)) } ?? StrataPaths.vault }
    public var simURLs: [URL] { [StrataPaths.sims] + simDirs.map { URL(fileURLWithPath: StrataPaths.expand($0)) } }
}
