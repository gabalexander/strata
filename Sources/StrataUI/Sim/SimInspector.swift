import SwiftUI
import StrataCore

@MainActor
struct SimInspector: View {
    let model: AppModel
    let sim: Simulation
    let terms: TermIndex
    let actions: SimActions
    let selection: StageSelection?
    let select: (StageSelection?) -> Void
    var pulse: SimPulse?
    var still = false

    var body: some View {
        let notePreview = selectedNotePreview
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "sidebar.right").font(Theme.ui(12)).foregroundStyle(Theme.muted)
                Text("Inspector").font(Theme.ui(12, .semibold)).foregroundStyle(Theme.text)
                Spacer()
                if selection != nil {
                    SimButton(title: "Deselect", icon: "xmark", iconOnly: true) { select(nil) }
                }
            }
            .padding(.horizontal, 14).frame(height: 44)
            Rectangle().fill(Theme.border).frame(height: 1)
            // Selection changes rebuild this on the same frame; only the SimLive leaves inside tick.
            SimPanelScroll(still: still, resetOn: selection) {
                VStack(alignment: .leading, spacing: 16) {
                    switch selection {
                    case .node(let id):
                        if let node = sim.level.node(id) { nodePane(node, notePreview: notePreview) }
                    case .edge(let id):
                        if let edge = sim.diagramEdge(id) { edgePane(edge) }
                    case .flow(let id):
                        if let flow = sim.level.flow(id) { flowPane(flow) }
                    case nil:
                        overview
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .overlay { SimOpsDetailHost(model: model, sim: sim, terms: terms, actions: actions, selection: selection, select: select, pulse: pulse, still: still) }
        }
        .background(Theme.surface)
    }

    private func live<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
        SimLive(sim: sim, pulse: pulse, content: content)
    }

    private var overview: some View {
        Group {
            if let narration = sim.level.narration {
                SimSection(title: "This level") { SimMarkdown(source: narration, model: model, terms: terms) }
            }
            if !sim.level.flows.isEmpty {
                SimSection(title: "Flows") {
                    ForEach(sim.level.flows) { flow in flowCard(flow, selectable: true) }
                }
            }
            SimSection(title: "Diagram legend") {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                          alignment: .leading, spacing: 9) {
                    legend("Request", symbol: "circle.fill", color: Theme.info)
                    legend("Response", symbol: "circle", color: Theme.info)
                    legend("Message", symbol: "square.fill", color: Theme.token(2))
                    legend("Failure", symbol: "xmark", color: Theme.bad)
                    legend("Deep dive", symbol: "square.3.layers.3d", color: Theme.muted)
                    legend("Personal note", symbol: "note.text", color: Theme.muted)
                }
            }
        }
    }

    private func nodeState(_ node: Node) -> NodeState { sim.nodeState(node.id) ?? NodeState() }

    private func nodePane(_ node: Node, notePreview: String?) -> some View {
        Group {
            HStack(alignment: .top, spacing: 9) {
                glyph(node.icon ?? node.kind.symbol, tint: node.simTint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(node.label).font(Theme.heading).foregroundStyle(Theme.text)
                    Text([node.kind.rawValue, node.tech].compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    if let name = node.term, let term = terms.term(name) {
                        SimTermAnchor(term: term, model: model, index: terms) {
                            Label(term.term, systemImage: "text.book.closed")
                                .font(Theme.ui(11, .medium)).foregroundStyle(Theme.accent)
                        }
                        .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
                if node.kind != .note {
                    live {
                        let health = nodeState(node).health.presentation
                        SimPill(title: health.title, icon: health.icon, tint: health.tint)
                    }
                }
            }
            if let doc = node.doc { SimMarkdown(source: doc, model: model, terms: terms) }
            SimPressureInspectorRow(sim: sim, node: node)
            live {
                let items = actions.nodeActions(node, state: nodeState(node))
                if !items.isEmpty {
                    SimSection(title: "Actions") { SimActionButtons(items: items) }
                }
            }
            SimOpsSection(model: model, sim: sim, actions: actions, node: node, selection: selection, pulse: pulse, still: still)
            if node.kind != .note {
                SimSection(title: "Live metrics") { live { nodeMetrics(node, nodeState(node)) } }
                if node.kind.role == .buffer { live { bufferDetails(nodeState(node)) } }
            }
            if !node.code.isEmpty {
                SimSection(title: "Code") {
                    ForEach(node.code, id: \.self) { path in
                        SimButton(title: path, icon: "chevron.left.forwardslash.chevron.right") { actions.openCode(path) }
                    }
                }
            }
            if !node.links.isEmpty {
                SimSection(title: "Links") {
                    ForEach(node.links, id: \.self) { link in
                        SimButton(title: link.label, icon: "arrow.up.right") { actions.open(link) }
                    }
                }
            }
            if actions.supportsNotes { nodeNote(node, preview: notePreview) }
            if node.kind != .note { SimParameters(node: node, sim: sim, model: model) }
        }
    }

    private func nodeMetrics(_ node: Node, _ state: NodeState) -> some View {
        let capacity: (String, NodeMetric) = switch node.kind {
        case .queue: ("Depth", .depth)
        case .topic: ("Lag", .lag)
        default: ("Queued", .queued)
        }
        let metrics: [(String, NodeMetric, Color)] = [
            ("Throughput", .throughput, Theme.good), ("p99", .p99, Theme.info),
            ("In flight", .inflight, Theme.info), (capacity.0, capacity.1, Theme.warn),
            ("Errors", .errors, Theme.bad),
        ] + (node.kind == .topic ? [("Depth", .depth, Theme.token(2))] : [])
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)], spacing: 7) {
            ForEach(metrics, id: \.1) { name, metric, tint in
                let series = sim.series(.node(node.id, metric))
                let current = metric == .inflight ? series.last.map(SimFormat.number) ?? state.formatted(metric) : state.formatted(metric)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(Theme.small).foregroundStyle(Theme.muted)
                    Text(current).font(Theme.mono(13, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    SimSparkline(points: series, tint: tint).frame(height: 18)
                }
                .padding(8)
                .card()
            }
        }
    }

    private func bufferDetails(_ state: NodeState) -> some View {
        SimSection(title: "Buffer") {
            HStack(spacing: 10) {
                stat("Unacknowledged", String(state.unacked))
                stat("Lost", String(state.lost), tint: state.lost > 0 ? Theme.bad : Theme.text)
            }
            ForEach(state.groupLag.keys.sorted(), id: \.self) { group in
                HStack {
                    Text(sim.level.flow(group)?.label ?? group).font(Theme.ui(12)).foregroundStyle(Theme.muted)
                    Spacer()
                    Text("\(state.groupLag[group, default: 0]) behind").font(Theme.mono(11))
                }
            }
        }
    }

    private var selectedNotePreview: String? {
        guard case .node(let id) = selection, let node = sim.level.node(id),
              let lines = model.vault.indexedLines(at: actions.notePath(node)) else { return nil }
        return lines.lazy.filter {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return !line.isEmpty && !line.hasPrefix("#") && !line.hasPrefix("[[")
        }.prefix(3).joined(separator: " ")
    }

    private func nodeNote(_ node: Node, preview: String?) -> some View {
        let path = actions.notePath(node)
        return SimSection(title: "Your note") {
            if let preview {
                if !preview.isEmpty { SimMarkdown(source: preview, model: model, terms: terms, lineLimit: 3) }
                SimButton(title: "Open note", icon: "note.text") { model.open(.note(path)) }
            } else {
                SimButton(title: "Add a note", icon: "note.text.badge.plus") { actions.addNote(node) }
            }
        }
    }

    private func edgePane(_ edge: StrataCore.Edge) -> some View {
        Group {
            HStack(spacing: 9) {
                glyph("arrow.right", tint: Theme.info)
                Text(actions.edgeTitle(edge)).font(Theme.heading).foregroundStyle(Theme.text)
                Spacer(minLength: 0)
            }
            live { edgeDetails(edge) }
        }
    }

    private func edgeDetails(_ edge: StrataCore.Edge) -> some View {
        let state = sim.edgeState(edge.id) ?? EdgeState()
        let bind = BindTarget.edge(from: edge.from, to: edge.to)
        let latency = sim.value(StrataCore.Binding(bind, "latency"))?.number ?? edge.latency?.mean ?? 0.001
        let loss = sim.value(StrataCore.Binding(bind, "loss"))?.number ?? edge.loss ?? 0
        return Group {
            HStack(spacing: 6) {
                if let proto = edge.protocol { SimPill(title: proto) }
                if state.cut { SimPill(title: "Cut", icon: "scissors", tint: Theme.bad) }
                if state.breakerOpen { SimPill(title: "Breaker open", tint: Theme.warn) }
            }
            SimSection(title: "Link metrics") {
                HStack(spacing: 0) {
                    stat("Latency", SimFormat.latency(latency))
                    stat("Rate", "\(SimFormat.number(state.rate))/s")
                    stat("Loss", SimFormat.value(.number(loss), param: "loss"))
                }
                if state.extraLatency > 0 { Text("Added delay \(SimFormat.latency(state.extraLatency))").font(Theme.mono(11)).foregroundStyle(Theme.warn) }
            }
            SimSection(title: "Actions") {
                SimActionButtons(items: actions.edgeActions(edge, state: state))
            }
        }
    }

    private func flowPane(_ flow: Flow) -> some View {
        let source = flow.from ?? flow.on
        return Group {
            flowCard(flow, selectable: false)
            if let source, let node = sim.level.node(source) {
                SimSection(title: flow.isConsumer ? "Consumes from" : "Source") {
                    SimButton(title: node.label, icon: node.icon ?? node.kind.symbol) { select(.node(node.id)) }
                }
            }
            if let consumer = flow.by, let node = sim.level.node(consumer) {
                SimSection(title: "Consumer") {
                    SimButton(title: node.label, icon: node.icon ?? node.kind.symbol) { select(.node(node.id)) }
                }
            }
        }
    }

    /// Live: the rate follows parameter changes and the stats tick with the pulse.
    private func flowCard(_ flow: Flow, selectable: Bool) -> some View {
        live { flowCardContent(flow, selectable: selectable) }
    }

    private func flowCardContent(_ flow: Flow, selectable: Bool) -> some View {
        let metrics = sim.metrics(flow: flow.id)
        let binding = StrataCore.Binding(.flow(flow.id), "rate")
        let rate = sim.value(binding)?.number ?? metrics.configuredRate
        let maximum = max(20, flow.rate.perSecondValue.map { $0 * 2 } ?? 0,
                          sim.level.controls.compactMap { control -> Double? in
                              guard control.bind == binding, case .range(_, let max, _) = control.input else { return nil }
                              return max
                          }.max() ?? 0)
        let range = max(maximum, ceil(rate))
        let index = sim.level.flows.firstIndex { $0.id == flow.id } ?? 0
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Circle().fill(Theme.token(flow.color ?? index + 1)).frame(width: 7, height: 7)
                if selectable {
                    Button { select(.flow(flow.id)) } label: {
                        Text(flow.label).font(Theme.ui(12, .semibold)).foregroundStyle(Theme.text)
                    }.buttonStyle(.plain)
                } else {
                    Text(flow.label).font(Theme.ui(12, .semibold)).foregroundStyle(Theme.text)
                }
                Spacer(minLength: 0)
                if !flow.isConsumer {
                    SimButton(title: "Send 1", icon: "paperplane") { sim.send(flow.id) }
                }
            }
            if !flow.isConsumer {
                HStack(spacing: 9) {
                    SimSlider(title: "Rate for \(flow.label)",
                              value: SwiftUI.Binding(get: { sim.value(binding)?.number ?? rate },
                                                     set: { sim.setValue(.number($0), for: binding) }),
                              range: 0...range, step: range > 100 ? 1 : 0.5)
                    Text("\(SimFormat.number(rate))/s").font(Theme.mono(10)).foregroundStyle(Theme.muted)
                        .frame(minWidth: 42, alignment: .trailing)
                }
            }
            HStack(spacing: 6) {
                stat("OK/s", SimFormat.number(metrics.ok), tint: Theme.good)
                stat("Err/s", SimFormat.number(metrics.failed), tint: metrics.failed > 0 ? Theme.bad : Theme.muted)
                stat("p50", SimFormat.latency(metrics.p50))
                stat("p99", SimFormat.latency(metrics.p99))
            }
        }
        .padding(9)
        .card()
    }

    private func stat(_ name: String, _ value: String, tint: Color = Theme.text) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(Theme.small).foregroundStyle(Theme.muted)
            Text(value).font(Theme.mono(11, .medium)).foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func glyph(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(Theme.ui(15, .semibold)).foregroundStyle(tint).frame(width: 34, height: 34)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
    }

    private func legend(_ label: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).frame(width: 13).foregroundStyle(color)
            Text(label).foregroundStyle(Theme.muted)
        }
        .font(Theme.small)
    }
}

extension NodeState {
    func formatted(_ metric: NodeMetric) -> String {
        switch metric {
        case .inflight: String(busy)
        case .queued: String(queued)
        case .util: "\(SimFormat.number(utilization * 100))%"
        case .throughput: "\(SimFormat.number(throughput))/s"
        case .errors: "\(SimFormat.number(errors))/s"
        case .p50: SimFormat.latency(p50)
        case .p99: SimFormat.latency(p99)
        case .depth: String(depth)
        case .lag: String(groupLag.values.reduce(0, +))
        }
    }
}
