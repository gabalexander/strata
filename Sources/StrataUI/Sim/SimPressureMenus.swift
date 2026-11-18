import SwiftUI
import StrataCore

/// Right-click items and ⌘K commands for the Pressure tab and its stage overlays.
@MainActor
enum SimPressureMenus {
    /// "Show blast radius", and "Scale to fix" when the node is a bottleneck. The right-click has
    /// already selected the node, which anchors the blast radius.
    static func node(_ node: Node, sim: Simulation, model: AppModel) -> [MenuItem] {
        guard node.kind.role == .server || node.kind.role == .buffer else { return [] }
        let state = SimPressureState.of(sim)
        var items: [MenuItem] = [.separator, MenuItem("Show blast radius", icon: "burst") { state.showBlast(node.id) }]
        if let fix = fix(node.id, sim: sim) {
            items.append(MenuItem("Scale to fix: \(fix.to) replicas", icon: "plus.square.on.square") {
                state.scale(node.id, to: fix.to, sim: sim)
                model.overlays.toast("Scaled \(node.label) to \(fix.to) replicas")
            })
        }
        return items
    }

    /// The replicas that stop the node being a bottleneck: its scale-plan step, else one more.
    static func fix(_ node: String, sim: Simulation) -> (from: Int, to: Int)? {
        let state = SimPressureState.of(sim)
        let analysis = state.analysis(sim)
        guard analysis.bottleneckFor[node]?.isEmpty == false else { return nil }
        let current = state.replicas(node, sim: sim)
        let target = analysis.steps[node]?.replicas ?? current + 1
        return target > current ? (current, target) : nil
    }

    /// ⌘K: "Pressure: heat map", "Pressure: open tab", and "Pressure: show blast radius of …" per node.
    static func palette(sim: Simulation, model: AppModel) -> [MenuItem] {
        let state = SimPressureState.of(sim)
        var items = [
            MenuItem("Pressure: heat map", icon: "thermometer.medium", checked: state.heat) { state.toggleHeat() },
            MenuItem("Pressure: open tab", icon: "gauge.with.dots.needle.67percent") { state.openTab() },
        ]
        items += sim.level.nodes.filter { $0.kind.role == .server || $0.kind.role == .buffer }.map { node in
            MenuItem("Pressure: show blast radius of \(node.label)", icon: "burst") {
                state.showBlast(node.id)
                SimFocus.of(model).reveal(node.id, in: sim.manifest.id, path: sim.path, model: model)
            }
        }
        return items
    }
}

/// The inspector's one-line "Capacity" row for a node: utilization, headroom, and the flows it is
/// the bottleneck for. Clicking opens the Pressure tab.
@MainActor
struct SimPressureInspectorRow: View {
    let sim: Simulation
    let node: Node
    @State private var hovered = false

    var body: some View {
        let state = SimPressureState.of(sim)
        let analysis = state.analysis(sim)
        if let capacity = analysis.nodes[node.id], capacity.slots != nil {
            let flows = (analysis.bottleneckFor[node.id] ?? []).map { sim.level.flow($0.flow)?.label ?? $0.flow }
            let primary = state.primaryFlow(for: node.id, sim: sim).map { sim.level.flow($0.flow)?.label ?? $0.flow }
            let util = capacity.utilization
            Button { state.openTab(flows.isEmpty ? .capacity : .bottlenecks) } label: {
                // One line: the longest variant that fits the inspector's width.
                ViewThatFits(in: .horizontal) {
                    line(util, title: true, flow: primary, named: true, headroom: true)
                    line(util, title: true, flow: primary, named: true, headroom: false)
                    line(util, title: false, flow: primary, named: true, headroom: false)
                    line(util, title: true, flow: primary, named: false, headroom: false)
                }
                .padding(.horizontal, 9).frame(height: 28)
                .background(hovered ? Theme.hover : Theme.raised, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .accessibilityLabel("Capacity: \(SimPressureFormat.percent(util)) utilization\(flows.isEmpty ? "" : ", bottleneck for \(flows.joined(separator: ", "))")")
            .accessibilityHint("Opens the Pressure tab")
        }
    }

    /// `Capacity · bottleneck for Place order ······ util 92% · 8% headroom →`
    private func line(_ util: Double, title: Bool, flow: String?, named: Bool, headroom: Bool) -> some View {
        HStack(spacing: 6) {
            if title { Text("Capacity").font(Theme.ui(11, .semibold)).foregroundStyle(Theme.muted) }
            if let flow {
                Text(named ? (title ? "· bottleneck for \(flow)" : "Bottleneck for \(flow)") : "· bottleneck")
                    .font(Theme.ui(11, .medium)).foregroundStyle(Theme.warn)
            }
            Spacer(minLength: 8)
            Text("util \(SimPressureFormat.percent(util))").font(Theme.mono(11, .medium))
                .foregroundStyle(SimPressureStyle.calm(util))
            if headroom || flow == nil {
                Text("· \(util > 1 ? "over capacity" : "\(SimPressureFormat.percent(max(0, 1 - util))) headroom")")
                    .font(Theme.mono(11)).foregroundStyle(Theme.muted)
            }
            Image(systemName: "arrow.right").font(Theme.ui(9, .semibold))
                .foregroundStyle(hovered ? Theme.text : Theme.faint)
        }
        .lineLimit(1)
    }
}
