import AppKit
import StrataCore

/// The app menu and the command palette use the same commands and key equivalents.
@MainActor
public enum ShellCommand: CaseIterable {
    case palette, switcher, newNote, search, back, forward, sidebar, inspector, dock
    case graph, home, reloadLibrary, dataFolder, editConfig, shortcuts

    public var title: String {
        switch self {
        case .palette: "Command palette"
        case .switcher: "Open note or simulator…"
        case .newNote: "New note"
        case .search: "Search notes"
        case .back: "Go back"
        case .forward: "Go forward"
        case .sidebar: "Toggle sidebar"
        case .inspector: "Toggle inspector"
        case .dock: "Toggle dock"
        case .graph: "Open graph"
        case .home: "Go home"
        case .reloadLibrary: "Reload library"
        case .dataFolder: "Open data folder in Finder"
        case .editConfig: "Edit config"
        case .shortcuts: "Keyboard shortcuts"
        }
    }

    var symbol: String {
        switch self {
        case .palette: "command"
        case .switcher: "arrow.right.square"
        case .newNote: "square.and.pencil"
        case .search: "magnifyingglass"
        case .back: "chevron.left"
        case .forward: "chevron.right"
        case .sidebar: "sidebar.left"
        case .inspector: "sidebar.right"
        case .dock: "dock.rectangle"
        case .graph: "point.3.connected.trianglepath.dotted"
        case .home: "house"
        case .reloadLibrary: "arrow.clockwise"
        case .dataFolder: "folder"
        case .editConfig: "gearshape"
        case .shortcuts: "keyboard"
        }
    }

    /// The command's entry in the app's one list of shortcuts (Shortcuts.swift), which the app menu registers.
    public var shortcutEntry: Shortcut? {
        switch self {
        case .palette: Shortcuts.palette
        case .switcher: Shortcuts.switcher
        case .newNote: Shortcuts.newNote
        case .search: Shortcuts.search
        case .back: Shortcuts.back
        case .forward: Shortcuts.forward
        case .sidebar: Shortcuts.sidebar
        case .inspector: Shortcuts.inspector
        case .dock: Shortcuts.dock
        case .graph: Shortcuts.graph
        case .home: Shortcuts.home
        case .editConfig: Shortcuts.config
        case .shortcuts: Shortcuts.sheet
        case .reloadLibrary, .dataFolder: nil
        }
    }

    public var keyEquivalent: String {
        guard case .char(let key)? = shortcutEntry?.keys.first else { return "" }
        return key
    }

    public var modifiers: NSEvent.ModifierFlags {
        shortcutEntry?.modifiers.eventFlags ?? .command
    }

    var shortcut: String? { shortcutEntry?.display }

    func isEnabled(in model: AppModel) -> Bool {
        switch self {
        case .back: !model.backStack.isEmpty
        case .forward: !model.forwardStack.isEmpty
        default: true
        }
    }

    public func perform(on model: AppModel) {
        model.overlays.dismissMenu()
        if self != .shortcuts { model.shortcutSheetOpen = false }
        if self != .palette && self != .switcher {
            model.paletteOpen = false
            model.switcherOpen = false
        }
        switch self {
        case .palette:
            model.switcherOpen = false
            model.paletteOpen.toggle()
        case .switcher:
            model.paletteOpen = false
            model.switcherOpen.toggle()
        case .newNote:
            let path = model.vault.createNote(in: nil, name: "Untitled", text: "")
            model.open(.note(path))
        case .search: model.open(.search(""))
        case .back:
            model.overlays.closeTerm()
            model.goBack()
        case .forward:
            model.overlays.closeTerm()
            model.goForward()
        case .sidebar: model.sidebarVisible.toggle()
        case .inspector: model.inspectorVisible.toggle()
        case .dock: model.dockVisible.toggle()
        case .graph: model.open(.graph)
        case .home: model.open(.home)
        case .reloadLibrary:
            model.library.reload()
            model.overlays.toast("Library reloaded")
        case .dataFolder, .editConfig:
            openData(model)
        case .shortcuts:
            model.overlays.closeTerm()
            model.shortcutSheetOpen.toggle()
        }
    }

    private func openData(_ model: AppModel) {
        let files = FileManager.default
        do {
            try files.createDirectory(at: StrataPaths.home, withIntermediateDirectories: true)
            if self == .dataFolder {
                NSWorkspace.shared.open(StrataPaths.home)
                return
            }
            if !files.fileExists(atPath: StrataPaths.config.path) {
                try Data("{}\n".utf8).write(to: StrataPaths.config, options: .withoutOverwriting)
            }
            if model.config.editor != nil {
                model.openCode(StrataPaths.config.path, repo: nil)
                return
            }
            let editor = Process()
            editor.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            editor.arguments = ["-t", StrataPaths.config.path]
            try editor.run()
        } catch {
            model.overlays.toast(error.localizedDescription)
        }
    }
}
