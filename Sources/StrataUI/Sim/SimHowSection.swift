import SwiftUI
import StrataCore

/// The inspector's "How it works" section: one card per mechanism of a node or an operation, with a
/// thumbnail of the sequence and a Play button that opens the player over the stage.
@MainActor
struct SimHowSection: View {
    let mechanisms: [Mechanism]
    let node: String
    var op: String?
    let owner: String
    let model: AppModel
    let sim: Simulation
    let terms: TermIndex
    let actions: SimActions

    var body: some View {
        SimSection(title: "How it works") {
            ForEach(mechanisms) { mechanism in
                SimHowCard(mechanism: mechanism, model: model, terms: terms, actions: actions) {
                    SimHowState.of(sim).open(mechanism, ref: SimHowRef(node: node, op: op, mechanism: mechanism.id), owner: owner)
                }
            }
        }
    }
}

@MainActor
private struct SimHowCard: View {
    let mechanism: Mechanism
    let model: AppModel
    let terms: TermIndex
    let actions: SimActions
    let play: () -> Void
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(Theme.ui(11, .semibold)).foregroundStyle(Theme.accent)
                    .frame(width: 22, height: 22)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                Text(mechanism.title).font(Theme.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if let summary = mechanism.summary {
                SimMarkdown(source: summary, model: model, terms: terms, size: 12, lineLimit: 4)
            }
            Button(action: play) {
                SimHowThumbnail(mechanism: mechanism)
                    .frame(height: thumbnailHeight)
                    .padding(.vertical, 6)
                    .background(Theme.bg.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(hovered ? Theme.accent.opacity(0.4) : Theme.border))
                    .overlay(alignment: .top) {
                        // Below the participants' names, so it never covers one.
                        Image(systemName: "play.fill")
                            .font(Theme.ui(13, .bold)).foregroundStyle(Theme.bg)
                            .frame(width: 34, height: 34)
                            .background(Theme.accent, in: Circle())
                            .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
                            .opacity(hovered ? 1 : 0.92)
                            .scaleEffect(hovered ? 1.06 : 1)
                            .padding(.top, 20)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .accessibilityLabel("Play \(mechanism.title)")
            HStack(spacing: 6) {
                SimButton(title: "Play", icon: "play.fill", active: true, action: play)
                Text(stats).font(Theme.ui(11)).foregroundStyle(Theme.faint).lineLimit(1)
                Spacer(minLength: 0)
            }
            if !mechanism.code.isEmpty {
                ForEach(mechanism.code, id: \.self) { path in
                    SimButton(title: path, icon: "chevron.left.forwardslash.chevron.right") { actions.openCode(path) }
                }
            }
        }
        .padding(10)
        .card()
    }

    private var thumbnailHeight: CGFloat { SimHowThumbnail.height(mechanism) }

    private var stats: String {
        var parts = ["\(mechanism.steps.count) steps"]
        if !mechanism.branches.isEmpty { parts.append("\(mechanism.branches.count) branch\(mechanism.branches.count == 1 ? "" : "es")") }
        if let end = mechanism.play()?.duration, mechanism.timed, end > 0 { parts.append(SimHowFormat.time(end)) }
        return parts.joined(separator: " · ")
    }
}

/// A miniature of the main sequence: lifelines and arrows, enough to recognise the shape of it.
@MainActor
struct SimHowThumbnail: View {
    let mechanism: Mechanism
    static let labelFont = NSFont.systemFont(ofSize: 9, weight: .medium)

    var body: some View {
        Canvas { context, size in
            let participants = mechanism.participants
            guard !participants.isEmpty else { return }
            let left: CGFloat = 26, right = size.width - 26
            var xs: [String: CGFloat] = [:]
            for (index, participant) in participants.enumerated() {
                xs[participant.id] = participants.count == 1 ? size.width / 2
                    : left + (right - left) * CGFloat(index) / CGFloat(participants.count - 1)
            }
            // Each name gets the room up to halfway to its neighbours, cut short with an ellipsis (or left
            // out when there is hardly any room), so names never run into each other.
            let spacing = participants.count > 1 ? (right - left) / CGFloat(participants.count - 1) : size.width
            for (index, participant) in participants.enumerated() {
                guard let x = xs[participant.id] else { continue }
                var line = Path()
                line.move(to: CGPoint(x: x, y: 13))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(Theme.borderStrong), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                let end = participants.count > 1 && (index == 0 || index == participants.count - 1)
                let room = participants.count == 1 ? size.width - 8 : end ? spacing / 2 + 5 : spacing - 6
                guard room >= 16 else { continue }
                let name = TextFit.ellipsize(participant.label, width: Double(room)) {
                    Double(SimHowMeasure.width($0, SimHowThumbnail.labelFont))
                }
                let label = context.resolve(Text(name).font(Theme.ui(9, .medium)).foregroundStyle(Theme.muted))
                let anchor: UnitPoint = index == 0 && participants.count > 1 ? .leading : index == participants.count - 1 && participants.count > 1 ? .trailing : .center
                let shift: CGFloat = anchor == .leading ? -8 : anchor == .trailing ? 8 : 0
                context.draw(label, at: CGPoint(x: x + shift, y: 6), anchor: anchor)
            }
            let steps = mechanism.steps.prefix(12)
            let rows = SimHowThumbnail.rows(Array(steps), height: size.height)
            for (index, step) in steps.enumerated() {
                guard let x1 = xs[step.from], let x2 = xs[step.to] else { continue }
                let y = rows[index]
                let ink = Theme.text.opacity(0.5)
                if x1 == x2 {
                    let s: CGFloat = step.from == participants.last?.id && participants.count > 1 ? -1 : 1
                    var loop = Path()
                    loop.move(to: CGPoint(x: x1, y: y - 2))
                    loop.addLine(to: CGPoint(x: x1 + s * 9, y: y - 2))
                    loop.addLine(to: CGPoint(x: x1 + s * 9, y: y + 2))
                    loop.addLine(to: CGPoint(x: x1, y: y + 2))
                    context.stroke(loop, with: .color(ink), lineWidth: 1)
                } else {
                    let direction: CGFloat = x2 > x1 ? 1 : -1
                    var arrow = Path()
                    arrow.move(to: CGPoint(x: x1, y: y))
                    arrow.addLine(to: CGPoint(x: x2, y: y))
                    arrow.move(to: CGPoint(x: x2 - direction * 4, y: y - 2.5))
                    arrow.addLine(to: CGPoint(x: x2, y: y))
                    arrow.addLine(to: CGPoint(x: x2 - direction * 4, y: y + 2.5))
                    context.stroke(arrow, with: .color(ink), lineWidth: 1)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// Row positions spaced by the time between steps, so a heartbeat rhythm shows even this small.
    static func rows(_ steps: [MechStep], height: CGFloat) -> [CGFloat] {
        var offsets: [CGFloat] = []
        var y: CGFloat = 0
        var previous = 0.0
        let pitch: CGFloat = steps.contains { $0.at != nil } ? 5 : 8
        for (index, step) in steps.enumerated() {
            let time = max(previous, step.at ?? previous)
            if index > 0 { y += pitch + min(12, CGFloat(time - previous) * 1.4) }
            offsets.append(y)
            previous = time
        }
        let room = max(1, height - 24)
        let scale = (offsets.last ?? 0) > room ? room / (offsets.last ?? 1) : 1
        return offsets.map { 20 + $0 * scale }
    }

    /// At least room for the play button under the names; at most 110.
    static func height(_ mechanism: Mechanism) -> CGFloat {
        let rows = rows(Array(mechanism.steps.prefix(12)), height: .infinity)
        return min(110, max(44, (rows.last ?? 20) + 6))
    }
}

/// The overview's list of every mechanism on the level, so they can be played without hunting for
/// the node that has them.
@MainActor
struct SimHowLevelSection: View {
    let sim: Simulation
    let select: (StageSelection?) -> Void

    var body: some View {
        let items = sim.level.nodes.flatMap { node in
            node.how.map { (node: node, op: nil as StrataCore.Operation?, mechanism: $0) }
                + node.ops.flatMap { op in op.how.map { (node: node, op: op as StrataCore.Operation?, mechanism: $0) } }
        }
        if !items.isEmpty {
            SimSection(title: "How it works") {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        if index > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.left.arrow.right")
                                .font(Theme.ui(10, .semibold)).foregroundStyle(Theme.accent)
                                .frame(width: 20, height: 20)
                                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.mechanism.title).font(Theme.ui(12, .medium)).foregroundStyle(Theme.text)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button { select(.node(item.node.id)) } label: {
                                    Text(item.op.map { "\(item.node.label) › \($0.label)" } ?? item.node.label)
                                        .font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
                                }
                                .buttonStyle(.plain)
                            }
                            Spacer(minLength: 4)
                            SimButton(title: "Play", icon: "play.fill", active: true) {
                                SimHowState.of(sim).open(item.mechanism, ref: SimHowRef(node: item.node.id, op: item.op?.id, mechanism: item.mechanism.id),
                                                         owner: item.op?.label ?? item.node.label)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                }
                .card()
            }
        }
    }
}

/// "How it works" in the node menu and in ⌘K: each mechanism opens the player.
@MainActor
enum SimHowMenus {
    static let icon = "arrow.left.arrow.right"

    /// The node's mechanisms and its operations' mechanisms, one item each, or one submenu for several.
    static func node(_ node: Node, sim: Simulation) -> [MenuItem] {
        let items = entries(of: node).map { entry in
            MenuItem(entry.mechanism.title, icon: icon) { open(entry, sim: sim) }
        }
        if items.isEmpty { return [] }
        if items.count == 1 {
            var item = items[0]
            item.title = "How it works: " + item.title
            return [.separator, item]
        }
        return [.separator, .submenu("How it works", icon: icon, items)]
    }

    /// Every mechanism on the level, for the palette.
    static func palette(sim: Simulation) -> [MenuItem] {
        sim.level.nodes.flatMap(entries).map { entry in
            MenuItem("How it works: \(entry.mechanism.title) (\(entry.owner))", icon: icon) { open(entry, sim: sim) }
        }
    }

    private struct Entry {
        let ref: SimHowRef
        let owner: String
        let mechanism: Mechanism
    }

    private static func entries(of node: Node) -> [Entry] {
        node.how.map { Entry(ref: SimHowRef(node: node.id, op: nil, mechanism: $0.id), owner: node.label, mechanism: $0) }
            + node.ops.flatMap { op in
                op.how.map { Entry(ref: SimHowRef(node: node.id, op: op.id, mechanism: $0.id), owner: op.label, mechanism: $0) }
            }
    }

    private static func open(_ entry: Entry, sim: Simulation) {
        SimHowState.of(sim).open(entry.mechanism, ref: entry.ref, owner: entry.owner)
    }
}
