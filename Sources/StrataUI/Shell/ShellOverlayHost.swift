import AppKit
import SwiftUI
import StrataCore

@MainActor
struct OverlayHost: View {
    let model: AppModel
    private var overlays: Overlays { model.overlays }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if let card = overlays.card {
                    TermCardOverlay(card: card, overlays: overlays, size: geometry.size)
                        .allowsHitTesting(card.pinned)
                }
                SimEnumCardLayer(model: model, size: geometry.size)
                if let menu = overlays.menu, !menu.items.isEmpty {
                    ContextMenuOverlay(menu: menu, overlays: overlays, size: geometry.size)
                        .id(menu.items.map(\.id))
                }
                toast
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .onChange(of: geometry.size) { overlays.dismissMenu() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
                overlays.dismissMenu()
                overlays.hideTerm()
            }
            .background {
                WindowEvents(matching: .keyDown) { event, _ in
                    guard !event.hasCommandModifiers, event.keyCode == 53,
                          overlays.menu == nil, overlays.card != nil,
                          !model.paletteOpen, !model.switcherOpen else { return event }
                    if !event.isARepeat { overlays.closeTerm() }
                    return nil
                }
            }
        }
    }

    private var toast: some View {
        VStack {
            Spacer()
            if let message = overlays.toast {
                Label(message, systemImage: "info.circle")
                    .font(Theme.ui(12, .medium))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(Theme.overlay, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.borderStrong))
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                    .padding(.bottom, 22)
                    .transition(.opacity)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.18), value: overlays.toast)
    }
}

@MainActor
private struct TermCardOverlay: View {
    let card: Overlays.Card
    let overlays: Overlays
    let size: CGSize
    @State private var contentHeight: CGFloat = 160

    var body: some View {
        let margin: CGFloat = 9
        let width = min(340, max(0, size.width - margin * 2))
        let height = min(contentHeight, max(0, size.height - margin * 2))
        let centred = card.anchor == .zero
        let proposedX = centred ? (size.width - width) / 2 : card.anchor.minX
        let below = card.anchor.maxY + 7
        let above = card.anchor.minY - height - 7
        let proposedY = centred ? (size.height - height) / 2 : below + height + margin <= size.height ? below : above
        let x = min(max(margin, proposedX), max(margin, size.width - width - margin))
        let y = min(max(margin, proposedY), max(margin, size.height - height - margin))

        ScrollView {
            details
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = ceil($0) }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: width, height: height)
        .background(Theme.overlay, in: RoundedRectangle(cornerRadius: Theme.radius))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radius)
                .strokeBorder(Theme.borderStrong)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.45), radius: 18, y: 9)
        .position(x: x + width / 2, y: y + height / 2)
        .accessibilityElement(children: .contain)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(card.term.term)
                    .font(Theme.ui(13, .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if card.pinned {
                    Button { overlays.closeTerm() } label: {
                        Image(systemName: "xmark")
                            .font(Theme.ui(11, .semibold))
                            .foregroundStyle(Theme.muted)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close term")
                }
            }
            termText(card.term.short)
            if let detail = card.term.detail {
                termText(detail).foregroundStyle(Theme.muted)
            }
            if let design = card.term.design {
                VStack(alignment: .leading, spacing: 5) {
                    Text("In a design").font(Theme.label).foregroundStyle(Theme.accent)
                    termText(design)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(Theme.raised, radius: Theme.radiusSmall)
            }
            if card.pinned, let index = card.index {
                let related = (card.term.related ?? []).compactMap(index.term)
                if !related.isEmpty { relatedTerms(related, index: index) }
            }
        }
    }

    private func termText(_ value: String) -> some View {
        let markdown = try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return Text(markdown ?? AttributedString(value))
            .font(Theme.ui(12))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func relatedTerms(_ terms: [Term], index: TermIndex) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            StrataSectionLabel("Related terms")
            ChipFlow(spacing: 4) {
                ForEach(Array(terms.enumerated()), id: \.offset) { _, term in
                    Button {
                        overlays.showTerm(term, anchor: card.anchor, pinned: true, index: index)
                    } label: {
                        StrataChip(term.term, tint: Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Lays chips out in rows, wrapping at the card's width.
private struct ChipFlow: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, rows(bounds.width, subviews).frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, used: CGFloat = 0
        var frames: [CGRect] = []
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += row + spacing
                row = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            used = max(used, x + size.width)
            x += size.width + spacing
            row = max(row, size.height)
        }
        return (CGSize(width: used, height: y + row), frames)
    }
}
