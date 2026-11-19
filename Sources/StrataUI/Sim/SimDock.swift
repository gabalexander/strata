import SwiftUI
import StrataCore

@_spi(Snapshots) public enum SimDockTab: String, CaseIterable {
    case controls = "Controls"
    case scenarios = "Try this"
    case pressure = "Pressure"
    case log = "Log"
    case glossary = "Glossary"
    case ask = "Ask"
    case about = "About"

    var icon: String {
        switch self {
        case .controls: "slider.horizontal.3"
        case .scenarios: "flag"
        case .pressure: "gauge.with.dots.needle.67percent"
        case .log: "list.bullet.rectangle"
        case .glossary: "text.book.closed"
        case .ask: "sparkle.magnifyingglass"
        case .about: "info.circle"
        }
    }

    /// The tab's hover hint: what it holds, in a few words.
    var hint: String {
        switch self {
        case .controls: "Controls: change the system and see what moves"
        case .scenarios: "Try this: guided scenarios to run"
        case .pressure: "Pressure: bottlenecks, capacity, blast radius"
        case .log: "Log: what just happened, newest first"
        case .glossary: "Glossary: the terms this map uses"
        case .ask: "Ask the map a question"
        case .about: "About this map"
        }
    }

    var shortcut: Shortcut? { self == .ask ? Shortcuts.ask : nil }
}

@MainActor
struct SimDock: View, Equatable {
    let sim: Simulation
    let model: AppModel
    let terms: TermIndex
    let actions: SimActions
    let selection: StageSelection?
    var pulse: SimPulse?
    var still = false
    /// Selects on the stage (the Pressure tab's rows).
    var select: (StageSelection?) -> Void = { _ in }
    @SwiftUI.Binding var tab: SimDockTab
    @State private var filterNode = true

    /// Only the log shows the selection, so selecting something elsewhere leaves the dock alone. Rows
    /// observe the simulation themselves; the closures in `actions` act on the same session either way.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        MainActor.assumeIsolated {
            lhs.sim === rhs.sim && lhs.pulse === rhs.pulse && lhs.still == rhs.still && lhs.tab == rhs.tab
                && lhs.logSelection == rhs.logSelection
        }
    }

    private var logSelection: StageSelection? { tab == .log || tab == .ask ? selection : nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                // Labels when they fit, else icons alone (each still says what it is in its hint).
                ViewThatFits(in: .horizontal) {
                    tabs(labels: true)
                    tabs(labels: false)
                }
                Spacer(minLength: 0)
                if tab == .pressure { SimPressureHeatToggle(sim: sim) }
                SimButton(title: "Hide dock", icon: "chevron.down", iconOnly: true, shortcut: Shortcuts.dock) { model.dockVisible = false }
            }
            .padding(.horizontal, 12).frame(height: 40)
            Rectangle().fill(Theme.border).frame(height: 1)
            if tab == .pressure {
                SimPressureTab(sim: sim, model: model, pulse: pulse, still: still, select: select)
            } else if tab == .ask {
                SimAskTab(sim: sim, model: model, selection: selection, still: still, select: select)
            } else {
                scrollable
            }
        }
        .background(Theme.surface)
    }

    private func tabs(labels: Bool) -> some View {
        HStack(spacing: 3) {
            ForEach(SimDockTab.allCases.filter { $0 != .ask || !SimAskState.offInConfig(model) }, id: \.self) { item in
                Button { tab = item } label: {
                    Group {
                        if labels { Label(item.rawValue, systemImage: item.icon) } else { Image(systemName: item.icon).frame(width: 14) }
                    }
                    .font(Theme.ui(11, .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .foregroundStyle(tab == item ? Theme.accent : Theme.muted)
                    .background(tab == item ? Theme.accent.opacity(0.10) : .clear,
                                in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .strataHint(item.hint, shortcut: item.shortcut?.display)
                .accessibilityLabel(item.rawValue)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
        }
        .fixedSize()
    }

    /// A tab switch rebuilds this on the same frame. Rows observe what they show themselves:
    /// `revision` for discrete changes and the pulse for live numbers.
    private var scrollable: some View {
        return SimPanelScroll(still: still, resetOn: tab) {
            Group {
                switch tab {
                case .controls: controls
                case .scenarios: scenarios
                case .pressure, .ask: EmptyView()
                case .log: SimLive(sim: sim, pulse: nil) { logContent }
                case .glossary: glossary
                case .about: about
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
        .onChange(of: selection) { _, _ in filterNode = true }
    }

    private var controls: some View {
        Group {
            if sim.level.controls.isEmpty {
                empty("No controls at this level", icon: "slider.horizontal.3")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 245, maximum: 360), spacing: 10, alignment: .topLeading)],
                          alignment: .leading, spacing: 10) {
                    ForEach(sim.level.controls) { control in
                        controlCard(control).frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                .frame(maxWidth: sim.level.controls.count == 2 ? 734 : .infinity, alignment: .leading)
            }
        }
    }

    private func controlCard(_ control: Control) -> some View {
        // Rows of a ForEach over unchanged data are not rebuilt by the panel's timeline, so each row
        // observes `revision`, which bumps on every parameter change, command and scenario step.
        let _ = sim.revision
        let value = sim.value(control.bind)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let id = control.term, let term = terms.term(id) {
                    SimTermAnchor(term: term, model: model, index: terms) {
                        Text(control.label).font(Theme.ui(12, .semibold)).foregroundStyle(Theme.accent)
                    }
                } else {
                    Text(control.label).font(Theme.ui(12, .semibold)).foregroundStyle(Theme.text)
                }
                Spacer(minLength: 4)
                if let value {
                    Text(SimFormat.value(value, param: control.bind.param, unit: control.unit))
                        .font(Theme.mono(11)).foregroundStyle(Theme.accent)
                }
            }
            switch control.input {
            case .range(let lower, let upper, let step):
                if upper > lower {
                    SimSlider(title: control.label,
                              value: SwiftUI.Binding(get: { sim.value(control.bind)?.number ?? lower },
                                                     set: { sim.setValue(.number($0), for: control.bind) }),
                              range: lower...upper, step: step > 0 ? step : (upper - lower) / 100)
                }
            case .options(let options):
                if let first = options.first {
                    ViewThatFits(in: .horizontal) {
                        SimSegments(values: options, selected: value ?? first, label: {
                            SimFormat.value($0, param: control.bind.param, unit: control.unit)
                        }, select: { sim.setValue($0, for: control.bind) })
                        SimValuePicker(model: model, options: options, value: value, label: {
                            SimFormat.value($0, param: control.bind.param, unit: control.unit)
                        }, select: { sim.setValue($0, for: control.bind) })
                    }
                }
            case .toggle:
                Toggle(control.label, isOn: SwiftUI.Binding(get: { value == .bool(true) },
                                                         set: { sim.setValue(.bool($0), for: control.bind) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Theme.accent)
            }

            if let insight = control.insights.first(where: { $0.when == .always || value.map($0.when.matches) == true }) {
                if !insight.effects.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 5) { effectChips(insight) }
                        VStack(alignment: .leading, spacing: 5) { effectChips(insight) }
                    }
                }
                SimMarkdown(source: insight.text, model: model, terms: terms, size: 12)
            } else if let hint = control.hint {
                SimMarkdown(source: hint, model: model, terms: terms, size: 12)
            }
        }
        .padding(11)
        .card()
    }

    private func effectChips(_ insight: InsightRule) -> some View {
        ForEach(Array(insight.effects.enumerated()), id: \.offset) { _, effect in
            let icon = effect.dir == .up ? "arrow.up" : effect.dir == .down ? "arrow.down" : "arrow.right"
            let tint = effect.good.map { $0 ? Theme.good : Theme.bad } ?? Theme.muted
            SimPill(title: effect.metric, icon: icon, tint: tint)
        }
    }

    private var scenarios: some View {
        VStack(alignment: .leading, spacing: 8) {
            if sim.level.scenarios.isEmpty { empty("No scenarios at this level", icon: "flag") }
            ForEach(sim.level.scenarios) { scenario in
                // `scenario` is observed, so starting or stopping one updates the row on the same frame.
                let active = sim.scenario == scenario.id
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "flag").foregroundStyle(active ? Theme.accent : Theme.muted)
                        Text(scenario.label).font(Theme.ui(13, .semibold)).foregroundStyle(Theme.text)
                        if active {
                            SimLive(sim: sim, pulse: pulse) { SimPill(title: stepLabel(scenario), tint: Theme.accent) }
                        }
                        Spacer(minLength: 4)
                        SimButton(title: active ? "Stop" : "Run", icon: active ? "stop.fill" : "play.fill", active: active) {
                            if active { sim.stopScenario() }
                            else { sim.start(scenario: scenario.id) }
                        }
                    }
                    if let goal = scenario.goal { SimMarkdown(source: goal, model: model, terms: terms, size: 12) }
                    if active {
                        SimLive(sim: sim, pulse: pulse) {
                            if let next = scenario.steps.filter({ $0.at > sim.now }).min(by: { $0.at < $1.at }) {
                                Text("Next step at \(SimFormat.seconds(next.at))").font(Theme.mono(10)).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                    if !scenario.watch.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 173, maximum: 230), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 6) {
                            ForEach(scenario.watch, id: \.self) { name in
                                HStack(spacing: 5) {
                                    Text(name).font(Theme.mono(10)).foregroundStyle(Theme.muted).lineLimit(1)
                                    Spacer(minLength: 0)
                                    SimLive(sim: sim, pulse: pulse) {
                                        Text(watched(name)).font(Theme.mono(11, .medium)).foregroundStyle(Theme.text)
                                            .lineLimit(1)
                                    }
                                }
                                .padding(6)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
                            }
                        }
                    }
                }
                .padding(11)
                .card()
                .frame(maxWidth: 734, alignment: .leading)
            }
        }
    }

    private func stepLabel(_ scenario: Scenario) -> String {
        let current = scenario.steps.count(where: { $0.at <= sim.now })
        return scenario.steps.isEmpty ? "Running" : "Step \(current)/\(scenario.steps.count)"
    }

    private func watched(_ name: String) -> String {
        guard let key = MetricKey.parse(name, in: sim.level) else { return "—" }
        switch key {
        case .node(let id, let metric):
            guard let state = sim.nodeState(id) else { return "—" }
            if metric == .inflight, let last = sim.series(key).last { return SimFormat.number(last) }
            return state.formatted(metric)
        case .flow(let id, let metric):
            let m = sim.metrics(flow: id)
            switch metric {
            case .rate: return "\(SimFormat.number(m.configuredRate))/s"
            case .ok: return "\(SimFormat.number(m.ok))/s"
            case .errors: return "\(SimFormat.number(m.failed))/s"
            case .p50: return SimFormat.latency(m.p50)
            case .p99: return SimFormat.latency(m.p99)
            case .retries: return "\(SimFormat.number(m.retries))/s"
            }
        }
    }

    private var logContent: some View {
        let id: String? = if case .node(let id) = selection { id } else { nil }
        let entries = sim.log.filter { entry in !filterNode || id == nil || entry.node == id }
        return VStack(alignment: .leading, spacing: 7) {
            if let id {
                SimButton(title: sim.level.node(id)?.label ?? id, icon: "line.3.horizontal.decrease", active: filterNode,
                          hint: filterNode ? "Showing this node's events; click for all" : "Show only this node's events") {
                    filterNode.toggle()
                }
                .accessibilityHint(filterNode ? "Show all events" : "Show only events for this node")
            }
            if entries.isEmpty { empty("No events yet", icon: "list.bullet.rectangle") }
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(entries.reversed()) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(SimFormat.seconds(event.t))
                            .font(Theme.mono(11)).foregroundStyle(Theme.muted).frame(width: 54, alignment: .trailing)
                        Image(systemName: event.level.glyph)
                            .font(Theme.ui(9)).foregroundStyle(event.level.tint).frame(width: 14)
                        Text(event.text).font(Theme.ui(12)).foregroundStyle(event.level.tint)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var glossary: some View {
        let sorted = terms.terms.sorted { $0.term.localizedStandardCompare($1.term) == .orderedAscending }
        return LazyVStack(alignment: .leading, spacing: 8) {
            if sorted.isEmpty { empty("No glossary terms for this simulator", icon: "text.book.closed") }
            ForEach(Array(sorted.enumerated()), id: \.offset) { _, term in
                SimTermAnchor(term: term, model: model, index: terms) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(term.term).font(Theme.ui(12, .semibold)).foregroundStyle(Theme.accent)
                        Text(term.short).font(Theme.ui(12)).foregroundStyle(Theme.muted)
                            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "pin").font(Theme.ui(10)).foregroundStyle(Theme.muted)
                    }
                    .padding(9).card()
                }
            }
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(sim.manifest.title).font(Theme.heading).foregroundStyle(Theme.text)
            if let summary = sim.manifest.summary {
                SimMarkdown(source: summary, model: model, terms: terms)
            }
            if let notes = sim.manifest.notes {
                SimMarkdown(source: notes, model: model, terms: terms)
            }
            ForEach(sim.manifest.links, id: \.self) { link in
                SimButton(title: link.label, icon: "arrow.up.right") { actions.open(link) }
            }
        }
        .frame(maxWidth: 660, alignment: .leading)
    }

    private func empty(_ message: String, icon: String) -> some View {
        Label(message, systemImage: icon).font(Theme.ui(12)).foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
    }
}

private extension LogEntry.Level {
    var tint: Color {
        switch self {
        case .info: Theme.text
        case .good: Theme.good
        case .warn: Theme.warn
        case .bad: Theme.bad
        }
    }

    var glyph: String {
        switch self {
        case .info: "circle.fill"
        case .good: "checkmark"
        case .warn: "exclamationmark.triangle"
        case .bad: "xmark.circle"
        }
    }
}
