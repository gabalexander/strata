import AppKit
import SwiftUI
import StrataCore

// In-window hover hints (docs/design.md, Hints): one line saying what a control does, with its shortcut.
// Never `.help`: a system tooltip is a separate window, which screen sharing would see. The state lives
// here and only the overlay host's HintLayer reads it, so a hint showing or moving re-renders that layer
// alone, never the panels around the control.

@MainActor
@Observable
public final class HoverHints {
    public struct Hint: Equatable {
        public var text: String
        public var shortcut: String?
        /// The control, in window space (top-left origin).
        public var anchor: CGRect
        /// Show above the control first (the stage's glyphs, so the card below stays readable).
        public var above = false
    }

    public private(set) var current: Hint?
    @ObservationIgnored private var owner: AnyHashable?
    @ObservationIgnored private var hovered: AnyHashable?
    @ObservationIgnored private var suppressed: AnyHashable?
    @ObservationIgnored private var timing = HintTiming()
    @ObservationIgnored private var pending: Task<Void, Never>?

    /// Offscreen snapshots: a control whose hint contains this text shows it at once.
    @ObservationIgnored @_spi(Snapshots) public var pinned: String?

    public init() {}

    /// The pointer entered a control. `anchor` is read when the hint shows, so it is where the control is then.
    /// `now` skips the rest (offscreen snapshots).
    public func enter(_ id: AnyHashable, text: String, shortcut: String? = nil, above: Bool = false, now: Bool = false,
                      anchor: @escaping @MainActor () -> CGRect) {
        hovered = id
        guard suppressed != id else { return }
        pending?.cancel()
        let wait = now ? 0 : timing.wait(at: Date())
        let show = { [weak self] in
            guard let self, self.hovered == id else { return }
            let frame = anchor()
            guard frame.width > 0 || frame.height > 0 else { return }
            self.owner = id
            self.timing.shown()
            let hint = Hint(text: text, shortcut: shortcut, anchor: frame, above: above)
            if self.current != hint { self.current = hint }
        }
        if wait == 0 {
            show()
        } else {
            pending = Task { @MainActor in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                show()
            }
        }
    }

    /// The pointer left a control. SwiftUI may report entering the next control first, so this only undoes
    /// what is still this control's: its pending hint, or its hint on screen.
    public func leave(_ id: AnyHashable) {
        if suppressed == id { suppressed = nil }
        if hovered == id {
            hovered = nil
            pending?.cancel()
        }
        guard owner == id else { return }
        timing.hidden(at: Date())
        owner = nil
        if current != nil { current = nil }
    }

    /// The control's text changed while hovered (Play became Pause).
    public func update(_ id: AnyHashable, text: String, shortcut: String?) {
        guard owner == id, var hint = current, hint.text != text || hint.shortcut != shortcut else { return }
        hint.text = text
        hint.shortcut = shortcut
        current = hint
    }

    /// A click, scroll or key: the hint goes, and the control under the pointer keeps quiet until it is left.
    public func dismiss() {
        pending?.cancel()
        timing.cooled()
        if let hovered { suppressed = hovered }
        owner = nil
        if current != nil { current = nil }
    }
}

private struct HintsKey: EnvironmentKey {
    static let defaultValue: HoverHints? = nil
}

private struct OverlaysKey: EnvironmentKey {
    static let defaultValue: Overlays? = nil
}

extension EnvironmentValues {
    /// The window's hints; nil where nothing draws them (offscreen stills of a single panel).
    var strataHints: HoverHints? {
        get { self[HintsKey.self] }
        set { self[HintsKey.self] = newValue }
    }

    /// The window's in-window menus, for small views that offer one (selectable text's Copy).
    var strataOverlays: Overlays? {
        get { self[OverlaysKey.self] }
        set { self[OverlaysKey.self] = newValue }
    }
}

public extension View {
    /// An in-window hover hint for this control: what it does in a few words, and its shortcut.
    func strataHint(_ text: String, shortcut: String? = nil) -> some View {
        modifier(HintModifier(text: text, shortcut: shortcut))
    }

    /// The same, with the shortcut taken from the app's one list.
    func strataHint(_ text: String, _ shortcut: Shortcut) -> some View {
        modifier(HintModifier(text: text, shortcut: shortcut.display))
    }

    /// Hands the window's hints and menus to the views inside (RootView does this for the whole window).
    func strataOverlays(_ overlays: Overlays?) -> some View {
        environment(\.strataHints, overlays?.hints).environment(\.strataOverlays, overlays)
    }

    /// Selectable text whose right-click is the app's own Copy, never the system's text menu (a separate
    /// window that screen sharing would see). Offscreen, where no window hosts menus, it is plain text.
    func strataSelectable(_ title: String = "Copy", text: @escaping @MainActor () -> String) -> some View {
        modifier(SelectableModifier(title: title, text: text))
    }
}

private struct SelectableModifier: ViewModifier {
    let title: String
    let text: @MainActor () -> String
    @Environment(\.strataOverlays) private var overlays

    func body(content: Content) -> some View {
        if let overlays {
            content.textSelection(.enabled).strataMenu(overlays) {
                [MenuItem(title, icon: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text(), forType: .string)
                    overlays.toast("Copied")
                }]
            }
        } else {
            content
        }
    }
}

/// Where a hinted control is: written as it moves, read only when its hint shows, so nothing re-renders.
@MainActor
private final class HintAnchor {
    var frame: CGRect = .zero
}

private struct HintModifier: ViewModifier {
    let text: String
    let shortcut: String?
    @Environment(\.strataHints) private var hints
    @State private var anchor = HintAnchor()

    func body(content: Content) -> some View {
        if let hints, !text.isEmpty {
            let id = ObjectIdentifier(anchor)
            content
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
                    anchor.frame = frame
                    if let pinned = hints.pinned, text.localizedCaseInsensitiveContains(pinned) {
                        hints.enter(id, text: text, shortcut: shortcut, now: true) { [anchor] in anchor.frame }
                    }
                }
                .onHover { inside in
                    if inside {
                        hints.enter(id, text: text, shortcut: shortcut) { [anchor] in anchor.frame }
                    } else {
                        hints.leave(id)
                    }
                }
                .onChange(of: text) { _, now in hints.update(id, text: now, shortcut: shortcut) }
                .onDisappear { hints.leave(id) }
        } else {
            content
        }
    }
}

/// Draws the current hint above everything in the window, clamped to it and clear of the control.
/// Clicks, scrolls and keys dismiss it (and pass through: a hint never takes an event).
@MainActor
struct HintLayer: View {
    let hints: HoverHints
    let size: CGSize

    private static let font = NSFont.systemFont(ofSize: 11)
    private static let keyFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    static let maxWidth: CGFloat = 340

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let hint = hints.current {
                let measured = Self.size(hint)
                let frame = HintPlacement.frame(size: measured, anchor: hint.anchor, bounds: size, preferAbove: hint.above)
                bubble(hint)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.1), value: hints.current == nil)
        .background {
            WindowEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown, .magnify]) { event, _ in
                hints.dismiss()
                return event
            }
        }
        .accessibilityHidden(true)
    }

    private func bubble(_ hint: HoverHints.Hint) -> some View {
        HStack(spacing: 7) {
            Text(hint.text)
                .font(Theme.small)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
            if let shortcut = hint.shortcut {
                Text(shortcut)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 4)
                    .frame(height: 16)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border))
                    .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background(Theme.overlay, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(Theme.borderStrong))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }

    /// Measured once per hint with AppKit, so placement needs no layout pass.
    static func size(_ hint: HoverHints.Hint) -> CGSize {
        let text = ceil((hint.text as NSString).size(withAttributes: [.font: font]).width)
        let key = hint.shortcut.map { ceil(($0 as NSString).size(withAttributes: [.font: keyFont]).width) + 8 + 7 } ?? 0
        return CGSize(width: min(maxWidth, text + key + 16 + 1), height: 24)
    }
}

// MARK: - Matching keys

extension Shortcut {
    /// Whether a key event is this shortcut (any of its keys or alternates, exactly its modifiers).
    /// Letters match by key code too, so a non-Latin layout still reaches them.
    func matches(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        for key in keys + alternates {
            switch key {
            case .char(let c):
                let symbol = c.unicodeScalars.first.map { !CharacterSet.alphanumerics.contains($0) } ?? false
                // A typed symbol may need ⇧ (`?`, `+`): compare the character and ignore ⇧ for it.
                let wanted = symbol ? modifiers.subtracting(.shift) : modifiers
                let have = symbol ? flags.subtracting(.shift) : flags
                guard have == wanted.eventFlags else { continue }
                let typed = (symbol ? event.characters : event.charactersIgnoringModifiers)?.lowercased()
                if typed == c { return true }
                if let code = Self.keyCodes[c], event.keyCode == code { return true }
            default:
                guard flags == modifiers.eventFlags, let code = Self.specialCodes[key], event.keyCode == code else { continue }
                return true
            }
        }
        return false
    }

    /// ANSI key codes, for layouts where the character differs.
    private static let keyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "0": 29,
    ]
    private static let specialCodes: [Key: UInt16] = [
        .space: 49, .escape: 53, .enter: 36, .left: 123, .right: 124, .down: 125, .up: 126, .home: 115, .end: 119,
    ]
}

extension Shortcut.Modifiers {
    var eventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.option) { flags.insert(.option) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.control) { flags.insert(.control) }
        return flags
    }
}
