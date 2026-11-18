import SwiftUI
import StrataCore

/// The dock's Pressure tab: where the architecture hurts. A rail of six sections, each with a one-line
/// summary, beside the section on screen. Live parts (culprits, measured rates and latencies) are
/// `SimLive` leaves on the pulse; everything else reads the capacity report cached per revision.
@MainActor
struct SimPressureTab: View {
    let sim: Simulation
    let model: AppModel
    var pulse: SimPulse?
    var still = false
    let select: (StageSelection?) -> Void

    var body: some View {
        let state = SimPressureState.of(sim)
        HStack(spacing: 0) {
            SimPressureRail(sim: sim, pulse: pulse)
                .frame(width: 212)
                .frame(maxHeight: .infinity, alignment: .top)
            Rectangle().fill(Theme.border).frame(width: 1)
            SimPanelScroll(still: still, resetOn: state.section) {
                Group {
                    switch state.section {
                    case .now: SimPressureNow(sim: sim, pulse: pulse, select: select)
                    case .bottlenecks: SimPressureBottlenecks(sim: sim, select: select)
                    case .scale: SimPressureScale(sim: sim, model: model, select: select)
                    case .stores: SimPressureStores(sim: sim, model: model, select: select)
                    case .volumes: SimPressureVolumes(sim: sim, pulse: pulse, select: select)
                    case .capacity: SimPressureCapacity(sim: sim, select: select)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
    }
}

/// Heat mode, in the dock's header while the Pressure tab is open (also ⌘K "Pressure: heat map").
@MainActor
struct SimPressureHeatToggle: View {
    let sim: Simulation

    var body: some View {
        let state = SimPressureState.of(sim)
        SimButton(title: "Heat map", icon: "thermometer.medium", active: state.heat) { state.toggleHeat() }
            .accessibilityValue(state.heat ? "On" : "Off")
    }
}

// MARK: - Rail

@MainActor
private struct SimPressureRail: View {
    let sim: Simulation
    var pulse: SimPulse?

    var body: some View {
        let state = SimPressureState.of(sim)
        let analysis = state.analysis(sim)
        VStack(spacing: 2) {
            ForEach(SimPressureSection.allCases, id: \.self) { section in
                SimPressureRailRow(section: section, selected: state.section == section) {
                    state.section = section
                } summary: {
                    if section == .now {
                        SimLive(sim: sim, pulse: pulse) { nowSummary(state.culprits(sim)) }
                    } else {
                        summary(section, analysis)
                    }
                }
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private func nowSummary(_ culprits: [Culprit]) -> some View {
        if let worst = culprits.first {
            HStack(spacing: 5) {
                Circle().fill(SimPressureStyle.severity(worst.severity)).frame(width: 6, height: 6)
                Text(String(culprits.count)).font(Theme.mono(11, .medium))
                    .foregroundStyle(SimPressureStyle.severity(worst.severity))
            }
        } else {
            Text("calm").font(Theme.mono(10)).foregroundStyle(Theme.faint)
        }
    }

    @ViewBuilder
    private func summary(_ section: SimPressureSection, _ analysis: SimPressureState.Analysis) -> some View {
        let report = analysis.report
        switch section {
        case .now: EmptyView()
        case .bottlenecks:
            if let tightest = report.flows.filter({ $0.maxRate != nil }).map({ ($0, SimPressureState.load($0)) })
                .max(by: { $0.1 < $1.1 }) {
                summaryText(tightest.1 > 1 ? "over" : "\(SimPressureFormat.percent(max(0, 1 - tightest.1))) left",
                            tint: SimPressureStyle.calm(tightest.1))
            } else { summaryText("—") }
        case .scale:
            let count = report.scalePlan.count
            summaryText(report.flows.isEmpty ? "—" : count == 0 ? "none" : count == 1 ? "1 step" : "\(count) steps")
        case .stores:
            let busiest = SimPressureStores.stores(report, level: sim.level).compactMap { analysis.nodes[$0]?.utilization }.max()
            summaryText(busiest.map { "\(SimPressureFormat.percent($0)) busy" } ?? "—", tint: busiest.map(SimPressureStyle.calm) ?? Theme.faint)
        case .volumes:
            let daily = sim.level.flows.filter { !$0.isConsumer }.reduce(0.0) { total, flow in
                total + (report.flows.first { $0.flow == flow.id }?.rate ?? sim.metrics(flow: flow.id).configuredRate) * 86_400
            }
            summaryText(daily > 0 ? SimPressureFormat.perDay(daily) : "—")
        case .capacity:
            let hot = report.nodes.filter { $0.slots != nil && $0.utilization >= 0.8 }.count
            summaryText(report.nodes.isEmpty ? "—" : hot == 0 ? "calm" : "\(hot) hot", tint: hot == 0 ? Theme.faint : Theme.bad)
        }
    }

    private func summaryText(_ value: String, tint: Color = Theme.muted) -> some View {
        Text(value).font(Theme.mono(10.5)).foregroundStyle(tint).lineLimit(1)
    }
}

@MainActor
private struct SimPressureRailRow<Summary: View>: View {
    let section: SimPressureSection
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var summary: Summary
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: section.icon).font(Theme.ui(11, .medium))
                    .foregroundStyle(selected ? Theme.accent : Theme.muted).frame(width: 15)
                Text(section.rawValue).font(Theme.ui(12, selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.text : hovered ? Theme.text : Theme.muted).lineLimit(1)
                Spacer(minLength: 6)
                summary
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(selected ? Theme.selected : hovered ? Theme.hover : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Shared pieces

struct SimPressureHeader<Trailing: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(Theme.ui(12, .semibold)).foregroundStyle(Theme.text)
            if let caption { Text(caption).font(Theme.small).foregroundStyle(Theme.faint).lineLimit(1) }
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension SimPressureHeader where Trailing == EmptyView {
    init(title: String, caption: String? = nil) {
        self.init(title: title, caption: caption) { EmptyView() }
    }
}

struct SimPressureEmpty: View {
    let message: String
    var icon = "circle.dashed"

    var body: some View {
        Label(message, systemImage: icon).font(Theme.ui(12)).foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
    }
}

struct SimPressureHairline: View {
    var inset: CGFloat = 0
    var body: some View { Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, inset) }
}

/// A row that highlights under the pointer and acts on click.
@MainActor
struct SimPressureRowButton<Content: View>: View {
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovered ? Theme.hover : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

extension Simulation {
    /// The stage selection a culprit's subject names: a node, a flow or an edge.
    func pressureTarget(_ subject: String) -> StageSelection? {
        if level.node(subject) != nil { return .node(subject) }
        if level.flow(subject) != nil { return .flow(subject) }
        if subject.contains("->") { return .edge(subject) }
        return nil
    }

    func pressureLabel(_ node: String) -> String { level.node(node)?.label ?? node }

    func pressureFlowColor(_ flow: String) -> Color {
        let index = level.flows.firstIndex { $0.id == flow } ?? 0
        return Theme.token(level.flows.first { $0.id == flow }?.color ?? index + 1)
    }
}

// MARK: - Right now

@MainActor
private struct SimPressureNow: View {
    let sim: Simulation
    var pulse: SimPulse?
    let select: (StageSelection?) -> Void

    var body: some View {
        SimLive(sim: sim, pulse: pulse) { content }
    }

    private var content: some View {
        let state = SimPressureState.of(sim)
        let culprits = state.culprits(sim)
        return VStack(alignment: .leading, spacing: 9) {
            SimPressureHeader(title: "Right now", caption: "live, worst first") {
                if !culprits.isEmpty {
                    Text(culprits.count == 1 ? "1 trouble spot" : "\(culprits.count) trouble spots")
                        .font(Theme.small).foregroundStyle(Theme.muted)
                }
            }
            if culprits.isEmpty {
                calm(state.analysis(sim))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(culprits.enumerated()), id: \.element.id) { offset, culprit in
                        if offset > 0 { SimPressureHairline(inset: 40) }
                        row(culprit)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .card(radius: 8)
            }
        }
    }

    private func row(_ culprit: Culprit) -> some View {
        let tint = SimPressureStyle.severity(culprit.severity)
        return SimPressureRowButton { if let target = sim.pressureTarget(culprit.subject) { select(target) } } content: {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 1.5).fill(tint).frame(width: 3, height: 16)
                Image(systemName: culprit.kind.icon).font(Theme.ui(11, .medium)).foregroundStyle(tint).frame(width: 16)
                Text(culprit.message).font(Theme.ui(12)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(culprit.kind.title).font(Theme.mono(10)).foregroundStyle(Theme.faint).fixedSize()
                Image(systemName: "chevron.right").font(Theme.ui(9, .medium)).foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .accessibilityLabel("\(culprit.kind.title): \(culprit.message)")
        .accessibilityHint("Selects it on the stage")
    }

    private func calm(_ analysis: SimPressureState.Analysis) -> some View {
        let busiest = analysis.report.nodes.filter { $0.slots != nil }.max { $0.utilization < $1.utilization }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle").font(Theme.ui(15, .medium)).foregroundStyle(Theme.good.opacity(0.85))
            VStack(alignment: .leading, spacing: 3) {
                Text("Nothing hurting").font(Theme.ui(13, .semibold)).foregroundStyle(Theme.text)
                Text("No node is saturated, no queue is growing and every SLO holds.")
                    .font(Theme.ui(12)).foregroundStyle(Theme.muted)
                if let busiest, let slots = busiest.slots, let node = sim.level.node(busiest.node) {
                    Text("Busiest: \(node.label) at \(SimPressureFormat.percent(busiest.utilization)) of its \(SimPressureFormat.slots(slots, kind: node.kind)).")
                        .font(Theme.small).foregroundStyle(Theme.faint)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .card(radius: 8)
    }
}

// MARK: - Bottlenecks

@MainActor
private struct SimPressureBottlenecks: View {
    let sim: Simulation
    let select: (StageSelection?) -> Void

    var body: some View {
        let analysis = SimPressureState.of(sim).analysis(sim)
        let flows = analysis.report.flows.sorted { load($0) > load($1) }
        VStack(alignment: .leading, spacing: 9) {
            SimPressureHeader(title: "Bottlenecks", caption: "rate now against the rate where the first node saturates") {
                legend
            }
            if flows.isEmpty {
                SimPressureEmpty(message: "No capacity analysis for this level yet", icon: "gauge.with.dots.needle.0percent")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(flows.enumerated()), id: \.element.id) { offset, flow in
                        if offset > 0 { SimPressureHairline() }
                        row(flow, analysis: analysis)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .card(radius: 8)
            }
            if !analysis.report.notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(analysis.report.notes.enumerated()), id: \.offset) { _, note in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: "info.circle").font(Theme.ui(10, .medium)).foregroundStyle(Theme.faint)
                            Text(note).font(Theme.small).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 2)
            }
        }
    }

    private func load(_ flow: FlowCapacity) -> Double { SimPressureState.load(flow) }

    private var legend: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Capsule().fill(Theme.muted).frame(width: 12, height: 5)
                Text("now")
            }
            HStack(spacing: 4) {
                Rectangle().fill(Theme.text.opacity(0.75)).frame(width: 1.5, height: 10)
                Text("max")
            }
            HStack(spacing: 4) {
                Image(systemName: "arrowtriangle.down.fill").font(Theme.ui(7))
                Text("declared peak")
            }
        }
        .font(Theme.small).foregroundStyle(Theme.muted)
    }

    private func row(_ flow: FlowCapacity, analysis: SimPressureState.Analysis) -> some View {
        let declared = flow.declared ?? sim.level.flow(flow.flow)?.traffic
        let peak = declared?.peak
        let ratio = load(flow)
        let now = flow.offered ?? flow.rate
        let overPeak = peak.map { peak in flow.maxRate.map { peak > $0 } ?? false } ?? false
        return SimPressureRowButton {
            select(flow.bottleneck.map(StageSelection.node) ?? .flow(flow.flow))
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Circle().fill(sim.pressureFlowColor(flow.flow)).frame(width: 7, height: 7)
                    Text(sim.level.flow(flow.flow)?.label ?? flow.flow).font(Theme.ui(12, .semibold)).foregroundStyle(Theme.text)
                    Text(sentence(flow, analysis: analysis)).font(Theme.ui(12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if flow.maxRate != nil {
                        if ratio > 1 {
                            Text("over capacity").font(Theme.mono(12, .medium)).foregroundStyle(Theme.bad)
                        } else {
                            Text(SimPressureFormat.percent(max(0, 1 - ratio))).font(Theme.mono(12, .medium))
                                .foregroundStyle(SimPressureStyle.calm(ratio))
                            Text("headroom").font(Theme.small).foregroundStyle(Theme.muted)
                        }
                    }
                }
                HStack(spacing: 14) {
                    SimPressureBar(rate: now, maxRate: flow.maxRate, peak: peak).frame(height: 15)
                    figure(SimPressureFormat.rate(now), flow.offered == nil ? "now" : "arrive", tint: ratio > 1 ? Theme.bad : Theme.text)
                    figure(flow.maxRate.map(SimPressureFormat.rate) ?? "—", "max", tint: Theme.text)
                    figure(peak.map(SimPressureFormat.rate) ?? "—", "peak", tint: overPeak ? Theme.bad : peak == nil ? Theme.faint : Theme.text)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
        }
        .accessibilityElement(children: .combine)
    }

    private func figure(_ value: String, _ label: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(Theme.mono(11, .medium)).foregroundStyle(tint).monospacedDigit()
            Text(label).font(Theme.small).foregroundStyle(Theme.faint)
        }
        .frame(width: 92, alignment: .trailing)
    }

    /// `saturates at 60/s: orders db, 8 connections`, and for a consumer that can't keep up, how fast
    /// its backlog grows.
    private func sentence(_ flow: FlowCapacity, analysis: SimPressureState.Analysis) -> String {
        if let offered = flow.offered, offered > 0, flow.rate == 0 { return "stopped: its consumer is down or out of slots" }
        guard let maxRate = flow.maxRate else { return "no bottleneck within 100× this rate" }
        var text = "saturates at \(SimPressureFormat.rate(maxRate))"
        if let id = flow.bottleneck {
            text += ": \(sim.pressureLabel(id))"
            if let slots = analysis.nodes[id]?.slots, let node = sim.level.node(id) {
                text += slots == 0 ? ", down" : ", \(SimPressureFormat.slots(slots, kind: node.kind))"
            }
        }
        if let offered = flow.offered, offered > maxRate * 1.000_001 {
            text += "; backlog grows \(SimPressureFormat.rate(offered - maxRate))"
        }
        return text
    }
}

/// Rate now as a fill, the max rate as a tick, and the declared peak as a marker above the bar; the
/// stretch between max and a higher peak is shaded red.
struct SimPressureBar: View {
    let rate: Double
    let maxRate: Double?
    let peak: Double?

    var body: some View {
        Canvas { context, size in
            let domain = max(maxRate ?? 0, peak ?? 0, rate, 0.000_001) * 1.08
            func x(_ value: Double) -> CGFloat { size.width * CGFloat(min(1, max(0, value / domain))) }
            let bar = CGRect(x: 0, y: size.height - 8, width: size.width, height: 6)
            context.fill(Path(roundedRect: bar, cornerRadius: 3), with: .color(Theme.selected))
            if let maxRate, let peak, peak > maxRate {
                let short = CGRect(x: x(maxRate), y: bar.minY, width: x(peak) - x(maxRate), height: bar.height)
                context.fill(Path(short), with: .color(Theme.bad.opacity(0.20)))
            }
            let load = maxRate.map { rate / max($0, 0.000_001) } ?? 0
            let fill = CGRect(x: 0, y: bar.minY, width: max(2, x(rate)), height: bar.height)
            context.fill(Path(roundedRect: fill, cornerRadius: 3), with: .color(SimPressureStyle.heat(load).opacity(0.85)))
            if let maxRate {
                let tick = CGRect(x: x(maxRate) - 0.75, y: bar.minY - 3, width: 1.5, height: bar.height + 6)
                context.fill(Path(tick), with: .color(Theme.text.opacity(0.75)))
            }
            if let peak {
                let px = min(size.width - 4, max(4, x(peak)))
                let color = maxRate.map { peak > $0 } == true ? Theme.bad : Theme.muted
                var marker = Path()
                marker.move(to: CGPoint(x: px - 4, y: 0))
                marker.addLine(to: CGPoint(x: px + 4, y: 0))
                marker.addLine(to: CGPoint(x: px, y: 5))
                marker.closeSubpath()
                context.fill(marker, with: .color(color))
                context.fill(Path(CGRect(x: px - 0.5, y: 5, width: 1, height: bar.maxY - 5)), with: .color(color.opacity(0.8)))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Scale next

@MainActor
private struct SimPressureScale: View {
    let sim: Simulation
    let model: AppModel
    let select: (StageSelection?) -> Void

    var body: some View {
        let state = SimPressureState.of(sim)
        let analysis = state.analysis(sim)
        let plan = analysis.report.scalePlan
        let tries = state.liveTries(sim)
        // A try the plan shows as a row keeps its Undo there; any other try gets its own line.
        let planned = Set(plan.map(\.id))
        VStack(alignment: .leading, spacing: 9) {
            SimPressureHeader(title: "Scale next", caption: "scale the bottleneck until it stops being one, then the next")
            ForEach(tries.filter { !planned.contains("\($0.node)-\($0.to)") }) { tried in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(Theme.ui(12, .medium)).foregroundStyle(Theme.good.opacity(0.85))
                    Text("Scaled \(sim.pressureLabel(tried.node)) \(tried.from) → \(tried.to) replicas")
                        .font(Theme.ui(12)).foregroundStyle(Theme.text)
                    Text("watch the stage").font(Theme.small).foregroundStyle(Theme.faint)
                    Spacer(minLength: 8)
                    SimButton(title: "Undo", icon: "arrow.uturn.backward") { state.undo(tried, sim: sim) }
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .card(radius: 8)
            }
            if plan.isEmpty {
                SimPressureEmpty(message: analysis.report.flows.isEmpty ? "No capacity analysis for this level yet"
                                 : "Nothing saturates within 100× today's rates", icon: "checkmark.circle")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(plan.enumerated()), id: \.element.id) { offset, step in
                        if offset > 0 { SimPressureHairline(inset: 38) }
                        row(step, offset: offset, plan: plan, analysis: analysis, tries: tries)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .card(radius: 8)
                footer(plan, analysis: analysis)
            }
        }
    }

    private func before(_ offset: Int, plan: [ScaleStep], analysis: SimPressureState.Analysis) -> Double? {
        if offset > 0 { return plan[offset - 1].newMaxRate }
        if let flow = plan[0].flow { return analysis.report.flows.first { $0.flow == flow }?.maxRate }
        return SimPressureState.of(sim).primaryFlow(for: plan[0].node, sim: sim)?.maxRate
    }

    private func row(_ step: ScaleStep, offset: Int, plan: [ScaleStep], analysis: SimPressureState.Analysis,
                     tries: [SimPressureState.Tried]) -> some View {
        let state = SimPressureState.of(sim)
        let tried = tries.first { $0.node == step.node && $0.to == step.replicas }
        // Steps build on each other: a node scaled earlier in the plan starts from that step's replicas.
        let earlier = plan.prefix(offset).last { $0.node == step.node }?.replicas
        let from = tried?.from ?? earlier ?? state.replicas(step.node, sim: sim)
        // The why: the reason's first sentence ("mailer is over capacity at peak.").
        let why = step.reason.components(separatedBy: ". ").first.map { $0.hasSuffix(".") ? $0 : $0 + "." } ?? ""
        return HStack(alignment: .center, spacing: 12) {
            Text(String(offset + 1)).font(Theme.mono(12, .medium)).foregroundStyle(Theme.faint)
                .frame(width: 14, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Button { select(.node(step.node)) } label: {
                        Text(sim.pressureLabel(step.node)).font(Theme.ui(12, .semibold)).foregroundStyle(Theme.text)
                    }
                    .buttonStyle(.plain)
                    Text("\(from) → \(step.replicas) replicas").font(Theme.mono(12)).foregroundStyle(Theme.text)
                    Text("·").foregroundStyle(Theme.faint)
                    if step.utilization > 0 || step.newUtilization > 0 {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(SimPressureFormat.percent(step.utilization)).foregroundStyle(SimPressureStyle.calm(step.utilization))
                            Text("→").foregroundStyle(Theme.faint)
                            Text(SimPressureFormat.percent(step.newUtilization)).foregroundStyle(Theme.text)
                            Text("busy").font(Theme.ui(12)).foregroundStyle(Theme.muted)
                        }
                        .font(Theme.mono(12))
                    } else if let after = step.newMaxRate {
                        Text("max \(before(offset, plan: plan, analysis: analysis).map(SimPressureFormat.number) ?? "?") → \(SimPressureFormat.rate(after))")
                            .font(Theme.mono(12)).foregroundStyle(Theme.muted)
                    }
                    Text(next(step)).font(Theme.ui(12)).foregroundStyle(Theme.muted)
                }
                if !why.isEmpty, why != "." {
                    Text(why).font(Theme.small).foregroundStyle(Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let tried {
                SimButton(title: "Undo", icon: "arrow.uturn.backward", active: true) { state.undo(tried, sim: sim) }
            } else {
                SimButton(title: "Try it", icon: "play.fill") {
                    state.scale(step.node, to: step.replicas, sim: sim)
                    model.overlays.toast("Scaled \(sim.pressureLabel(step.node)) to \(step.replicas) replicas")
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// `then orders-svc saturates at 188/s`, or that nothing else does.
    private func next(_ step: ScaleStep) -> String {
        guard let next = step.nextBottleneck else { return "then nothing else saturates" }
        let at = step.newMaxRate.map { " at \(SimPressureFormat.rate($0))" } ?? ""
        return next == step.node ? "then it saturates again\(at)" : "then \(sim.pressureLabel(next)) saturates\(at)"
    }

    @ViewBuilder
    private func footer(_ plan: [ScaleStep], analysis: SimPressureState.Analysis) -> some View {
        let id = plan.last?.flow ?? plan.first?.flow ?? SimPressureState.of(sim).primaryFlow(for: plan[0].node, sim: sim)?.flow
        if let last = plan.last?.newMaxRate, let id, let flow = sim.level.flow(id) {
            let capacity = analysis.report.flows.first { $0.flow == id }
            let peak = (capacity?.declared ?? flow.traffic)?.peak
            let steps = plan.count == 1 ? "this step" : "these \(plan.count) steps"
            HStack(spacing: 6) {
                if let peak {
                    Image(systemName: last >= peak ? "checkmark" : "exclamationmark.triangle")
                        .font(Theme.ui(10, .semibold)).foregroundStyle(last >= peak ? Theme.good : Theme.warn)
                    Text("After \(steps) \(flow.label) takes \(SimPressureFormat.rate(last)), \(last >= peak ? "above" : "still under") its declared peak of \(SimPressureFormat.rate(peak)).")
                } else {
                    Text("After \(steps) \(flow.label) takes \(SimPressureFormat.rate(last)) before the next node saturates.")
                }
            }
            .font(Theme.small).foregroundStyle(Theme.muted)
            .padding(.leading, 2)
        }
    }
}
