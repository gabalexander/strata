import AppKit
import SwiftUI
import StrataCore
import StrataUI

// PLACEHOLDER (shell agent): accessory app, hidden windows, hotkey, menu bar item, URL scheme.

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let model = AppModel(library: Library(), vault: Vault(root: StrataPaths.vault))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.sharingType = .none
    window.contentView = NSHostingView(rootView: RootView(model: model))
    window.center()
    window.makeKeyAndOrderFront(nil)
    app.setActivationPolicy(.accessory)
    app.activate()
    app.run()
}
