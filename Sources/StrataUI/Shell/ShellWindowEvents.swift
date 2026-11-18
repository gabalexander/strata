import AppKit
import SwiftUI

/// Local AppKit dispatch lets a transient overlay handle navigation before the text field or window.
@MainActor
struct WindowEvents: NSViewRepresentable {
    let matching: NSEvent.EventTypeMask
    let handle: (NSEvent, NSView) -> NSEvent?

    func makeNSView(context: Context) -> Listener {
        let listener = Listener()
        listener.matching = matching
        listener.handle = handle
        return listener
    }

    func updateNSView(_ listener: Listener, context: Context) { listener.handle = handle }
    static func dismantleNSView(_ listener: Listener, coordinator: ()) { listener.detach() }

    final class Listener: NSView {
        var matching: NSEvent.EventTypeMask = []
        var handle: ((NSEvent, NSView) -> NSEvent?)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: matching) { [weak self] event in
                guard let self, let window = self.window,
                      (event.window ?? NSApp.keyWindow) === window,
                      let handle = self.handle else { return event }
                return handle(event, self)
            }
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

extension NSEvent {
    var hasCommandModifiers: Bool {
        !modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
    }

    var contentLocation: CGPoint? { contentLocation(in: window) }

    func contentLocation(in window: NSWindow?) -> CGPoint? {
        guard let content = window?.contentView else { return nil }
        let point = content.convert(locationInWindow, from: nil)
        return CGPoint(x: point.x, y: content.isFlipped ? point.y : content.bounds.height - point.y)
    }
}
