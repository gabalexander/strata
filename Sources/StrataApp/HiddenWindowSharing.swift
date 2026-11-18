import AppKit
import ObjectiveC

@MainActor
enum HiddenWindowSharing {
    static var enabled = true

    static func install() { _ = hook }

    private static let hook: Void = {
        let original = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.order(_:relativeTo:)))!
        let replacement = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.strataOrder(_:relativeTo:)))!
        method_exchangeImplementations(original, replacement)
    }()
}

private extension NSWindow {
    @objc dynamic func strataOrder(_ place: NSWindow.OrderingMode, relativeTo otherWindow: Int) {
        if place != .out, HiddenWindowSharing.enabled, sharingType != .none {
            sharingType = .none
        }
        strataOrder(place, relativeTo: otherWindow)
    }
}
