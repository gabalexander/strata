import AppKit
import Carbon.HIToolbox
import Observation
import StrataCore
import StrataUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: AppModel?
    private var window: StrataWindow?
    private var statusItem: NSStatusItem?
    private let hotkey = HotkeyRegistration()
    private var pendingURLRoute: Route?
    private var saveTask: Task<Void, Never>?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(openURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let (config, diagnostics) = ConfigLoader.load()
        for diagnostic in diagnostics { NSLog("Strata config: %@", diagnostic.description) }

        let library = Library(dirs: config.simURLs)
        library.startWatching()
        let vault = Vault(root: config.vaultURL, loadImmediately: false)
        vault.startWatching(seedFrom: StrataResources.url("Vault"))

        let model = AppModel(library: library, vault: vault, config: config)
        self.model = model
        model.replace(RouteState.load())
        observeRoute()

        let window = StrataWindow(model: model)
        self.window = window
        window.delegate = self

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowActivity), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowActivity), name: NSApplication.didUpdateNotification, object: NSApp)
        enforceWindowSharing()
        installMainMenu()

        var key = Hotkey.parse(config.hotkey)
        if key == nil {
            NSLog("Strata: invalid hotkey %@, using %@", config.hotkey, Hotkey.defaultSpec)
            key = Hotkey.parse(Hotkey.defaultSpec)
        }
        var registered = false
        if let key {
            let status = hotkey.register(key) { [weak self] in self?.toggleWindow() }
            registered = status == noErr
            if !registered { NSLog("Strata: could not register %@ (OSStatus %d)", key.display, status) }
        }
        if config.menubar { installStatusItem(hint: registered ? key?.display : nil) }

        if let route = pendingURLRoute {
            pendingURLRoute = nil
            model.open(route)
            showWindow()
        } else if !CommandLine.arguments.contains("--hidden") || (!config.menubar && !registered) {
            // A normal launch shows the window; the login agent passes --hidden and waits for the hotkey.
            showWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveTask?.cancel()
        if let model { save(model.route) }
        hotkey.unregister()
        NSAppleEventManager.shared().removeEventHandler(forEventClass: AEEventClass(kInternetEventClass),
                                                        andEventID: AEEventID(kAEGetURL))
        NotificationCenter.default.removeObserver(self)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideWindow()
        return false
    }

    @objc private func windowActivity(_ notification: Notification) { enforceWindowSharing() }

    private func enforceWindowSharing() {
        guard model?.config.hideFromScreenShare == true else { return }
        for window in NSApp.windows where window.sharingType != .none { window.sharingType = .none }
    }

    @objc private func showWindow() {
        enforceWindowSharing()
        window?.showOnMouseScreen()
    }

    @objc private func hideWindow() {
        model?.overlays.dismissMenu()
        model?.paletteOpen = false
        model?.switcherOpen = false
        window?.hide()
    }

    private func toggleWindow() {
        if window?.isKeyWindow == true { hideWindow() } else { showWindow() }
    }

    @objc private func openURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let route = Route(strataURL: string) else { return }
        guard let model else { pendingURLRoute = route; return }
        model.paletteOpen = false
        model.switcherOpen = false
        model.open(route)
        showWindow()
    }

    private func observeRoute() {
        guard let model else { return }
        withObservationTracking {
            _ = model.route
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, let model = self.model else { return }
                self.observeRoute()
                self.scheduleSave(model.route)
            }
        }
    }

    private func scheduleSave(_ route: Route) {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.save(route)
        }
    }

    private func save(_ route: Route) {
        do { try RouteState(route).save() }
        catch { NSLog("Strata: could not save state: %@", error.localizedDescription) }
    }
}

extension AppDelegate {
    private func installMainMenu() {
        let main = NSMenu()
        let app = addSubmenu("Strata", to: main)
        addItem("Hide Window", #selector(hideWindow), to: app, key: "w", target: self)
        addItem("Quit Strata", #selector(NSApplication.terminate(_:)), to: app, key: "q", target: NSApp)

        let edit = addSubmenu("Edit", to: main)
        addItem("Undo", Selector(("undo:")), to: edit, key: "z")
        addItem("Redo", Selector(("redo:")), to: edit, key: "z", modifiers: [.command, .shift])
        edit.addItem(.separator())
        addItem("Cut", #selector(NSText.cut(_:)), to: edit, key: "x")
        addItem("Copy", #selector(NSText.copy(_:)), to: edit, key: "c")
        addItem("Paste", #selector(NSText.paste(_:)), to: edit, key: "v")
        addItem("Select All", #selector(NSText.selectAll(_:)), to: edit, key: "a")
        let find = addItem("Find…", #selector(NSTextView.performTextFinderAction(_:)), to: edit, key: "f")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue

        let commands = addSubmenu("Commands", to: main)
        for command in ShellCommand.allCases { addCommand(command, to: commands) }
        NSApp.mainMenu = main
    }

    private func installStatusItem(hint: String?) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Strata")
        let menu = NSMenu()
        let showTitle = hint.map { "Show Strata (\($0))" } ?? "Show Strata"
        addItem(showTitle, #selector(showWindow), to: menu, target: self)
        menu.addItem(.separator())
        addCommand(.newNote, to: menu, status: true)
        addCommand(.switcher, to: menu, status: true, title: "Open simulator…")
        addCommand(.reloadLibrary, to: menu, status: true)
        menu.addItem(.separator())
        addCommand(.dataFolder, to: menu, status: true, title: "Open ~/.strata in Finder")
        addCommand(.editConfig, to: menu, status: true)
        menu.addItem(.separator())
        addItem("Quit Strata", #selector(NSApplication.terminate(_:)), to: menu, key: "q", target: NSApp)
        item.menu = menu
        statusItem = item
    }

    private func addSubmenu(_ title: String, to main: NSMenu) -> NSMenu {
        let item = NSMenuItem()
        let menu = NSMenu(title: title)
        item.submenu = menu
        main.addItem(item)
        return menu
    }

    @discardableResult
    private func addItem(_ title: String, _ action: Selector, to menu: NSMenu, key: String = "",
                         modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        menu.addItem(item)
        return item
    }

    private func addCommand(_ command: ShellCommand, to menu: NSMenu, status: Bool = false, title: String? = nil) {
        let item = addItem(title ?? command.title, status ? #selector(performStatusCommand(_:)) : #selector(performCommand(_:)),
                           to: menu, key: command.keyEquivalent, modifiers: command.modifiers, target: self)
        item.representedObject = command
    }

    @objc private func performCommand(_ sender: NSMenuItem) {
        guard let model, let command = sender.representedObject as? ShellCommand else { return }
        command.perform(on: model)
    }

    @objc private func performStatusCommand(_ sender: NSMenuItem) {
        switch sender.representedObject as? ShellCommand {
        case .newNote: showWindow()
        case .switcher:
            showWindow()
            guard let model else { return }
            model.overlays.dismissMenu()
            model.paletteOpen = false
            model.switcherOpen = true
            return
        default: break
        }
        performCommand(sender)
    }
}
