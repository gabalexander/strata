import AppKit

MainActor.assumeIsolated {
    HiddenWindowSharing.install()
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
