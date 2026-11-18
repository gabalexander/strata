import SwiftUI
import AppKit
import StrataCore

// Navigation and shared services. CONTRACT FILE: owned by the lead; screens add what they need
// through extensions in their own files.

public enum Route: Hashable, Sendable {
    case home                               // library overview
    case note(String)                       // vault-relative path
    case sim(String, path: [String])        // manifest id + deep-dive path (node ids)
    case graph                              // notes + sims link graph
    case search(String)                     // full-text search results
}

@MainActor
@Observable
public final class AppModel {
    public let library: Library
    public let vault: Vault
    public let overlays = Overlays()
    public var config: StrataConfig

    public private(set) var route: Route = .home
    public private(set) var backStack: [Route] = []
    public private(set) var forwardStack: [Route] = []

    public var sidebarVisible = true
    public var inspectorVisible = true
    public var dockVisible = true           // sim screens: the bottom dock (⌘J)
    /// Commands the active screen offers to the ⌘K palette (e.g. a sim's play/pause, scenarios, node actions).
    public var screenCommands: [MenuItem] = []
    public var paletteOpen = false          // ⌘K: commands + everything
    public var switcherOpen = false         // ⌘O: jump to a note or sim

    /// Running simulations by "id|path", so a sim keeps its state when you navigate away and back.
    /// Sim screens create and drop entries; a library reload of that id drops them.
    @ObservationIgnored public var sessions: [String: Simulation] = [:]

    public init(library: Library, vault: Vault, config: StrataConfig = StrataConfig()) {
        self.library = library; self.vault = vault; self.config = config
    }

    public func open(_ r: Route) {
        guard r != route else { return }
        overlays.dismissMenu(); overlays.closeTerm()
        backStack.append(route); forwardStack.removeAll()
        if backStack.count > 100 { backStack.removeFirst() }
        route = r
    }
    /// Swap the current route without a history entry (e.g. renaming the open note).
    public func replace(_ r: Route) { route = r }
    public func goBack() { guard let r = backStack.popLast() else { return }; forwardStack.append(route); route = r }
    public func goForward() { guard let r = forwardStack.popLast() else { return }; backStack.append(route); route = r }

    public static func sessionKey(_ id: String, _ path: [String]) -> String { ([id] + path).joined(separator: "|") }

    /// "Open code": runs `config.editor` (e.g. `code -g`) with the absolute path, else reveals it in Finder.
    public func openCode(_ path: String, repo: String?) {
        var p = StrataPaths.expand(path)
        if !p.hasPrefix("/"), let repo { p = (StrataPaths.expand(repo) as NSString).appendingPathComponent(p) }
        if let editor = config.editor ?? Self.defaultEditor() {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/zsh")
            task.arguments = ["-lc", "\(editor) \(Self.shellQuote(p))"]
            do { try task.run(); return } catch {}
        }
        let file = p.split(separator: ":").first.map(String.init) ?? p
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)])
    }

    private static func defaultEditor() -> String? {
        for c in ["/opt/homebrew/bin/code", "/usr/local/bin/code", "/opt/homebrew/bin/cursor", "/usr/local/bin/cursor"]
        where FileManager.default.isExecutableFile(atPath: c) { return "\(c) -g" }
        return nil
    }
    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
