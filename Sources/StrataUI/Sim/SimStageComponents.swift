import Observation
import SwiftUI
import StrataCore

// A service whose deep dive holds several processes (the binaries of a Go repo's `cmd/*`, a worker, a
// scheduler) lists them as chips on its card. A chip dives straight in with that process selected, and
// hovering the card lists every process with its tech, binary and code.

/// One chip on a card, in world coordinates. `component` is nil for the "+N" chip that stands for the rest.
struct StageChip {
    struct Ref: Hashable {
        let node: String
        let component: String?
    }

    let component: String?
    let label: String
    let rect: CGRect
}

extension StageLayout {
    /// The chip row sits between the tech badge and the live line.
    static let chipRowTop: CGFloat = 42
    static let chipHeight: CGFloat = 13

    /// 168 × 64, and 16 pt taller for a card with a row of component chips.
    static func cardSize(for node: Node) -> CGSize {
        CGSize(width: 168, height: hasChips(node) ? 80 : 64)
    }

    static func hasChips(_ node: Node) -> Bool { node.kind != .note && !node.components.isEmpty }
}

extension StageRenderer {
    func drawComponents(_ card: StageLayout.Card, selected: Bool, in context: GraphicsContext) {
        guard StageLayout.hasChips(card.node) else { return }
        for chip in chipLayout(card, in: context) {
            let hot = hoveredChip == StageChip.Ref(node: card.node.id, component: chip.component)
            let shape = Path(roundedRect: chip.rect, cornerRadius: 4)
            context.fill(shape, with: .color(hot ? Theme.accent.opacity(0.16) : selected ? Theme.accent.opacity(0.07) : Theme.hover))
            context.stroke(shape, with: .color(hot ? Theme.accent.opacity(0.6) : Theme.border), lineWidth: hot ? 1 : 0.5)
            let label = text(chip.label, .chip(hot ? Theme.text : Theme.muted), width: chip.rect.width - 9, in: context)
            context.draw(label, at: CGPoint(x: chip.rect.midX, y: chip.rect.midY))
        }
    }

    /// The chip at a world point, on any card.
    func chip(at point: CGPoint) -> StageChip.Ref? {
        for (node, list) in chips {
            if let chip = list.first(where: { $0.rect.insetBy(dx: -1.5, dy: -2).contains(point) }) {
                return StageChip.Ref(node: node, component: chip.component)
            }
        }
        return nil
    }

    /// Chips left to right in the order the deep dive declares them; when the rest don't fit, "+N".
    private func chipLayout(_ card: StageLayout.Card, in context: GraphicsContext) -> [StageChip] {
        if let cached = chips[card.node.id] { return cached }
        let components = card.node.components
        let r = card.rect
        let left = r.minX + 10, right = r.maxX - 10, gap: CGFloat = 4
        let y = r.minY + StageLayout.chipRowTop
        func width(_ label: String) -> CGFloat {
            text(label, .chip(Theme.muted), in: context).measure(in: CGSize(width: 400, height: 20)).width + 10
        }
        var result: [StageChip] = []
        var x = left
        for (index, component) in components.enumerated() {
            let rest = components.count - index - 1
            let more = rest > 0 ? width("+\(rest)") + gap : 0
            var w = width(component.label)
            if x + w + more > right {
                if index == 0 {
                    w = max(28, right - x - more)   // a long first label truncates rather than vanish
                } else {
                    let label = "+\(components.count - index)"
                    result.append(StageChip(component: nil, label: label,
                                            rect: CGRect(x: x, y: y, width: width(label), height: StageLayout.chipHeight)))
                    break
                }
            }
            result.append(StageChip(component: component.id, label: component.label,
                                    rect: CGRect(x: x, y: y, width: w, height: StageLayout.chipHeight)))
            x += w + gap
        }
        chips[card.node.id] = result
        return result
    }
}

/// The card and chip under the pointer, per session. The chip lights at once; the list of components
/// opens after a short hover so passing over a card doesn't flash it.
@MainActor
@Observable
final class SimComponentsHover {
    private(set) var node: String?
    private(set) var chip: StageChip.Ref?
    private(set) var showsCard = false
    @ObservationIgnored private var task: Task<Void, Never>?

    private static let stores = NSMapTable<Simulation, SimComponentsHover>.weakToStrongObjects()

    static func of(_ sim: Simulation) -> SimComponentsHover {
        if let store = stores.object(forKey: sim) { return store }
        let store = SimComponentsHover()
        stores.setObject(store, forKey: sim)
        return store
    }

    /// The pointer is over `node` (nil: off every card with chips) and over `chip` when on one.
    func track(node: String?, chip: StageChip.Ref?) {
        if chip != self.chip { self.chip = chip }
        guard node != self.node else { return }
        task?.cancel()
        if showsCard { showsCard = false }
        self.node = node
        guard node != nil else { return }
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.showsCard = true
        }
    }

    func clear() { track(node: nil, chip: nil) }

    fileprivate func show(node: String, chip: String?) {
        task?.cancel()
        self.node = node
        self.chip = chip.map { StageChip.Ref(node: node, component: $0) }
        showsCard = true
    }
}

/// The processes inside a service: name, kind, tech, binary and code. Drawn in the stage, never in a window.
@MainActor
struct StageComponentsCard: View {
    let node: Node
    let highlighted: String?

    static let width: CGFloat = 300

    /// A rough height, to choose between above and below the card before it is measured.
    static func estimatedHeight(_ node: Node) -> CGFloat {
        CGFloat(54) + node.components.reduce(0) { $0 + 26 + ($1.binary == nil ? 0 : 15) + ($1.code.isEmpty ? 0 : 15) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Inside \(node.label)").font(Theme.label).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer(minLength: 8)
                Text(node.components.count == 1 ? "1 process" : "\(node.components.count) processes")
                    .font(Theme.mono(10)).foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 11).padding(.top, 9).padding(.bottom, 5)
            ForEach(node.components) { component in row(component) }
            Text("Click a chip to open it inside \(node.label).")
                .font(Theme.ui(10)).foregroundStyle(Theme.faint).lineLimit(1)
                .padding(.horizontal, 11).padding(.top, 5).padding(.bottom, 9)
        }
        .frame(width: Self.width, alignment: .leading)
        .background(Theme.overlay, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.borderStrong))
        .shadow(color: .black.opacity(0.42), radius: 14, x: 0, y: 8)
        .accessibilityElement(children: .combine)
    }

    private func row(_ component: Node) -> some View {
        let lit = component.id == highlighted
        let tint = component.simTint
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: component.icon ?? component.kind.symbol)
                .font(Theme.ui(10, .semibold)).foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(component.label).font(Theme.ui(12, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    if let tech = component.tech, !tech.isEmpty {
                        Text(tech).font(Theme.mono(10)).foregroundStyle(Theme.muted).lineLimit(1)
                            .padding(.horizontal, 4).frame(height: 14)
                            .background(Theme.hover, in: RoundedRectangle(cornerRadius: 4))
                    }
                    Spacer(minLength: 4)
                    Text(component.kind.rawValue).font(Theme.mono(10)).foregroundStyle(Theme.faint)
                }
                .frame(height: 20)
                if let binary = component.binary {
                    HStack(spacing: 4) {
                        Image(systemName: "terminal").font(Theme.ui(9, .medium))
                        Text(binary).font(Theme.mono(10.5)).lineLimit(1).truncationMode(.middle)
                    }
                    .foregroundStyle(Theme.info)
                }
                if let code = component.code.first {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right").font(Theme.ui(8, .medium))
                        Text(component.code.count > 1 ? "\(code) +\(component.code.count - 1)" : code)
                            .font(Theme.mono(10)).lineLimit(1).truncationMode(.middle)
                    }
                    .foregroundStyle(Theme.faint)
                }
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 4)
        .background(lit ? Theme.accent.opacity(0.09) : .clear)
        .overlay(alignment: .leading) {
            if lit { Rectangle().fill(Theme.accent).frame(width: 2) }
        }
    }
}

/// Offscreen snapshots: hover a card with chips, optionally over one chip.
@_spi(Snapshots) @MainActor
public enum SimComponentsSnapshot {
    public static func hover(_ sim: Simulation, node: String, component: String? = nil) {
        SimComponentsHover.of(sim).show(node: node, chip: component)
    }
}
