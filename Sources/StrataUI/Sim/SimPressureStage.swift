import SwiftUI
import StrataCore

/// How a highlighted node or edge is drawn when it carries its own colour (pressure overlays): the
/// border and glow in `color` at `strength` (0...1), an optional short tag over the card, and a
/// dashed ring around it ("stops here").
struct StageTint: Equatable, Sendable {
    var color: Color
    var strength = 1.0
    var tag: String?
    var ring = false
}

/// Colours of the Pressure tab and its stage overlays. Red only for real trouble.
enum SimPressureStyle {
    /// Static utilization: green under 0.5, amber under 0.8, red above.
    static func heat(_ utilization: Double) -> Color {
        utilization < 0.5 ? Theme.good : utilization < 0.8 ? Theme.warn : Theme.bad
    }

    /// A figure that only turns red at real trouble (≥ 80% busy) and stays quiet otherwise.
    static func calm(_ utilization: Double) -> Color {
        utilization >= 0.8 ? Theme.bad : utilization >= 0.5 ? Theme.text : Theme.muted
    }

    static func severity(_ severity: Culprit.Severity) -> Color {
        switch severity {
        case .critical: Theme.bad
        case .warn: Theme.warn
        case .watch: Theme.muted
        }
    }

    static func access(_ access: OpAccess?) -> Color {
        switch access {
        case .read: Theme.info
        case .write: Theme.token(2)
        case .readWrite: Theme.token(4)
        case nil: Theme.muted
        }
    }
}

extension Culprit.Kind {
    var icon: String {
        switch self {
        case .saturated: "gauge.with.dots.needle.100percent"
        case .queueing: "tray.full"
        case .lagging: "hourglass"
        case .timeouts: "timer"
        case .errors: "exclamationmark.triangle"
        case .breakerOpen: "bolt.slash"
        case .down: "power"
        case .sloBreach: "target"
        }
    }

    var title: String {
        switch self {
        case .saturated: "saturated"
        case .queueing: "queueing"
        case .lagging: "lagging"
        case .timeouts: "timeouts"
        case .errors: "errors"
        case .breakerOpen: "breaker open"
        case .down: "down"
        case .sloBreach: "SLO"
        }
    }
}

/// Numbers in the Pressure tab: right-aligned mono, `47/s`, `4.2M/day`, `92%`.
enum SimPressureFormat {
    /// `47/s` from 10 up, `4.5/s` below.
    static func rate(_ perSecond: Double) -> String { "\(number(perSecond))/s" }

    static func number(_ value: Double) -> String {
        SimFormat.number(value >= 10 ? value.rounded() : value)
    }

    /// `840`, `43.2k`, `389k`, `4.2M`, `1.3B`.
    static func count(_ value: Double) -> String {
        let magnitude = abs(value)
        func scaled(_ unit: Double, _ suffix: String) -> String {
            let v = value / unit
            return (abs(v) >= 100 ? SimFormat.number(v.rounded()) : SimFormat.number((v * 10).rounded() / 10)) + suffix
        }
        if magnitude >= 1e9 { return scaled(1e9, "B") }
        if magnitude >= 1e6 { return scaled(1e6, "M") }
        if magnitude >= 1e3 { return scaled(1e3, "k") }
        return SimFormat.number(value >= 10 ? value.rounded() : value)
    }

    static func perDay(_ value: Double) -> String { count(value) + "/day" }

    /// `92%`, and `<1%` for a load too small to round up to one.
    static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "—" }
        if fraction > 0, fraction < 0.005 { return "<1%" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    static func latency(_ seconds: Double?) -> String { SimOpsText.latency(seconds) }

    /// `8 connections`, `16 slots`.
    static func slots(_ count: Int, kind: NodeKind) -> String {
        let noun = switch kind {
        case .database, .cache, .search, .vector: count == 1 ? "connection" : "connections"
        default: count == 1 ? "slot" : "slots"
        }
        return "\(count) \(noun)"
    }
}

/// The legend chip in the stage's top-left corner while a pressure overlay shows.
@MainActor
struct SimPressureLegend: View {
    let sim: Simulation
    let selection: StageSelection?
    let tabOpen: Bool

    var body: some View {
        let state = SimPressureState.of(sim)
        let overlay = state.overlay(for: selection, tabOpen: tabOpen, opsLit: SimOpsState.of(sim).lit(for: selection),
                                    level: sim.level)
        if let overlay {
            HStack(spacing: 10) {
                switch overlay {
                case .heat:
                    Label("Heat map", systemImage: "thermometer.medium")
                        .font(Theme.ui(11, .semibold)).foregroundStyle(Theme.text)
                    Text("static utilization").font(Theme.small).foregroundStyle(Theme.muted)
                    swatch(Theme.good, "< 50%")
                    swatch(Theme.warn, "< 80%")
                    swatch(Theme.bad, "≥ 80%")
                case .blast(let node):
                    Label("Blast radius of \(sim.level.node(node)?.label ?? node)", systemImage: "burst")
                        .font(Theme.ui(11, .semibold)).foregroundStyle(Theme.text)
                    HStack(spacing: 5) {
                        Capsule().fill(Theme.bad.opacity(0.85)).frame(width: 14, height: 3)
                        Text("backs up").font(Theme.small).foregroundStyle(Theme.muted)
                    }
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Theme.warn.opacity(0.85), style: StrokeStyle(lineWidth: 1.2, dash: [2.5, 2]))
                            .frame(width: 12, height: 10)
                        Text("stops here").font(Theme.small).foregroundStyle(Theme.muted)
                    }
                    swatch(Theme.warn, "lags")
                }
                StrataKeycap("esc")
                Button { state.clear(overlay, selection: selection) } label: {
                    Image(systemName: "xmark").font(Theme.ui(9, .semibold)).foregroundStyle(Theme.muted)
                        .frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(overlay == .heat ? "Turn off heat map" : "Hide blast radius")
            }
            .lineLimit(1)
            .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 6)
            .background(Theme.overlay.opacity(0.94), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            .fixedSize()
            .padding(12)
            .transition(.opacity)
        }
    }

    private func swatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(Theme.small).foregroundStyle(Theme.muted)
        }
    }
}
