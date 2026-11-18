import SwiftUI
import StrataCore

/// The inspector's "Operations" section for a node. Services list their own ops grouped by kind, with
/// the callers of each endpoint under it. Databases, caches and buffers show the reverse view: every
/// op on the level that talks to them, by table, key pattern, or producer and consumer.
@MainActor
struct SimOpsSection: View {
    let model: AppModel
    let sim: Simulation
    let actions: SimActions
    let node: Node
    let selection: StageSelection?
    var pulse: SimPulse?
    var still = false

    private var state: SimOpsState { SimOpsState.of(sim) }
    private var index: SimOpsIndex { state.index }

    var body: some View {
        let own = index.ops(of: node.id)
        let incoming = index.targeting(node.id)
        if node.kind != .note, !own.isEmpty || !incoming.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text("Operations").font(Theme.ui(11, .semibold)).foregroundStyle(Theme.muted)
                    Text(String(own.count + incoming.count)).font(Theme.mono(10)).foregroundStyle(Theme.faint)
                    Spacer(minLength: 0)
                }
                switch node.kind {
                case .database, .search: tables(incoming)
                case .cache: keys(incoming)
                case .queue, .topic: buffer(incoming)
                default: EmptyView()
                }
                ownGroups(own, incoming: [.database, .search, .cache, .queue, .topic].contains(node.kind) ? [] : incoming)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
                    row(entry, callers: group == .endpoints ? index.linkedCallers[entry.ref] ?? [] : [])
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
            let writers = Set(rows.filter { [.write, .readWrite].contains(SimOpsText.access($0.op)) }.map(\.node.id))
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
                        row(entry, owner: true, preview: entry.op.payload.map(SimOpsText.preview))
                    }
                }
            }
        }
    }

    /// `owner` rows belong to other nodes and talk to this one (the reverse view).
    private func row(_ entry: SimOpsIndex.Entry, owner: Bool = false, preview: String? = nil,
                     callers: [OpRef] = []) -> some View {
        SimOpRow(sim: sim, entry: entry, owner: owner, summary: owner ? SimOpsText.reverseSummary(entry) : nil,
                 preview: preview,
                 callers: callers.compactMap(index.entry), pinned: state.isPinned(entry.ref, at: selection), pulse: pulse,
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
    var callers: [SimOpsIndex.Entry] = []
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
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(op.label).font(Theme.ui(12, .medium)).foregroundStyle(Theme.text)
                                .lineLimit(1).truncationMode(.tail)
                                .layoutPriority(1)
                            if !op.risks.isEmpty {
                                Circle().fill(Theme.warn).frame(width: 5, height: 5)
                                    .accessibilityLabel("\(op.risks.count) risks")
                            }
                            Spacer(minLength: 4)
                            if pinned {
                                Image(systemName: "pin.fill").font(Theme.ui(9)).foregroundStyle(Theme.accent)
                                    .accessibilityLabel("Path pinned")
                            }
                            if !owner { SimLive(sim: sim, pulse: pulse) { SimOpRate(sim: sim, ref: entry.ref) } }
                            if let access = SimOpsText.access(op) { SimOpAccessBadge(access: access) }
                        }
                        .frame(height: 16)
                        if owner {
                            HStack(spacing: 5) {
                                Text(entry.node.label).font(Theme.ui(11, .medium)).foregroundStyle(Theme.muted)
                                    .lineLimit(1).layoutPriority(1)
                                if !secondLine.isEmpty {
                                    Text("· " + secondLine).font(Theme.mono(10)).foregroundStyle(Theme.muted)
                                        .lineLimit(1).truncationMode(.tail)
                                }
                                Spacer(minLength: 4)
                                SimLive(sim: sim, pulse: pulse) { SimOpRate(sim: sim, ref: entry.ref) }
                            }
                        } else {
                            Text(secondLine)
                                .font(Theme.mono(10)).foregroundStyle(Theme.muted)
                                .lineLimit(1).truncationMode(.tail)
                        }
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
            ForEach(callers, id: \.ref) { caller in
                SimOpCallerRow(caller: caller, sim: sim, still: still, open: open, menu: menu, overlays: overlays)
            }
        }
    }

    private var secondLine: String { summary ?? SimOpsText.summary(entry, in: sim.level) }

    private func hover(_ ref: OpRef?, leaving: OpRef) {
        let state = SimOpsState.of(sim)
        if let ref { state.hovered = ref } else if state.hovered == leaving { state.hovered = nil }
    }
}

/// A caller under an endpoint: `↳ api-gateway · CreateOrder`.
@MainActor
private struct SimOpCallerRow: View {
    let caller: SimOpsIndex.Entry
    let sim: Simulation
    let still: Bool
    let open: (OpRef) -> Void
    let menu: (OpRef) -> [MenuItem]
    let overlays: Overlays
    @State private var hovered = false

    var body: some View {
        Button { open(caller.ref) } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right").font(Theme.ui(9, .medium)).foregroundStyle(Theme.faint)
                Text("\(caller.node.label) · \(caller.op.label)")
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
            if inside { state.hovered = caller.ref } else if state.hovered == caller.ref { state.hovered = nil }
        }
        .simOpsMenu(still: still) { overlays.showMenu(menu(caller.ref), at: $0) }
        .accessibilityLabel("Called by \(caller.node.label), \(caller.op.label)")
    }
}

/// `4.9/s · 31 ms`, or a dash when no flow step performs the op.
@MainActor
struct SimOpRate: View {
    let sim: Simulation
    let ref: OpRef

    var body: some View {
        let metrics = SimOpsMetrics.metrics(sim, ref)
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
