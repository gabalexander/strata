import Foundation

/// Where an in-window hover hint goes and when it shows (docs/design.md, Hints). Pure geometry and
/// timing, so the checks cover it; the view that draws the hint lives in StrataUI (Overlay/Hints.swift).
public enum HintPlacement {
    /// Space between the hint and the control it explains.
    public static let gap: CGFloat = 6
    /// The hint never comes closer than this to the window's edges.
    public static let margin: CGFloat = 8

    /// The hint's frame for a bubble of `size` explaining `anchor`, inside a window of `bounds`
    /// (window space, top-left origin). Below the anchor and centred on it; above it when there is no
    /// room below; beside it (right, then left) when neither fits; always clamped to the window. It
    /// covers the anchor only when the window is too small for anything else.
    public static func frame(size: CGSize, anchor: CGRect, bounds: CGSize, preferAbove: Bool = false) -> CGRect {
        let width = min(size.width, max(0, bounds.width - margin * 2))
        let height = min(size.height, max(0, bounds.height - margin * 2))
        let maxX = max(margin, bounds.width - margin - width)
        let maxY = max(margin, bounds.height - margin - height)
        let centredX = min(max(margin, anchor.midX - width / 2), maxX)
        let below = CGRect(x: centredX, y: anchor.maxY + gap, width: width, height: height)
        let above = CGRect(x: centredX, y: anchor.minY - gap - height, width: width, height: height)
        let fitsBelow = below.maxY <= bounds.height - margin
        let fitsAbove = above.minY >= margin
        if preferAbove ? fitsAbove : fitsBelow { return preferAbove ? above : below }
        if preferAbove ? fitsBelow : fitsAbove { return preferAbove ? below : above }
        let sideY = min(max(margin, anchor.midY - height / 2), maxY)
        let right = CGRect(x: anchor.maxX + gap, y: sideY, width: width, height: height)
        if right.maxX <= bounds.width - margin { return right }
        let left = CGRect(x: anchor.minX - gap - width, y: sideY, width: width, height: height)
        if left.minX >= margin { return left }
        return CGRect(x: centredX, y: min(max(margin, below.minY), maxY), width: width, height: height)
    }
}

/// When a hint shows: after a short rest on a control, or at once while hints are "warm" (one is on
/// screen, or one hid a moment ago), so moving along a toolbar reads each control without waiting.
public struct HintTiming: Equatable, Sendable {
    /// The rest before the first hint.
    public static let delay: TimeInterval = 0.45
    /// How long after a hint hides the next one still shows at once.
    public static let warmth: TimeInterval = 0.5

    /// When the last hint hid; nil when none has yet, or a click or scroll cooled them down.
    public private(set) var hiddenAt: Date?
    public private(set) var showing = false

    public init() {}

    /// The wait before a hint for a control the pointer just entered.
    public func wait(at now: Date) -> TimeInterval {
        if showing { return 0 }
        if let hiddenAt, now.timeIntervalSince(hiddenAt) < Self.warmth { return 0 }
        return Self.delay
    }

    public mutating func shown() { showing = true }

    /// The pointer left the control: the next hint may follow at once.
    public mutating func hidden(at now: Date) {
        if showing { hiddenAt = now }
        showing = false
    }

    /// A click, scroll or key: hints cool down, so the next one waits out the delay again.
    public mutating func cooled() {
        showing = false
        hiddenAt = nil
    }
}
