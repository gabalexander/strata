import AppKit
import SwiftUI
import StrataUI

@MainActor
final class StrataWindow: NSWindow {
    private var lastEscape: TimeInterval?

    init(model: AppModel) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "Strata"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        toolbarStyle = .unifiedCompact
        appearance = NSAppearance(named: .darkAqua)
        isReleasedWhenClosed = false
        contentMinSize = NSSize(width: 1100, height: 700)
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        tabbingMode = .disallowed
        sharingType = model.config.hideFromScreenShare ? .none : .readOnly
        let host = NSHostingView(rootView: RootView(model: model))
        host.sizingOptions = []
        contentView = host
        if !setFrameUsingName("Strata") { center() }
        setFrameAutosaveName("Strata")
    }

    func showOnMouseScreen() {
        // Ordering out also moves an already-visible window here from a different Space.
        if !isKeyWindow && isVisible { orderOut(nil) }
        let mouse = NSEvent.mouseLocation
        if !isKeyWindow,
           let display = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let visible = display.visibleFrame
            var windowFrame = frame
            windowFrame.size.width = max(contentMinSize.width, min(windowFrame.width, visible.width))
            windowFrame.size.height = max(contentMinSize.height, min(windowFrame.height, visible.height))
            if !display.frame.contains(NSPoint(x: windowFrame.midX, y: windowFrame.midY)) {
                windowFrame.origin = NSPoint(x: visible.midX - windowFrame.width / 2,
                                             y: visible.midY - windowFrame.height / 2)
            }
            windowFrame.origin.x = max(visible.minX, min(windowFrame.minX, visible.maxX - windowFrame.width))
            windowFrame.origin.y = min(visible.maxY - windowFrame.height, max(visible.minY, windowFrame.minY))
            if windowFrame != frame { setFrame(windowFrame, display: false) }
        }
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }

    func hide() {
        lastEscape = nil
        orderOut(nil)
    }

    override func resignKey() {
        super.resignKey()
        lastEscape = nil
    }

    override func miniaturize(_ sender: Any?) {}

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.keyCode == 53,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            if !event.isARepeat {
                if let lastEscape, event.timestamp - lastEscape <= 0.65 {
                    hide()
                    return
                }
                lastEscape = event.timestamp
            }
        } else if event.type == .keyDown || event.type == .leftMouseDown || event.type == .rightMouseDown {
            lastEscape = nil
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {}
}
