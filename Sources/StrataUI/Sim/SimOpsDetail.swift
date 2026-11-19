import AppKit
import SwiftUI
import StrataCore

/// Laid over the inspector's content: draws nothing until an op detail is open for the current
/// selection, then replaces it. The content underneath keeps its scroll position for Back. Selecting
/// anything else closes the detail (`SimOpsState.selectionChanged`, called by the workspace).
@MainActor
struct SimOpsDetailHost: View {
    let model: AppModel
    let sim: Simulation
    let terms: TermIndex
    let actions: SimActions
    let selection: StageSelection?
    let select: (StageSelection?) -> Void
    var pulse: SimPulse?
    var still = false

    var body: some View {
        let state = SimOpsState.of(sim)
        if let detail = state.detail(for: selection), let entry = state.index.entry(detail.current) {
            SimOpDetail(model: model, sim: sim, terms: terms, actions: actions, entry: entry, detail: detail,
                        select: select, pulse: pulse, still: still)
                .background(Theme.surface)
        }
    }
}

/// The focused view of one operation.
@MainActor
struct SimOpDetail: View {
    let model: AppModel
    let sim: Simulation
    let terms: TermIndex
    let actions: SimActions
    let entry: SimOpsIndex.Entry
    let detail: SimOpsState.Detail
    let select: (StageSelection?) -> Void
    var pulse: SimPulse?
    var still = false

    private var state: SimOpsState { SimOpsState.of(sim) }
    private var index: SimOpsIndex { state.index }
    private var op: StrataCore.Operation { entry.op }

    var body: some View {
        SimPanelScroll(still: still, resetOn: detail.current) {
            VStack(alignment: .leading, spacing: 16) {
                backBar
                header
                toolbar
                if let doc = op.doc { SimMarkdown(source: doc, model: model, terms: terms) }
                live
                kindBody.simEnumTables(op, on: entry.node.id, level: sim.level)
                if let formula = op.formula { SimFormulaSection(formula: formula, model: model, terms: terms, actions: actions) }
                if !op.how.isEmpty {
                    SimHowSection(mechanisms: op.how, node: entry.node.id, op: op.id, owner: op.label, model: model, sim: sim,
                                  terms: terms, actions: actions)
                }
                if !op.risks.isEmpty { risks }
                if !op.facts.isEmpty { SimSection(title: "Facts") { SimOpsTable(rows: op.facts.map { ($0.key, $0.value) }) } }
                if !op.code.isEmpty {
                    SimSection(title: "Code") {
                        ForEach(op.code, id: \.self) { path in
                            SimButton(title: path, icon: "chevron.left.forwardslash.chevron.right") { actions.openCode(path) }
                        }
                    }
                }
                links("Called by", index.callers(of: entry.ref))
                links("Reaches", index.reaches(entry.ref))
                flows
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }

    // MARK: Header

    private var backBar: some View {
        let previous = detail.trail.count > 1 ? index.entry(detail.trail[detail.trail.count - 2]) : nil
        let title = previous.map(SimOpsText.title) ?? anchorTitle
        return HStack(spacing: 6) {
            SimOpsBackButton(title: title) { state.back() }
            Spacer(minLength: 0)
            Text("Esc").font(Theme.mono(10)).foregroundStyle(Theme.faint)
        }
    }

    private var anchorTitle: String {
        switch detail.anchor {
        case .node(let id): sim.level.node(id)?.label ?? id
        case .flow(let id): sim.level.flow(id)?.label ?? id
        case .edge(let id): sim.diagramEdge(id).map(actions.edgeTitle) ?? id
        case nil: "Overview"
        }
    }

    private var header: some View {
        let tintNode = op.direction == .outbound ? entry.peer.flatMap(sim.level.node) ?? entry.node : entry.node
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: op.kind.symbol)
                .font(Theme.ui(14, .semibold)).foregroundStyle(tintNode.simTint).frame(width: 34, height: 34)
                .background(tintNode.simTint.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
            VStack(alignment: .leading, spacing: 5) {
                Text(op.label).font(Theme.heading).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    Text(SimOpsText.kindName(op.kind)).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    if let access = SimOpsText.access(op) {
                        SimOpAccessBadge(access: access)
                        Text(SimOpsText.accessName(access)).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    }
                    if let streaming = op.streaming {
                        Text("· \(streaming)").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    }
                }
                direction
            }
            Spacer(minLength: 0)
        }
        .simOpsMenu(still: still) {
            model.overlays.showMenu(SimOpsMenus.row(entry, sim: sim, model: model, anchor: detail.anchor, includeOpen: false),
                                    at: $0)
        }
    }

    /// `orders-svc calls → orders db`, `served by orders-svc`; node names select the node.
    private var direction: some View {
        let peer = entry.peer.flatMap(sim.level.node)
        let verb: String = switch op.kind {
        case .publish: "publishes"
        case .consume: "consumes"
        default: op.direction == .inbound ? "served by" : "calls"
        }
        return HStack(spacing: 4) {
            if op.direction == .inbound && op.kind != .consume {
                Text(verb).foregroundStyle(Theme.muted)
                SimOpsNodeLink(title: entry.node.label) { select(.node(entry.node.id)) }
            } else {
                SimOpsNodeLink(title: entry.node.label) { select(.node(entry.node.id)) }
                Text(verb).foregroundStyle(Theme.muted)
                if let peer {
                    Image(systemName: op.kind == .consume ? "arrow.left" : "arrow.right")
                        .font(Theme.ui(9, .semibold)).foregroundStyle(Theme.faint)
                    SimOpsNodeLink(title: peer.label) { select(.node(peer.id)) }
                } else if let name = op.target ?? op.topic {
                    Text(name).foregroundStyle(Theme.text)
                }
            }
        }
        .font(Theme.ui(12))
        .lineLimit(1)
    }

    private var toolbar: some View {
        let pinned = state.isPinned(entry.ref, at: detail.anchor)
        return HStack(spacing: 6) {
            if let node = SimOpsPath.diveNode(entry) {
                SimButton(title: "Deep dive", icon: "square.3.layers.3d") { actions.dive(node) }
            }
            if let copy = SimOpsText.copyable(op) {
                SimButton(title: copy.title, icon: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copy.text, forType: .string)
                    model.overlays.toast(copy.title.replacingOccurrences(of: "Copy", with: "Copied"))
                }
            }
            SimButton(title: pinned ? "Unpin path" : "Pin path", icon: pinned ? "pin.slash" : "pin", active: pinned) {
                state.togglePin(entry.ref, at: detail.anchor)
            }
        }
    }

    // MARK: Live

    private var live: some View {
        SimLive(sim: sim, pulse: pulse) {
            let metrics = sim.opMetrics(node: entry.node.id, op: entry.op.id)
            if metrics.referenced {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        stat("Rate", "\(SimFormat.number(metrics.rate))/s", tint: Theme.text)
                        stat("Errors", "\(SimFormat.number(metrics.errors))/s", tint: metrics.errors > 0 ? Theme.bad : Theme.muted)
                        stat("p50", SimFormat.latency(metrics.p50))
                        stat("p99", SimFormat.latency(metrics.p99))
                    }
                    SimSparkline(points: sim.opSeries(node: entry.node.id, op: entry.op.id, metric: "rate"), tint: Theme.good).frame(height: 22)
                }
                .padding(9)
                .card()
            } else {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "waveform.path").font(Theme.ui(11)).foregroundStyle(Theme.faint)
                    Text("No flow step performs this op, so it has no live numbers. It still documents the code.")
                        .font(Theme.small).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func stat(_ name: String, _ value: String, tint: Color = Theme.text) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(Theme.small).foregroundStyle(Theme.muted)
            Text(value).font(Theme.mono(11, .medium)).foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Kind

    @ViewBuilder
    private var kindBody: some View {
        switch op.kind {
        case .sql, .search: query
        case .cache: cache
        case .publish, .consume: message
        case .rpc, .http, .call, .storage, .llm: endpoint
        }
    }

    @ViewBuilder
    private var query: some View {
        if let query = op.query.map(SimOpsCode.trimmed) {
            SimOpsCodeBlock(title: op.kind == .search ? "Query" : "SQL",
                            text: op.kind == .sql ? SimOpsCode.sql(query) : SimOpsCode.message(query).text,
                            raw: query, copyTitle: "Copy query", overlays: model.overlays, still: still)
        }
        let touches = !op.tables.isEmpty || !op.indexes.isEmpty || op.tx != nil || op.locks != nil
        if touches {
            SimSection(title: "Touches") {
                SimOpsChips {
                    ForEach(op.tables, id: \.self) { SimDataTableChip(model: model, sim: sim, node: entry.peer, table: $0, select: select) }
                    ForEach(op.indexes, id: \.self) { SimOpsChip(title: $0, symbol: "list.number", mono: true, tint: Theme.muted) }
                    if let tx = op.tx { SimOpsChip(title: tx ? "transaction" : "no transaction", symbol: "arrow.triangle.2.circlepath", tint: tx ? Theme.info : Theme.muted) }
                    if let locks = op.locks { SimOpsChip(title: "\(locks) locks", symbol: "lock", tint: Theme.warn) }
                }
            }
        }
    }

    private var cache: some View {
        SimSection(title: "Command") {
            SimOpsTable(rows: [
                ("command", op.command), ("key", op.key), ("ttl", op.ttl.map(SimOpsText.duration)),
                ("store", entry.peer.flatMap(sim.level.node)?.label),
            ].compactMap { row in row.1.map { (row.0, $0) } }, monoValues: true)
        }
    }

    @ViewBuilder
    private var message: some View {
        let rows = [("topic", op.topic ?? entry.peer.flatMap(sim.level.node)?.label), ("key", op.key),
                    ("group", op.group)].compactMap { row in row.1.map { (row.0, $0) } }
        if !rows.isEmpty { SimSection(title: "Message") { SimOpsTable(rows: rows, monoValues: true) } }
        if let payload = op.payload { block("Payload", payload, copy: "Copy payload") }
    }

    @ViewBuilder
    private var endpoint: some View {
        let line = [op.method, op.path].compactMap { $0 }.joined(separator: " ")
        if !line.isEmpty, line != op.label {
            SimSection(title: op.kind == .rpc ? "Method" : "Request line") {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    if let method = op.method, op.kind != .rpc || op.path != nil {
                        Text(method).font(Theme.mono(10, .semibold)).foregroundStyle(Theme.info)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Theme.info.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    }
                    Text(op.kind == .rpc && op.path == nil ? op.method ?? "" : op.path ?? "")
                        .font(Theme.mono(11)).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        if let request = op.request { block("Request", request, copy: "Copy request") }
        if let response = op.response { block("Response", response, copy: "Copy response") }
        if !op.status.isEmpty {
            SimSection(title: "Status") {
                SimOpsChips {
                    ForEach(op.status, id: \.self) { status in
                        SimOpsChip(title: status, mono: false, tint: statusTint(status))
                    }
                }
            }
        }
    }

    private func block(_ title: String, _ source: String, copy: String) -> some View {
        let text = SimOpsCode.trimmed(source)
        let formatted = SimOpsCode.message(text)
        return SimOpsCodeBlock(title: title, text: formatted.text, raw: SimOpsCode.json(text) ?? text, copyTitle: copy,
                               overlays: model.overlays, caption: formatted.isJSON ? "json" : nil, still: still)
    }

    private func statusTint(_ status: String) -> Color {
        let code = SimOpsText.statusCode(status).uppercased()
        if let first = code.first, code.count == 3, code.allSatisfy(\.isNumber) {
            switch first {
            case "1", "2", "3": return Theme.good
            case "4": return Theme.warn
            default: return Theme.bad
            }
        }
        if code == "OK" { return Theme.good }
        if ["UNAVAILABLE", "INTERNAL", "DEADLINE_EXCEEDED", "UNKNOWN", "DATA_LOSS"].contains(code) { return Theme.bad }
        return Theme.warn
    }

    // MARK: Risks, links, flows

    private var risks: some View {
        SimSection(title: "Risks") {
            ForEach(op.risks, id: \.self) { risk in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").font(Theme.ui(10)).foregroundStyle(Theme.warn)
                    Text(risk).font(Theme.ui(12)).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(Theme.warn.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(Theme.warn.opacity(0.16)))
            }
        }
    }

    @ViewBuilder
    private func links(_ title: String, _ refs: [OpRef]) -> some View {
        let entries = refs.compactMap(index.entry)
        if !entries.isEmpty {
            SimSection(title: title) {
                SimOpsGroupBox(title: "") {
                    ForEach(Array(entries.enumerated()), id: \.element.ref) { offset, link in
                        if offset > 0 { SimOpsHairline() }
                        // A link from another node already talks to this op's node: leave the peer out.
                        SimOpRow(sim: sim, entry: link, owner: link.node.id != entry.node.id,
                                 summary: link.peer == entry.node.id ? SimOpsText.reverseSummary(link) : nil,
                                 pulse: pulse, still: still,
                                 open: { state.push($0) },
                                 menu: { SimOpsMenus.row(index.entry($0) ?? link, sim: sim, model: model, anchor: detail.anchor) },
                                 overlays: model.overlays)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var flows: some View {
        let ids = index.flows[entry.ref] ?? []
        let flows = ids.compactMap(sim.level.flow)
        if !flows.isEmpty {
            SimSection(title: "Flows") {
                SimOpsChips {
                    ForEach(flows) { flow in
                        let order = sim.level.flows.firstIndex { $0.id == flow.id } ?? 0
                        SimOpsFlowChip(title: flow.label, color: Theme.token(flow.color ?? order + 1)) { select(.flow(flow.id)) }
                    }
                }
            }
        }
    }
}

// MARK: - Small parts

@MainActor
private struct SimOpsBackButton: View {
    let title: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left").font(Theme.ui(10, .semibold))
                Text(title).font(Theme.ui(12, .medium)).lineLimit(1).truncationMode(.tail)
            }
            .foregroundStyle(hovered ? Theme.text : Theme.muted)
            .padding(.horizontal, 7).frame(height: 24)
            .background(hovered ? Theme.hover : Theme.raised, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("Back to \(title)")
    }
}

/// A node name that selects the node.
@MainActor
private struct SimOpsNodeLink: View {
    let title: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title).font(Theme.ui(12, .medium))
                .foregroundStyle(hovered ? Theme.accent : Theme.text)
                .underline(hovered, color: Theme.accent.opacity(0.6))
                .lineLimit(1).truncationMode(.tail)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityHint("Selects this node")
    }
}

@MainActor
private struct SimOpsFlowChip: View {
    let title: String
    let color: Color
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).font(Theme.ui(11, .medium)).foregroundStyle(hovered ? Theme.text : Theme.muted).lineLimit(1)
            }
            .padding(.horizontal, 8).frame(height: 24)
            .background(hovered ? Theme.hover : Theme.raised, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityHint("Selects this flow")
    }
}

struct SimOpsChip: View {
    let title: String
    var symbol: String?
    var mono = false
    var tint: Color = Theme.token(3)

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(Theme.ui(9, .medium)) }
            Text(title).font(mono ? Theme.mono(10.5) : Theme.ui(11, .medium)).lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(tint.opacity(0.18)))
    }
}

/// Key–value rows on a card, hairlines between.
struct SimOpsTable: View {
    let rows: [(String, String)]
    var monoValues = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { offset, row in
                if offset > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(row.0).font(Theme.ui(11)).foregroundStyle(Theme.muted)
                        .frame(width: 84, alignment: .leading).lineLimit(1)
                    Text(row.1).font(monoValues ? Theme.mono(11) : Theme.ui(12)).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
            }
        }
        .card(radius: 8)
    }
}

/// Chips that wrap onto as many lines as they need.
struct SimOpsChips<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { SimOpsFlowLayout(spacing: 5) { content } }
}

private struct SimOpsFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, arrange(bounds.width, subviews).frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, used: CGFloat = 0
        var frames: [CGRect] = []
        for view in subviews {
            var size = view.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if x > 0, x + size.width > width {
                x = 0
                y += line + spacing
                line = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            used = max(used, x - spacing)
            line = max(line, size.height)
        }
        return (CGSize(width: used, height: y + line), frames)
    }
}
