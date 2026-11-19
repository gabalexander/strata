import SwiftUI
import StrataCore

/// A small glyph on a card (docs/design.md, Nodes): the ops count, the deep-dive layers, the note, drift,
/// slow and down marks, the replica dots. The renderer records where it drew each one; hovering one shows
/// its hint (Hints.swift) in place of the card's own hover card, so only one thing explains at a time. The hint
/// sits above the card for a glyph on its upper half and below it for one on its lower half.
struct StageGlyph: Equatable {
    enum Kind: Equatable {
        case ops(Int), deepDive, note, drift, slow, down, replicas(Int)
    }

    let kind: Kind
    /// In stage (world) space.
    let rect: CGRect

    init(_ kind: Kind, rect: CGRect) {
        self.kind = kind
        self.rect = rect
    }

    /// A symbol drawn centred on `point`, with a little slack for the pointer.
    init(_ kind: Kind, around point: CGPoint) {
        self.init(kind, rect: CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16))
    }

    /// What the hint says: what the glyph means and how to get at it.
    var hint: String {
        switch kind {
        case .ops(let count): count == 1 ? "1 operation: select the card to see it" : "\(count) operations: select the card to list them"
        case .deepDive: "Has a deep dive: double-click to go inside"
        case .note: "Your note: right-click › Open note"
        case .drift: "Out of date with the repo: select for details"
        case .slow: "Slowed ×10: right-click › Normal speed"
        case .down: "Down: right-click › Restore"
        case .replicas(let count): "\(count) replicas"
        }
    }

    var shortcut: String? {
        switch kind {
        case .deepDive: Shortcuts.doubleClick.display
        default: nil
        }
    }
}

extension StageRenderer {
    /// The glyph under a point in stage space, on the card the pointer is over.
    func glyph(at point: CGPoint, on target: StageSelection?) -> StageGlyph? {
        guard case .node(let id)? = target else { return nil }
        return glyphs[id]?.first { $0.rect.insetBy(dx: -2, dy: -2).contains(point) }
    }
}

/// Which glyph the pointer is on, kept out of SwiftUI's state so moving across glyphs re-renders nothing.
@MainActor
final class StageGlyphHover {
    var key: String?
}

/// Offscreen snapshots: the stage shows this node's first glyph hint (`STRATA_SNAP_GLYPH=node`), as if hovered.
@_spi(Snapshots) @MainActor
public enum SimGlyphSnapshot {
    public static var node: String?
}
