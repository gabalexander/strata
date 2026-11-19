import SwiftUI
import StrataCore

/// The inspector's "Operations" section for a node. Services list their own ops grouped by kind, with
/// the callers of each endpoint under it. Databases, caches and buffers show the reverse view: every
/// op on the level that talks to them, by table, key pattern, or producer and consumer.
///
/// In a deep dive the ops of the node it is inside (`InheritedOps`) join in: a database, cache, buffer
/// or port lists those mapped to it with the rest, and a process lists those it takes part in under
/// "Operations of <owner>", by the node each talks to. With `inherited`, the section is the level
/// overview's: all of the owner's ops, grouped by kind as on the owner's own level.
@MainActor
struct SimOpsSection: View {
    let model: AppModel
    let sim: Simulation
    let actions: SimActions
    let node: Node
    let selection: StageSelection?
    var pulse: SimPulse?
    var still = false
    /// The overview of a deep dive: `node` is the owner, and the section lists its inherited ops.
    var inherited = false

    private var state: SimOpsState { SimOpsState.of(sim) }
    private var index: SimOpsIndex { state.index }

    var body: some View {
        if inherited { overview } else { nodeOps }
    }

    @ViewBuilder
    private var nodeOps: some View {
        let own = index.ops(of: node.id)
        let process = Node.componentKinds.contains(node.kind)
        let incoming = index.targeting(node.id).filter { !(process && $0.inherited) }
        let through = process ? index.inherited(through: node.id) : []
        if node.kind != .note, !own.isEmpty || !incoming.isEmpty || !through.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if !own.isEmpty || !incoming.isEmpty {
                    header("Operations", count: own.count + incoming.count)
                    switch node.kind {
                    case .database, .search: tables(incoming)
                    case .cache: keys(incoming)
                    case .queue, .topic: buffer(incoming)
                    default: EmptyView()
                    }
                    ownGroups(own, incoming: [.database, .search, .cache, .queue, .topic].contains(node.kind) ? [] : incoming)
                }
                if !through.isEmpty, let owner = index.inheritance?.owner {
                    VStack(alignment: .leading, spacing: 3) {
                        header("Operations of \(owner.label)", count: through.count)
                        Text("Mapped to \(node.label) or to a node it calls.")
                            .font(Theme.small).foregroundStyle(Theme.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, own.isEmpty && incoming.isEmpty ? 0 : 6)
                    byPeer(through)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The deep dive's overview: the owner's ops as its own level lists them, grouped by kind.
    @ViewBuilder
    private var overview: some View {
        let entries = index.inherited
        if !entries.isEmpty {
            let mapped = entries.filter { $0.peer != nil }.count
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    header("Operations of \(node.label)", count: entries.count)
                    Text(mapped == 0 ? "Kept on \(node.label) in the overview."
                         : "Kept on \(node.label) in the overview; \(mapped) talk to a node here. Hover one to light its path.")
                        .font(Theme.small).foregroundStyle(Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ownGroups(entries, incoming: [])
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).font(Theme.ui(11, .semibold)).foregroundStyle(Theme.muted).lineLimit(1)
            Text(String(count)).font(Theme.mono(10)).foregroundStyle(Theme.faint)
            Spacer(minLength: 0)
        }
    }

    /// A process's inherited ops, by the node each talks to: `orders db 6`, `prices 2`.
    @ViewBuilder
    private func byPeer(_ entries: [SimOpsIndex.Entry]) -> some View {
        let here = entries.filter { $0.peer == node.id || $0.peer == nil }
        let peers = entries.compactMap(\.peer).filter { $0 != node.id }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if !here.isEmpty {
            SimOpsGroupBox(title: "Runs here", count: here.count) {
                ForEach(Array(here.enumerated()), id: \.element.ref) { offset, entry in
                    if offset > 0 { SimOpsHairline() }
                    row(entry)
                }
            }
        }
        ForEach(peers, id: \.self) { peer in
            let rows = entries.filter { $0.peer == peer }
            let target = sim.level.node(peer)
            SimOpsGroupBox(title: target?.label ?? peer, symbol: target.map { $0.icon ?? $0.kind.symbol }, count: rows.count) {
                ForEach(Array(rows.enumerated()), id: \.element.ref) { offset, entry in
                    if offset > 0 { SimOpsHairline() }
                    row(entry, summary: SimOpsText.summary(entry, in: sim.level, namingPeer: false))
                }
            }
        }
    }

    // MARK: Own ops

    @ViewBuilder
    private func ownGroups(_ own: [SimOpsIndex.Entry], incoming: [SimOpsIndex.Entry]) -> some View {
        let groups = OpGroup.allCases.compactMap { group -> (OpGroup, [SimOpsIndex.Entry])? in
            let rows = own.filter { OpGroup.of($0.op) == group }
            return rows.isEmpty ? nil : (group, rows)
        }
        ForEach(groups, id: \.0) { group, rows in
            SimOpsGroupBox(title: group.title, count: rows.count) {
                ForEach(Array(rows.enumerated()), id: \.element.ref) { offset, entry in
                    if offset > 0 { SimOpsHairline() }
                    switch group {
                    case .endpoints: row(entry, links: index.linkedCallers[entry.ref] ?? [])
                    case .publishes: row(entry, links: index.linked[entry.ref].map { [$0] } ?? [], forward: true)
                    default: row(entry)
                    }
                }
            }
        }
        // Calls into this node that no `calls:` ties to one of its endpoints.
        let linked = Set(own.flatMap { index.linkedCallers[$0.ref] ?? [] })
        let unlinked = incoming.filter { !linked.contains($0.ref) }
        if !unlinked.isEmpty {
            SimOpsGroupBox(title: "Called from", count: unlinked.count) {
                ForEach(Array(unlinked.enumerated()), id: \.element.ref) { offset, entry in
                    if offset > 0 { SimOpsHairline() }
                    row(entry, owner: true)
                }
            }
        }
    }

    // MARK: Reverse views

    /// A database or search index: who touches each table, flagging tables more than one service writes.
    @ViewBuilder
    private func tables(_ incoming: [SimOpsIndex.Entry]) -> some View {
        // Busiest tables first; ties keep the order the ops name them in.
        let named = incoming.flatMap(\.op.tables).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let names = named.enumerated().sorted { a, b in
            let (x, y) = (incoming.filter { $0.op.tables.contains(a.element) }.count,
                          incoming.filter { $0.op.tables.contains(b.element) }.count)
            return x == y ? a.offset < b.offset : x > y
        }.map(\.element)
        let other = incoming.filter(\.op.tables.isEmpty)
        ForEach(names, id: \.self) { table in
            let rows = incoming.filter { $0.op.tables.contains(table) }
            // An inherited op's node holds this level's processes, so it never counts as another writer.
            let writers = Set(rows.filter { !$0.inherited && [.write, .readWrite].contains(SimOpsText.access($0.op)) }.map(\.node.id))
            SimOpsGroupBox(title: table, symbol: "tablecells", mono: true, count: rows.count,
                           flag: writers.count > 1 ? "shared write · \(writers.count) services" : nil) {
                ForEach(Array(rows.enumerated()), id: \.element.ref) { offset, entry in
                    if offset > 0 { SimOpsHairline() }
                    row(entry, owner: true)
                }
            }
        }
        if !other.isEmpty {
            SimOpsGroupBox(title: names.isEmpty ? "Queries" : "Other queries", count: other.count) {
                ForEach(Array(other.enumerated()), id: \.element.ref) { offset, entry in
                    if offset > 0 { SimOpsHairline() }
                    row(entry, owner: true)
                }
            }
        }
    }

    /// A cache: the ops on each key pattern.
    @ViewBuilder
    private func keys(_ incoming: [SimOpsIndex.Entry]) -> some View {
        let patterns = incoming.map { $0.op.key ?? "" }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        ForEach(patterns, id: \.self) { pattern in
            let rows = incoming.filter { ($0.op.key ?? "") == pattern }
            SimOpsGroupBox(title: pattern.isEmpty ? "No key pattern" : pattern, symbol: pattern.isEmpty ? nil : "key",
                           mono: !pattern.isEmpty, count: rows.count) {
                ForEach(Array(rows.enumerated()), id: \.element.ref) { offset, entry in
                    if offset > 0 { SimOpsHairline() }
                    row(entry, owner: true)
                }
            }
        }
    }

    /// A queue or topic: who publishes into it and who consumes from it, with payload previews.
    @ViewBuilder
    private func buffer(_ incoming: [SimOpsIndex.Entry]) -> some View {
        let producers = incoming.filter { $0.op.kind == .publish }
        let consumers = incoming.filter { $0.op.kind == .consume }
        let other = incoming.filter { $0.op.kind != .publish && $0.op.kind != .consume }
        ForEach([("Producers", producers), ("Consumers", consumers), ("Other", other)], id: \.0) { title, rows in
            if !rows.isEmpty {
                SimOpsGroupBox(title: title, count: rows.count) {
                    ForEach(Array(rows.enumerated()), id: \.element.ref) { offset, entry in
                        if offset > 0 { SimOpsHairline() }
                        // Producer → consumer: the consume op a publish's `calls:` names.
                        row(entry, owner: true, preview: entry.op.payload.map(SimOpsText.preview),
                            links: entry.op.kind == .publish ? index.linked[entry.ref].map { [$0] } ?? [] : [], forward: true)
                    }
                }
            }
        }
    }

    /// `owner` rows belong to other nodes and talk to this one (the reverse view).
    /// `links` are sub-rows: the callers of an endpoint, or (`forward`) the consumer a publish feeds.
    private func row(_ entry: SimOpsIndex.Entry, owner: Bool = false, summary: String? = nil, preview: String? = nil,
                     links: [OpRef] = [], forward: Bool = false) -> some View {
        SimOpRow(sim: sim, entry: entry, owner: owner, summary: summary ?? (owner ? SimOpsText.reverseSummary(entry) : nil),
                 preview: preview,
                 links: links.compactMap(index.entry), forward: forward, pinned: state.isPinned(entry.ref, at: selection), pulse: pulse,
                 still: still,
                 open: { state.open($0, from: selection) },
                 menu: { SimOpsMenus.row(index.entry($0) ?? entry, sim: sim, model: model, anchor: selection) },
                 overlays: model.overlays)
    }
}

/// One op: kind glyph, label, R/W badge, live rate and p99, risk dot, and a compact second line.
@MainActor
struct SimOpRow: View {
    let sim: Simulation
    let entry: SimOpsIndex.Entry
    /// Name the op's node on the second line (reverse views and links between nodes).
    var owner = false
    /// The second line, instead of the op's own summary.
    var summary: String?
    var preview: String?
    /// Sub-rows: an endpoint's callers (`↳ api-gateway · CreateOrder`), or with `forward` the ops this
    /// one reaches (`→ mailer · OrderPlaced`).
    var links: [SimOpsIndex.Entry] = []
    var forward = false
    /// Its path is pinned on the stage ("Highlight path").
    var pinned = false
    /// Beats the live rate and p99 (SimLive); nothing else in the row refreshes with it.
    var pulse: SimPulse?
    var still = false
    let open: (OpRef) -> Void
    let menu: (OpRef) -> [MenuItem]
    let overlays: Overlays
    @State private var hovered = false

    var body: some View {
        let op = entry.op
        VStack(alignment: .leading, spacing: 0) {
            Button { open(entry.ref) } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: op.kind.symbol)
                        .font(Theme.ui(11, .medium))
                        .foregroundStyle(hovered ? Theme.text : Theme.muted)
                        .frame(width: 16, height: 16)
                    SimOpRowLines {
                        HStack(spacing: 6) {
                            Text(op.label).font(Theme.ui(12, .medium)).foregroundStyle(Theme.text)
                                .lineLimit(1).truncationMode(.tail)
                            if !op.risks.isEmpty {
                                Circle().fill(Theme.warn).frame(width: 5, height: 5)
                                    .accessibilityLabel("\(op.risks.count) risks")
                            }
                        }
                        HStack(spacing: 6) {
                            if pinned {
                                Image(systemName: "pin.fill").font(Theme.ui(9)).foregroundStyle(Theme.accent)
                                    .accessibilityLabel("Path pinned")
                            }
                            if let access = SimOpsText.access(op) { SimOpAccessBadge(access: access) }
                        }
                        HStack(spacing: 5) {
                            if owner {
                                Text(entry.node.label).font(Theme.ui(11, .medium)).foregroundStyle(Theme.muted)
                                    .lineLimit(1).layoutPriority(1)
                            }
                            let rest = owner && !secondLine.isEmpty ? "· " + secondLine : secondLine
                            Text(rest).font(Theme.mono(10)).foregroundStyle(Theme.muted)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        SimLive(sim: sim, pulse: pulse) { SimOpRate(sim: sim, ref: entry.ref) }
                        if let preview {
                            Text(preview).font(Theme.mono(10)).foregroundStyle(Theme.faint)
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                }
                .padding(.horizontal, 9).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovered ? Theme.hover : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { inside in
                hovered = inside
                hover(inside ? entry.ref : nil, leaving: entry.ref)
            }
            .simOpsMenu(still: still) { overlays.showMenu(menu(entry.ref), at: $0) }
            .onDisappear { hover(nil, leaving: entry.ref) }
            .accessibilityLabel("\(owner ? entry.node.label + ", " : "")\(op.label), \(secondLine)")
            .accessibilityHint("Opens the operation")
            ForEach(links, id: \.ref) { link in
                SimOpLinkRow(link: link, forward: forward, sim: sim, still: still, open: open, menu: menu, overlays: overlays)
            }
        }
    }

    private var secondLine: String { summary ?? SimOpsText.summary(entry, in: sim.level) }

    private func hover(_ ref: OpRef?, leaving: OpRef) {
        let state = SimOpsState.of(sim)
        if let ref { state.hovered = ref } else if state.hovered == leaving { state.hovered = nil }
    }
}

/// A caller under an endpoint (`↳ api-gateway · CreateOrder`) or a consumer under a producer
/// (`→ mailer · OrderPlaced`).
@MainActor
private struct SimOpLinkRow: View {
    let link: SimOpsIndex.Entry
    let forward: Bool
    let sim: Simulation
    let still: Bool
    let open: (OpRef) -> Void
    let menu: (OpRef) -> [MenuItem]
    let overlays: Overlays
    @State private var hovered = false

    var body: some View {
        Button { open(link.ref) } label: {
            HStack(spacing: 6) {
                Image(systemName: forward ? "arrow.right" : "arrow.turn.down.right")
                    .font(Theme.ui(9, .medium)).foregroundStyle(Theme.faint)
                Text("\(link.node.label) · \(link.op.label)")
                    .font(Theme.ui(11)).foregroundStyle(hovered ? Theme.text : Theme.muted)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.leading, 33).padding(.trailing, 9).padding(.top, 1).padding(.bottom, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovered = inside
            let state = SimOpsState.of(sim)
            if inside { state.hovered = link.ref } else if state.hovered == link.ref { state.hovered = nil }
        }
        .simOpsMenu(still: still) { overlays.showMenu(menu(link.ref), at: $0) }
        .accessibilityLabel("\(forward ? "Reaches" : "Called by") \(link.node.label), \(link.op.label)")
    }
}

/// `4.9/s · 31 ms`, or a dash when no flow step performs the op.
@MainActor
struct SimOpRate: View {
    let sim: Simulation
    let ref: OpRef

    var body: some View {
        let metrics = sim.opMetrics(node: ref.node, op: ref.op)
        Text(SimOpsText.rate(metrics))
            .font(Theme.mono(10)).monospacedDigit()
            .foregroundStyle(metrics.referenced ? Theme.text.opacity(0.78) : Theme.faint)
            .lineLimit(1).fixedSize()
    }
}

/// R, W or RW.
struct SimOpAccessBadge: View {
    let access: OpAccess

    var body: some View {
        let writes = access != .read
        Text(SimOpsText.badge(access))
            .font(Theme.mono(9, .semibold))
            .foregroundStyle(writes ? Theme.text : Theme.muted)
            .padding(.horizontal, 3)
            .frame(minWidth: 16, minHeight: 14)
            .background(writes ? Theme.selected : Theme.hover, in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(writes ? Theme.borderStrong : Theme.border))
            .accessibilityLabel(SimOpsText.accessName(access))
    }
}


/// The lines of an op row: the label and its badge on line one, the summary on line two, an optional
/// preview below. The live numbers sit beside the label when the label still fits, and otherwise end
/// line two, so the label is the last thing to truncate.
/// Subviews, in order: label, badge, summary, numbers, then any extra full-width lines.
private struct SimOpRowLines: Layout {
    private let gap: CGFloat = 6
    private let lineSpacing: CGFloat = 3
    private let firstLine: CGFloat = 16

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 260
        return CGSize(width: width, height: arrange(width, subviews).map(\.maxY).max() ?? firstLine)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, arrange(bounds.width, subviews)) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [CGRect] {
        guard subviews.count >= 4 else { return subviews.map { _ in .zero } }
        let label = subviews[0].sizeThatFits(.unspecified)
        let badge = subviews[1].sizeThatFits(.unspecified)
        let numbers = subviews[3].sizeThatFits(.unspecified)
        let badgeRoom = badge.width > 0 ? badge.width + gap : 0
        let inline = label.width + gap + numbers.width + badgeRoom <= width
        func centred(_ size: CGSize, x: CGFloat, line: CGRect) -> CGRect {
            CGRect(x: x, y: line.minY + (line.height - size.height) / 2, width: size.width, height: size.height)
        }
        let one = CGRect(x: 0, y: 0, width: width, height: firstLine)
        let labelWidth = min(label.width, width - badgeRoom - (inline ? numbers.width + gap : 0))
        var frames = [centred(CGSize(width: max(0, labelWidth), height: label.height), x: 0, line: one),
                      centred(badge, x: width - badge.width, line: one)]
        let summaryWidth = max(0, inline ? width : width - numbers.width - gap)
        let summary = subviews[2].sizeThatFits(ProposedViewSize(width: summaryWidth, height: nil))
        let two = CGRect(x: 0, y: one.maxY + lineSpacing, width: width, height: max(summary.height, numbers.height))
        frames.append(CGRect(x: 0, y: two.minY, width: summaryWidth, height: summary.height))
        frames.append(inline ? centred(numbers, x: width - badgeRoom - numbers.width, line: one)
                             : centred(numbers, x: width - numbers.width, line: two))
        var y = two.maxY
        for view in subviews.dropFirst(4) {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            frames.append(CGRect(x: 0, y: y + lineSpacing, width: width, height: size.height))
            y += lineSpacing + size.height
        }
        return frames
    }
}

/// A labelled card of rows.
struct SimOpsGroupBox<Content: View>: View {
    let title: String
    var symbol: String?
    var mono = false
    var count: Int?
    var flag: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !title.isEmpty { header }
            VStack(alignment: .leading, spacing: 0) { content }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .card(radius: 8)
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(Theme.ui(9, .medium)).foregroundStyle(Theme.faint) }
            Text(title).font(mono ? Theme.mono(10.5, .medium) : Theme.label)
                .foregroundStyle(mono ? Theme.text.opacity(0.82) : Theme.faint).lineLimit(1)
            if let count { Text(String(count)).font(Theme.mono(10)).foregroundStyle(Theme.faint) }
            Spacer(minLength: 4)
            if let flag {
                Label(flag, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.ui(10, .medium)).foregroundStyle(Theme.warn).lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.warn.opacity(0.10), in: Capsule())
            }
        }
        .padding(.horizontal, 2)
    }
}

extension View {
    /// Right-click menus need an AppKit catcher, which offscreen stills can't draw.
    @ViewBuilder
    func simOpsMenu(still: Bool, _ show: @escaping @MainActor (CGPoint) -> Void) -> some View {
        if still { self } else { onRightClick { _, global in show(global) } }
    }
}

struct SimOpsHairline: View {
    var body: some View { Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 33) }
}
