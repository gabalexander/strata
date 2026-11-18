import SwiftUI
import StrataCore

// The Pressure tab's denser sections: pressure on data stores, volumes and capacity. Numbers are
// right-aligned mono in fixed columns so rows line up.

// MARK: - Pressure on data stores

@MainActor
struct SimPressureStores: View {
    let sim: Simulation
    let model: AppModel
    let select: (StageSelection?) -> Void

    static let kinds: Set<NodeKind> = [.database, .cache, .search, .store, .vector]

    /// Databases, caches and search nodes with load, busiest first.
    static func stores(_ report: CapacityReport, level: Level) -> [String] {
        let utilization = Dictionary(report.nodes.map { ($0.node, $0.utilization) }, uniquingKeysWith: { first, _ in first })
        return report.pressure.keys
            .filter { id in level.node(id).map { kinds.contains($0.kind) } ?? false }
            .filter { !(report.pressure[$0] ?? []).isEmpty }
            .sorted { (utilization[$0] ?? 0, $1) > (utilization[$1] ?? 0, $0) }
    }

    var body: some View {
        let analysis = SimPressureState.of(sim).analysis(sim)
        let stores = Self.stores(analysis.report, level: sim.level)
        VStack(alignment: .leading, spacing: 9) {
            SimPressureHeader(title: "Pressure on data stores", caption: "share of busy time (rate × hold) by op and caller") {
                HStack(spacing: 10) {
                    swatch(.read, "read")
                    swatch(.write, "write")
                    swatch(.readWrite, "read-write")
                }
            }
            if stores.isEmpty {
                SimPressureEmpty(message: "No database or cache load at this level", icon: "cylinder.split.1x2")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 560), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(stores, id: \.self) { id in
                        SimPressureStoreCard(sim: sim, model: model, store: id, capacity: analysis.nodes[id],
                                             sources: analysis.report.pressure[id] ?? [], select: select)
                    }
                }
            }
        }
    }

    private func swatch(_ access: OpAccess, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(SimPressureStyle.access(access)).frame(width: 8, height: 8)
            Text(label).font(Theme.small).foregroundStyle(Theme.muted)
        }
    }
}

@MainActor
private struct SimPressureStoreCard: View {
    let sim: Simulation
    let model: AppModel
    let store: String
    let capacity: NodeCapacity?
    let sources: [LoadSource]
    let select: (StageSelection?) -> Void
    @State private var hovered: String?

    private struct Group: Identifiable {
        let id: String
        let sources: [LoadSource]
    }

    private var index: SimOpsIndex { SimOpsState.of(sim).index }

    private func ref(_ source: LoadSource) -> OpRef? { source.op.map { OpRef(node: source.node, op: $0) } }

    private func access(_ source: LoadSource) -> OpAccess? {
        source.access ?? ref(source).flatMap(index.entry).flatMap { SimOpsText.access($0.op) }
    }

    /// Sources by table, biggest table first; within a table, biggest share first.
    private var groups: [Group] {
        let keyed = Dictionary(grouping: sources) { $0.tables.joined(separator: ", ") }
        return keyed.map { Group(id: $0.key, sources: $0.value.sorted { $0.busyShare > $1.busyShare }) }
            .sorted { a, b in
                let (x, y) = (a.sources.reduce(0) { $0 + $1.busyShare }, b.sources.reduce(0) { $0 + $1.busyShare })
                return x == y ? a.id < b.id : x > y
            }
    }

    /// Each source's colour: its access colour, stepping down in strength for each further source
    /// of the same access so neighbouring segments stay apart.
    private func colors(_ ordered: [LoadSource]) -> [String: Color] {
        var seen: [String: Int] = [:]
        var result: [String: Color] = [:]
        for source in ordered {
            let key = access(source).map(\.rawValue) ?? "-"
            let step = seen[key, default: 0]
            seen[key] = step + 1
            result[source.id] = SimPressureStyle.access(access(source)).opacity([0.95, 0.68, 0.48, 0.34][min(step, 3)])
        }
        return result
    }

    var body: some View {
        let node = sim.level.node(store)
        let groups = groups
        let ordered = groups.flatMap(\.sources)
        let colors = colors(ordered)
        VStack(alignment: .leading, spacing: 8) {
            header(node)
            bar(ordered, colors: colors).frame(height: 10)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(groups) { group in
                    if !group.id.isEmpty || groups.count > 1 {
                        HStack(spacing: 5) {
                            Image(systemName: "tablecells").font(Theme.ui(9, .medium)).foregroundStyle(Theme.faint)
                            Text(group.id.isEmpty ? "no table named" : group.id).font(Theme.mono(10.5, .medium))
                                .foregroundStyle(Theme.text.opacity(0.78)).lineLimit(1)
                        }
                        .padding(.top, 4).padding(.leading, 4)
                    }
                    ForEach(group.sources) { source in row(source, color: colors[source.id] ?? Theme.muted) }
                }
            }
        }
        .padding(12)
        .card(radius: 8)
    }

    private func header(_ node: Node?) -> some View {
        let tint = node?.simTint ?? Theme.muted
        return HStack(spacing: 8) {
            Image(systemName: node?.icon ?? node?.kind.symbol ?? "cylinder.split.1x2")
                .font(Theme.ui(11, .semibold)).foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
            Button { select(.node(store)) } label: {
                Text(node?.label ?? store).font(Theme.ui(12, .semibold)).foregroundStyle(Theme.text)
            }
            .buttonStyle(.plain)
            if let tech = node?.tech { Text(tech).font(Theme.mono(10)).foregroundStyle(Theme.muted) }
            Spacer(minLength: 8)
            if let capacity, let slots = capacity.slots, let node {
                if slots == 0 {
                    Text("down").font(Theme.mono(11, .medium)).foregroundStyle(Theme.bad)
                } else {
                    Text(SimPressureFormat.percent(capacity.utilization)).font(Theme.mono(11, .medium))
                        .foregroundStyle(SimPressureStyle.calm(capacity.utilization))
                    ViewThatFits(in: .horizontal) {
                        Text("busy · \(SimPressureFormat.slots(slots, kind: node.kind)) · \(SimPressureFormat.latency(capacity.holdTime)) hold")
                        Text("busy · \(SimPressureFormat.slots(slots, kind: node.kind))")
                        Text("busy")
                    }
                    .font(Theme.small).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
        }
    }

    private func bar(_ ordered: [LoadSource], colors: [String: Color]) -> some View {
        Canvas { context, size in
            let total = max(1, ordered.reduce(0) { $0 + $1.busyShare })
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3), with: .color(Theme.selected))
            var x: CGFloat = 0
            var clip = context
            clip.clip(to: Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3))
            for source in ordered {
                let width = size.width * CGFloat(source.busyShare / total)
                guard width > 0.5 else { continue }
                let rect = CGRect(x: x, y: 0, width: max(1, width - 1.5), height: size.height)
                let color = colors[source.id] ?? Theme.muted
                clip.fill(Path(rect), with: .color(color))
                if hovered == source.id {
                    clip.stroke(Path(rect.insetBy(dx: 0.75, dy: 0.75)), with: .color(Theme.text.opacity(0.85)), lineWidth: 1.5)
                }
                x += width
            }
        }
        .accessibilityHidden(true)
    }

    private func row(_ source: LoadSource, color: Color) -> some View {
        let ref = ref(source)
        let entry = ref.flatMap(index.entry)
        // No op: a consumer flow's deliveries (the caller is the buffer), or a step that names none.
        let delivery = sim.level.node(source.node)?.kind.role == .buffer
        let title = entry?.op.label ?? "\(sim.level.flow(source.flow)?.label ?? source.flow) \(delivery ? "deliveries" : "calls")"
        return SimPressureRowButton {
            select(.node(store))
            if let ref { SimOpsMenus.open(ref, sim: sim, model: model, anchor: .node(store)) }
        } content: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
                if let access = access(source) { SimOpAccessBadge(access: access) }
                // Wraps rather than truncates when the card is narrow.
                Text("\(Text(title).font(Theme.ui(12)).foregroundStyle(Theme.text))  \(Text(sim.pressureLabel(source.node)).font(Theme.ui(11)).foregroundStyle(Theme.muted))")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(SimPressureFormat.rate(source.rate)).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    .monospacedDigit().frame(width: 58, alignment: .trailing)
                Text(SimPressureFormat.perDay(source.daily > 0 ? source.daily : source.rate * 86_400))
                    .font(Theme.mono(11)).foregroundStyle(Theme.faint)
                    .monospacedDigit().lineLimit(1).frame(width: 84, alignment: .trailing)
                Text(SimPressureFormat.percent(source.busyShare)).font(Theme.mono(11, .medium)).foregroundStyle(Theme.text)
                    .monospacedDigit().frame(width: 40, alignment: .trailing)
            }
            .padding(.horizontal, 4).padding(.vertical, 3)
        }
        .onHover { inside in
            hovered = inside ? source.id : hovered == source.id ? nil : hovered
            let ops = SimOpsState.of(sim)
            if inside, let ref { ops.hovered = ref } else if ops.hovered == ref { ops.hovered = nil }
        }
        .accessibilityLabel("\(title), \(sim.pressureLabel(source.node)), \(SimPressureFormat.percent(source.busyShare)) of busy time")
        .accessibilityHint(ref == nil ? "Selects the database" : "Opens the operation")
    }
}

// MARK: - Volumes

@MainActor
struct SimPressureVolumes: View {
    let sim: Simulation
    var pulse: SimPulse?
    let select: (StageSelection?) -> Void

    private static let columns: [(String, CGFloat)] = [
        ("sim /s", 62), ("sim /day", 70), ("peak", 62), ("declared /day", 88), ("SLO p99", 62), ("live p99", 62),
    ]

    var body: some View {
        let analysis = SimPressureState.of(sim).analysis(sim)
        VStack(alignment: .leading, spacing: 9) {
            SimPressureHeader(title: "Volumes", caption: "simulated calls beside the declared traffic and SLOs")
            if sim.level.flows.isEmpty {
                SimPressureEmpty(message: "No flows at this level", icon: "chart.bar")
            } else {
                VStack(spacing: 0) {
                    headerRow
                    SimPressureHairline()
                    SimLive(sim: sim, pulse: pulse) {
                        VStack(spacing: 0) {
                            ForEach(Array(sim.level.flows.enumerated()), id: \.element.id) { offset, flow in
                                if offset > 0 { SimPressureHairline() }
                                flowRows(flow, analysis: analysis)
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .card(radius: 8)
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Text("flow and its ops").frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Self.columns, id: \.0) { title, width in
                Text(title).frame(width: width, alignment: .trailing)
            }
            Color.clear.frame(width: 10)
        }
        .font(Theme.small).foregroundStyle(Theme.faint).lineLimit(1)
        .padding(.horizontal, 12).frame(height: 24)
    }

    @ViewBuilder
    private func flowRows(_ flow: Flow, analysis: SimPressureState.Analysis) -> some View {
        let capacity = analysis.report.flows.first { $0.flow == flow.id }
        let metrics = sim.metrics(flow: flow.id)
        let rate = capacity?.rate ?? (flow.isConsumer ? metrics.started : metrics.configuredRate)
        let declared = capacity?.declared ?? flow.traffic
        let slo = capacity?.slo ?? flow.slo
        VStack(spacing: 0) {
            SimPressureRowButton { select(.flow(flow.id)) } content: {
                HStack(spacing: 10) {
                    HStack(spacing: 7) {
                        Circle().fill(sim.pressureFlowColor(flow.id)).frame(width: 7, height: 7)
                        Text(flow.label).font(Theme.ui(12, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    numbers([SimPressureFormat.rate(rate), SimPressureFormat.count(rate * 86_400),
                             declared?.peak.map(SimPressureFormat.rate) ?? "—", declared?.daily.map(SimPressureFormat.count) ?? "—",
                             slo?.p99.map(SimPressureFormat.latency) ?? "—", SimPressureFormat.latency(metrics.p99)],
                            tint: Theme.text, peakTint: peakTint(declared?.peak, capacity?.maxRate))
                    status(live: metrics.p99, slo: slo?.p99)
                }
                .padding(.horizontal, 12).frame(height: 28)
            }
            ForEach(ops(of: flow), id: \.ref) { entry in
                let op = sim.opMetrics(node: entry.node.id, op: entry.op.id)
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: entry.op.kind.symbol).font(Theme.ui(10)).foregroundStyle(Theme.faint).frame(width: 14)
                        Text(entry.node.label).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
                        Text(entry.op.label).font(Theme.ui(11.5)).foregroundStyle(Theme.text.opacity(0.86)).lineLimit(1)
                    }
                    .padding(.leading, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    numbers([SimPressureFormat.rate(op.rate), SimPressureFormat.count(op.rate * 86_400), "", "", "",
                             SimPressureFormat.latency(op.p99)], tint: Theme.muted, peakTint: Theme.muted)
                    Color.clear.frame(width: 10)
                }
                .padding(.horizontal, 12).frame(height: 22)
            }
        }
        .padding(.bottom, ops(of: flow).isEmpty ? 0 : 4)
    }

    private func numbers(_ values: [String], tint: Color, peakTint: Color) -> some View {
        ForEach(Array(zip(values, Self.columns).enumerated()), id: \.offset) { offset, pair in
            Text(pair.0).font(Theme.mono(11, offset == 0 ? .medium : .regular))
                .foregroundStyle(offset == 2 ? peakTint : pair.0 == "—" ? Theme.faint : tint)
                .monospacedDigit().lineLimit(1)
                .frame(width: pair.1.1, alignment: .trailing)
        }
    }

    private func peakTint(_ peak: Double?, _ maxRate: Double?) -> Color {
        guard let peak else { return Theme.faint }
        return maxRate.map { peak > $0 } == true ? Theme.bad : Theme.text
    }

    private func status(live: Double?, slo: Double?) -> some View {
        Group {
            if let slo {
                let tint = live.map { $0 > slo ? Theme.bad : $0 > slo * 0.8 ? Theme.warn : Theme.good } ?? Theme.faint
                Circle().fill(tint).frame(width: 7, height: 7)
                    .accessibilityLabel(live.map { $0 > slo ? "over SLO" : "within SLO" } ?? "no data")
            } else {
                Color.clear
            }
        }
        .frame(width: 10)
    }

    /// The ops a flow performs, in level order, that the simulation counts.
    private func ops(of flow: Flow) -> [SimOpsIndex.Entry] {
        let index = SimOpsState.of(sim).index
        return index.all.filter { index.flows[$0.ref]?.contains(flow.id) == true }
    }
}

// MARK: - Capacity

@MainActor
struct SimPressureCapacity: View {
    let sim: Simulation
    let select: (StageSelection?) -> Void

    private static let columns: [(String, CGFloat)] = [("slots", 56), ("hold", 64), ("demand", 64), ("util", 48)]

    var body: some View {
        let analysis = SimPressureState.of(sim).analysis(sim)
        let nodes = analysis.report.nodes.filter { $0.slots != nil } + analysis.report.nodes.filter { $0.slots == nil }
        VStack(alignment: .leading, spacing: 9) {
            SimPressureHeader(title: "Capacity", caption: "slots = concurrency × replicas · demand = rate × visits × hold, in busy slots")
            if nodes.isEmpty {
                SimPressureEmpty(message: "No capacity analysis for this level yet", icon: "rectangle.stack")
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Text("node, busiest first").frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(Self.columns, id: \.0) { title, width in Text(title).frame(width: width, alignment: .trailing) }
                        Text("headroom").frame(width: 110, alignment: .leading)
                    }
                    .font(Theme.small).foregroundStyle(Theme.faint).lineLimit(1)
                    .padding(.horizontal, 12).frame(height: 24)
                    SimPressureHairline()
                    ForEach(nodes) { capacity in row(capacity, bottleneck: analysis.bottleneckFor[capacity.node] ?? []) }
                }
                .padding(.bottom, 3)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .card(radius: 8)
            }
        }
    }

    private func row(_ capacity: NodeCapacity, bottleneck: [FlowCapacity]) -> some View {
        let node = sim.level.node(capacity.node)
        let limited = capacity.slots != nil
        let down = capacity.slots == 0
        let util = capacity.utilization
        return SimPressureRowButton { select(.node(capacity.node)) } content: {
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: node?.icon ?? node?.kind.symbol ?? "circle").font(Theme.ui(10, .medium))
                        .foregroundStyle(node?.simTint ?? Theme.muted).frame(width: 14)
                    Text(node?.label ?? capacity.node).font(Theme.ui(12)).foregroundStyle(limited ? Theme.text : Theme.muted)
                        .lineLimit(1)
                    if !bottleneck.isEmpty {
                        Text("bottleneck").font(Theme.ui(10, .medium)).foregroundStyle(Theme.warn)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Theme.warn.opacity(0.10), in: Capsule())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                cell(capacity.slots.map(String.init) ?? "∞", width: 56, tint: down ? Theme.bad : limited ? Theme.text : Theme.faint)
                cell(capacity.holdTime > 0 ? SimPressureFormat.latency(capacity.holdTime) : "—", width: 64,
                     tint: capacity.holdTime > 0 ? Theme.muted : Theme.faint)
                cell(capacity.demand > 0 || limited ? SimFormat.number(capacity.demand) : "—", width: 64,
                     tint: capacity.demand > 0 || limited ? Theme.muted : Theme.faint)
                cell(down ? "down" : limited ? SimPressureFormat.percent(util) : "—", width: 48,
                     tint: down ? Theme.bad : limited ? SimPressureStyle.calm(util) : Theme.faint, weight: .medium)
                headroom(limited && !down ? util : nil, down: down).frame(width: 110, alignment: .leading)
            }
            .padding(.horizontal, 12).frame(height: 24)
        }
    }

    private func cell(_ value: String, width: CGFloat, tint: Color, weight: Font.Weight = .regular) -> some View {
        Text(value).font(Theme.mono(11, weight)).foregroundStyle(tint).monospacedDigit().lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }

    @ViewBuilder
    private func headroom(_ util: Double?, down: Bool) -> some View {
        if let util {
            HStack(spacing: 6) {
                Canvas { context, size in
                    let track = CGRect(x: 0, y: (size.height - 4) / 2, width: size.width, height: 4)
                    context.fill(Path(roundedRect: track, cornerRadius: 2), with: .color(Theme.selected))
                    let used = CGRect(x: 0, y: track.minY, width: size.width * CGFloat(min(1, max(0, util))), height: 4)
                    context.fill(Path(roundedRect: used, cornerRadius: 2), with: .color(SimPressureStyle.heat(util).opacity(0.85)))
                }
                .frame(width: 64, height: 8)
                Text(util > 1 ? "over" : SimPressureFormat.percent(1 - util)).font(Theme.mono(10))
                    .foregroundStyle(util > 1 ? Theme.bad : Theme.muted).monospacedDigit().lineLimit(1)
            }
        } else {
            Text(down ? "refuses work" : "unlimited").font(Theme.small).foregroundStyle(down ? Theme.bad : Theme.faint)
        }
    }
}
