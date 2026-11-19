import SwiftUI
import StrataCore

/// The first time a map or simulator opens: one calm line at the top of the stage naming the four ways in
/// (docs/design.md, First open). It shows until its close button is clicked, once ever (state.json keeps
/// it); offscreen snapshots don't show it unless they ask.
@MainActor
struct SimIntroHint: View {
    let model: AppModel
    static let id = "map-intro"

    var body: some View {
        if model.onboarding, !model.seenHints.contains(Self.id) {
            HStack(spacing: 9) {
                Image(systemName: "hand.point.up.left").font(Theme.ui(11, .medium)).foregroundStyle(Theme.accent)
                ViewThatFits(in: .horizontal) {
                    line([("Click", "a card to inspect it"), ("double-click", "to dive in"), ("right-click", "for actions"),
                          ("⌘K", "for everything"), ("?", "for shortcuts")])
                    line([("Click", "to inspect"), ("double-click", "to dive in"), ("right-click", "for actions"), ("⌘K", "for everything")])
                    line([("Double-click", "to dive in"), ("right-click", "for actions"), ("⌘K", "")])
                    line([("Right-click", "for actions"), ("⌘K", "")])
                }
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(Theme.ui(9, .bold)).foregroundStyle(Theme.muted)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .strataHint("Got it, don't show this again")
                .accessibilityLabel("Dismiss the tip")
            }
            .padding(.leading, 11).padding(.trailing, 5)
            .frame(height: 30)
            .background(Theme.overlay.opacity(0.94), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.borderStrong))
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
            .transition(.opacity)
        }
    }

    private func line(_ parts: [(key: String, rest: String)]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 { Text("  ·  ").foregroundStyle(Theme.faint) }
                Text(part.key).foregroundStyle(Theme.text).fontWeight(.medium)
                if !part.rest.isEmpty { Text(" " + part.rest).foregroundStyle(Theme.muted) }
            }
        }
        .font(Theme.ui(12))
        .lineLimit(1)
        .fixedSize()
    }

    private func dismiss() {
        withAnimation(Theme.snappy) { _ = model.seenHints.insert(Self.id) }
    }
}
