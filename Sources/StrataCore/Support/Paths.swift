import Foundation

/// Where Strata keeps its data. Everything is under one hidden directory so nothing about a work
/// project lands in a repo or a synced folder by accident. `STRATA_HOME` overrides it (tests, snapshots).
public enum StrataPaths {
    public static var home: URL {
        if let h = ProcessInfo.processInfo.environment["STRATA_HOME"], !h.isEmpty { return URL(fileURLWithPath: (h as NSString).expandingTildeInPath) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".strata")
    }
    public static var sims: URL { home.appendingPathComponent("sims") }
    public static var vault: URL { home.appendingPathComponent("vault") }
    public static var config: URL { home.appendingPathComponent("config.yaml") }
    public static var state: URL { home.appendingPathComponent("state.json") }   // window/UI state the app restores
    public static var ask: URL { home.appendingPathComponent("ask") }             // Ask history per map, and its settings

    public static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }
}

/// Bundled read-only resources (Examples, Glossaries, Vault seed). In the app bundle they sit in
/// Contents/Resources; in a dev build they are found next to the package (`Resources/` at the repo root).
public enum StrataResources {
    public static func url(_ name: String) -> URL? {
        let fm = FileManager.default
        if let r = ProcessInfo.processInfo.environment["STRATA_RESOURCES"] {
            let u = URL(fileURLWithPath: r).appendingPathComponent(name)
            if fm.fileExists(atPath: u.path) { return u }
        }
        if let base = Bundle.main.resourceURL {
            let u = base.appendingPathComponent(name)
            if fm.fileExists(atPath: u.path) { return u }
        }
        // The CLI lives in Strata.app/Contents/Resources/bin (often run through a ~/.local/bin symlink).
        let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let bundled = exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(name)
        if fm.fileExists(atPath: bundled.path) { return bundled }
        // Sources/StrataCore/Support/Paths.swift → repo root
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let u = repo.appendingPathComponent("Resources").appendingPathComponent(name)
        return fm.fileExists(atPath: u.path) ? u : nil
    }
}
