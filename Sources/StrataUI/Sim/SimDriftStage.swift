import SwiftUI
import StrataCore

extension StageRenderer {
    /// A stale node's mark (docs/design.md, Drift): two small arrows going round, out of sync with the repo,
    /// in the warning colour among the card's status glyphs. Its count is in the inspector, not on the card.
    func drawDriftMarker(at point: CGPoint, in context: GraphicsContext) {
        symbol(SimDriftMenus.icon, at: point, size: 10, tint: Theme.warn.opacity(0.85), in: context)
    }
}
