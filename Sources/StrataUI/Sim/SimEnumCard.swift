import AppKit
import SwiftUI
import StrataCore

/// The hover card for an enum value, drawn by the overlay host like a glossary term's card: below its
/// anchor or flipped above it, clamped to the window. It never takes clicks; the value under it does.
@MainActor
struct SimEnumCardLayer: View {
    let model: AppModel
    let size: CGSize

    var body: some View {
        let state = SimEnumState.of(model)
        ZStack(alignment: .topLeading) {
            if let card = state.card, model.overlays.menu == nil, model.overlays.card == nil, !model.paletteOpen {
                SimEnumCardPlacement(card: card, size: size)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in state.hideCard() }
        .background {
            // Values in selectable code are drawn by AppKit: watch clicks on them here, without taking them.
            WindowEvents(matching: [.leftMouseDown, .leftMouseUp]) { event, _ in
                state.mouse(event.type, at: event.contentLocation, model: model)
                return event
            }
            .accessibilityHidden(true)
        }
    }
}

@MainActor
private struct SimEnumCardPlacement: View {
    let card: SimEnumState.Card
    let size: CGSize
    @State private var height: CGFloat = 120

    var body: some View {
        let margin: CGFloat = 9
        let width = min(320, max(0, size.width - margin * 2))
        let below = card.anchor.maxY + 6
        let above = card.anchor.minY - height - 6
        let proposedY = below + height + margin <= size.height ? below : above
        let x = min(max(margin, card.anchor.minX - 10), max(margin, size.width - width - margin))
        let y = min(max(margin, proposedY), max(margin, size.height - height - margin))
        SimEnumCardView(content: card.content)
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height = ceil($0) }
            .position(x: x + width / 2, y: y + height / 2)
            .accessibilityElement(children: .combine)
    }
}

/// `Order status`, `20 → paid`, what it means, terminal, and where it can go next.
struct SimEnumCardView: View {
    let content: SimEnumCardContent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "tag").font(Theme.ui(9.5, .semibold)).foregroundStyle(simEnumTint)
                Text(content.label).font(Theme.ui(11, .medium)).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer(minLength: 0)
                if content.value?.terminal == true { SimEnumFlag(title: "terminal", symbol: "circle.circle") }
                else if content.starts { SimEnumFlag(title: "start", symbol: "smallcircle.filled.circle") }
            }
            headline
            if let value = content.value {
                if let doc = value.doc {
                    Text(doc).font(Theme.ui(12)).foregroundStyle(Theme.text).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                next
            } else {
                Text("\(content.label) has no value \(content.literal). Check the code, or add it to the enum.")
                    .font(Theme.ui(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Text(content.value == nil ? "Click to see its values" : "Click to open the state machine")
                .font(Theme.ui(10.5)).foregroundStyle(Theme.faint)
                .padding(.top, 1)
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .background(Theme.overlay, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.borderStrong))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 9)
    }

    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            if let value = content.value {
                if content.coded || content.literal != value.name {
                    Text(content.literal).font(Theme.mono(13, .semibold)).foregroundStyle(Theme.accent)
                    Image(systemName: "arrow.right").font(Theme.ui(10, .semibold)).foregroundStyle(Theme.faint)
                    Text(value.name).font(Theme.ui(14, .semibold)).foregroundStyle(Theme.text)
                    if content.literal != value.value {
                        Text(value.value).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    }
                } else {
                    Text(value.name).font(Theme.mono(13, .semibold)).foregroundStyle(Theme.accent)
                }
            } else {
                Text(content.literal).font(Theme.mono(13, .semibold)).foregroundStyle(Theme.warn)
                Image(systemName: "arrow.right").font(Theme.ui(10, .semibold)).foregroundStyle(Theme.faint)
                Text("unknown value").font(Theme.ui(13, .semibold)).foregroundStyle(Theme.warn)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var next: some View {
        if !content.next.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("Next").font(Theme.ui(10.5, .semibold)).foregroundStyle(Theme.faint)
                ForEach(content.next) { step in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "arrow.turn.down.right").font(Theme.ui(9, .semibold)).foregroundStyle(Theme.faint)
                        Text(stepTitle(step)).font(Theme.mono(11, .medium)).foregroundStyle(Theme.text).fixedSize()
                        VStack(alignment: .leading, spacing: 1) {
                            if let label = step.label {
                                Text(label).font(Theme.ui(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                            }
                            if let by = step.by {
                                Text("by \(by)").font(Theme.mono(10)).foregroundStyle(Theme.faint).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(Theme.border))
        } else if content.value?.terminal == true {
            Text("A final state: nothing moves out of it.").font(Theme.ui(11)).foregroundStyle(Theme.muted)
        }
    }

    private func stepTitle(_ step: SimEnumCardContent.Next) -> String {
        guard let name = step.name else { return step.code }
        return content.coded ? "\(step.code) \(name)" : name
    }

}

/// `terminal`, `start`: a small capsule beside the enum's label.
struct SimEnumFlag: View {
    let title: String
    var symbol: String?
    var tint: Color = Theme.muted

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(Theme.ui(8.5, .semibold)) }
            Text(title).font(Theme.ui(10, .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(tint.opacity(0.10), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.22)))
        .fixedSize()
    }
}
