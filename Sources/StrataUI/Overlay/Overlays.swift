import SwiftUI
import AppKit
import StrataCore

// In-window menus, hover cards and toasts. Strata never opens a separate system window for these
// (no .contextMenu, .popover, .help, .sheet, NSMenu): every window is hidden from screen sharing,
// and a separate menu/popover window would not be. OverlayHost (shell) draws this state above everything.
// CONTRACT FILE: owned by the lead.

public struct MenuItem: Identifiable {
    public enum Role { case normal, destructive }
    public let id = UUID()
    public var title: String
    public var icon: String?              // SF Symbol
    public var shortcut: String?          // display only, e.g. "⌘K"
    public var role: Role = .normal
    public var enabled = true
    public var checked = false
    public var submenu: [MenuItem] = []
    public var isSeparator = false
    public var isHeader = false           // a non-clickable section label
    public var action: (@MainActor () -> Void)?

    public init(_ title: String, icon: String? = nil, shortcut: String? = nil, role: Role = .normal,
                enabled: Bool = true, checked: Bool = false, action: (@MainActor () -> Void)? = nil) {
        self.title = title; self.icon = icon; self.shortcut = shortcut; self.role = role
        self.enabled = enabled; self.checked = checked; self.action = action
    }
    public static func submenu(_ title: String, icon: String? = nil, _ items: [MenuItem]) -> MenuItem {
        var m = MenuItem(title, icon: icon); m.submenu = items; return m
    }
    public static var separator: MenuItem { var m = MenuItem(""); m.isSeparator = true; return m }
    public static func header(_ title: String) -> MenuItem { var m = MenuItem(title); m.isHeader = true; m.enabled = false; return m }
}

@MainActor
@Observable
public final class Overlays {
    public struct Menu { public var items: [MenuItem]; public var at: CGPoint }
    public struct Card {
        public var term: Term
        public var anchor: CGRect          // global (window) coordinates, top-left origin
        public var pinned: Bool
        public var index: TermIndex?       // to resolve `related` chips
        /// A formula to typeset instead of the term's text (a node's ƒ badge); `term.term` is its title.
        public var formula: Formula?
    }

    public var menu: Menu?
    public var card: Card?
    public private(set) var toast: String?
    @ObservationIgnored private var toastGen = 0

    public init() {}

    /// `at` is in global (window) coordinates, top-left origin: what `.onRightClick` hands you.
    public func showMenu(_ items: [MenuItem], at: CGPoint) { card = nil; menu = Menu(items: items, at: at) }
    public func dismissMenu() { menu = nil }

    public func showTerm(_ term: Term, anchor: CGRect, pinned: Bool = false, index: TermIndex? = nil) {
        if let c = card, c.pinned, !pinned { return }
        card = Card(term: term, anchor: anchor, pinned: pinned, index: index)
    }
    /// A formula card (docs/manifest.md, Formulas), placed and dismissed like a term card.
    public func showFormula(_ formula: Formula, title: String, anchor: CGRect, pinned: Bool = false) {
        if let c = card, c.pinned, !pinned { return }
        card = Card(term: Term(id: "formula:" + title, term: title, short: formula.expr), anchor: anchor, pinned: pinned,
                    index: nil, formula: formula)
    }
    /// Hides an unpinned card (hover ended). Pinned cards close via `closeTerm`.
    public func hideTerm() { if card?.pinned == false { card = nil } }
    public func closeTerm() { card = nil }

    public func toast(_ text: String) {
        toast = text; toastGen += 1
        let g = toastGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            if self?.toastGen == g { self?.toast = nil }
        }
    }
}

// MARK: - Right click

public extension View {
    /// Right-click (or control-click) anywhere on this view. `local` is in the view's own space,
    /// `global` in window space (top-left origin), ready for `Overlays.showMenu(at:)`.
    func onRightClick(_ action: @escaping @MainActor (_ local: CGPoint, _ global: CGPoint) -> Void) -> some View {
        overlay(RightClickCatcher(action: action))
    }

    /// Convenience: a static menu on right-click.
    func strataMenu(_ overlays: Overlays, _ items: @escaping @MainActor () -> [MenuItem]) -> some View {
        onRightClick { _, g in overlays.showMenu(items(), at: g) }
    }
}

private struct RightClickCatcher: NSViewRepresentable {
    let action: @MainActor (CGPoint, CGPoint) -> Void
    func makeNSView(context: Context) -> CatcherView { CatcherView(action: action) }
    func updateNSView(_ v: CatcherView, context: Context) { v.action = action }

    final class CatcherView: NSView {
        var action: @MainActor (CGPoint, CGPoint) -> Void
        init(action: @escaping @MainActor (CGPoint, CGPoint) -> Void) { self.action = action; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override var isFlipped: Bool { true }

        // Only claim right clicks and control-clicks; everything else falls through to SwiftUI.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let e = NSApp.currentEvent else { return nil }
            let right = e.type == .rightMouseDown || (e.type == .leftMouseDown && e.modifierFlags.contains(.control))
            return right ? super.hitTest(point) : nil
        }
        override func menu(for event: NSEvent) -> NSMenu? { nil }
        override func rightMouseDown(with e: NSEvent) { fire(e) }
        override func mouseDown(with e: NSEvent) { if e.modifierFlags.contains(.control) { fire(e) } }

        private func fire(_ e: NSEvent) {
            let local = convert(e.locationInWindow, from: nil)
            var global = local
            if let root = window?.contentView {
                let p = root.convert(e.locationInWindow, from: nil)
                global = CGPoint(x: p.x, y: root.isFlipped ? p.y : root.bounds.height - p.y)
            }
            MainActor.assumeIsolated { action(local, global) }
        }
    }
}
