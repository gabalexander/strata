import AppKit
import SwiftUI
import StrataCore

/// The dock's Ask tab (docs/design.md, Ask): a question field, the answer streaming with links into
/// the map, suggested questions, and the map's earlier questions.
@MainActor
struct SimAskTab: View {
    let sim: Simulation
    let model: AppModel
    let selection: StageSelection?
    let still: Bool
    let select: (StageSelection?) -> Void
    @State private var focused = false

    private var state: SimAskState { SimAskState.of(model, manifest: sim.manifest.id) }

    private var focus: AskFocus {
        switch selection {
        case .node(let id): AskFocus(path: sim.path, node: id)
        case .flow(let id): AskFocus(path: sim.path, flow: id)
        case .edge, nil: AskFocus(path: sim.path)
        }
    }

    var body: some View {
        let state = state
        VStack(spacing: 0) {
            if state.enabled {
                field(state)
                Rectangle().fill(Theme.border).frame(height: 1)
                SimPanelScroll(still: still) {
                    content(state)
                        .frame(maxWidth: 1100, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                }
            } else {
                off(state)
            }
        }
        .onAppear {
            state.loadHistory()
            takeFocus(state)
        }
        .onChange(of: state.focusRequest) { _, _ in takeFocus(state) }
    }

    private func takeFocus(_ state: SimAskState) {
        guard state.focusRequest > state.focusHandled else { return }
        state.focusHandled = state.focusRequest
        focused = true
    }

    private func submit(_ text: String? = nil) {
        state.ask(text ?? state.question, manifest: sim.manifest, focus: focus, config: model.config.ask)
        focused = true
    }

    private func navigate(_ target: AskTarget) {
        SimAskNav.open(target, sim: sim, model: model, select: select)
    }

    // MARK: Field

    private func field(_ state: SimAskState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle.magnifyingglass").font(Theme.ui(13, .medium)).foregroundStyle(Theme.accent)
            StrataTextField(placeholder: "Ask about this map: what breaks, who writes a column, why a status sticks…",
                            text: SwiftUI.Binding(get: { state.question }, set: { state.question = $0 }),
                            focused: $focused, overlays: model.overlays, placeholderColor: Theme.faint,
                            onSubmit: { submit() })
                .frame(maxWidth: .infinity)
            if !focused, state.question.isEmpty {
                Text(SimAskHooks.shortcut).font(Theme.mono(10)).foregroundStyle(Theme.faint)
            }
            if state.running {
                SimButton(title: "Stop", icon: "stop.fill", active: true) { state.stop() }
            } else {
                SimButton(title: "Ask", icon: "arrow.up") { submit() }
                    .disabled(state.question.trimmingCharacters(in: .whitespaces).isEmpty)
                    .opacity(state.question.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            }
        }
        .padding(.leading, 10).padding(.trailing, 4)
        .frame(height: 34)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Theme.accent.opacity(0.45) : Theme.border))
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: Content

    /// One column before the first question. With an answer on screen and room to spare, the answer
    /// takes the left and the suggestions and earlier questions sit beside it.
    @ViewBuilder
    private func content(_ state: SimAskState) -> some View {
        if let exchange = state.current {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    main(exchange, state: state).frame(minWidth: 480, maxWidth: 720, alignment: .leading)
                    side(state).frame(width: 280, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 12) {
                    main(exchange, state: state)
                    side(state)
                }
                .frame(maxWidth: 760, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if state.needsNotice { notice(state) }
                suggestions(state)
                if !state.earlier.isEmpty { earlier(state) }
            }
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private func main(_ exchange: SimAskState.Exchange, state: SimAskState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.needsNotice { notice(state) }
            self.exchange(exchange, state: state)
        }
    }

    private func side(_ state: SimAskState) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if state.current?.running != true { suggestions(state) }
            if !state.earlier.isEmpty { earlier(state) }
        }
    }

    private func notice(_ state: SimAskState) -> some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: "lock.shield").font(Theme.ui(12)).foregroundStyle(Theme.warn)
            Text("Asking sends your question and this map to Claude under your own Claude Code account; it leaves this Mac.")
                .font(Theme.ui(12)).foregroundStyle(Theme.muted).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            SimButton(title: "Got it") { state.acknowledge() }
            SimButton(title: "Turn Ask off", icon: "power") { state.setEnabled(false) }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.warn.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(Theme.warn.opacity(0.22)))
    }

    private func exchange(_ exchange: SimAskState.Exchange, state: SimAskState) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(exchange.question).font(Theme.ui(13, .semibold)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                meta(exchange)
                if exchange.phase == .done, !exchange.answer.isEmpty {
                    SimButton(title: "Copy answer", icon: "doc.on.doc", iconOnly: true) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(exchange.answer, forType: .string)
                        model.overlays.toast("Copied the answer")
                    }
                }
            }
            if !exchange.answer.isEmpty {
                SimAskMarkdown(text: exchange.answer, manifest: sim.manifest, open: navigate)
            }
            switch exchange.phase {
            case .starting, .streaming:
                HStack(spacing: 7) {
                    Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(Theme.accent)
                        .symbolEffect(.pulse, isActive: !still)
                    Text(exchange.activity ?? (exchange.answer.isEmpty ? "Thinking…" : "Writing…"))
                        .font(Theme.ui(11)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            case .stopped:
                Text("Stopped.").font(Theme.ui(11)).foregroundStyle(Theme.faint)
            case .failed(let failure):
                self.failure(failure, question: exchange.question, state: state)
            case .done:
                EmptyView()
            }
        }
        .padding(12)
        .card()
    }

    @ViewBuilder
    private func meta(_ exchange: SimAskState.Exchange) -> some View {
        let model = exchange.model.map(Self.shortModel)
        if exchange.running, !still {
            TimelineView(.periodic(from: exchange.started, by: 1)) { context in
                metaText(model, seconds: context.date.timeIntervalSince(exchange.started))
            }
        } else {
            metaText(model, seconds: exchange.seconds)
        }
    }

    private func metaText(_ model: String?, seconds: Double?) -> some View {
        let parts = [model, seconds.map { "\(Int($0.rounded())) s" }].compactMap { $0 }
        return Text(parts.joined(separator: " · ")).font(Theme.mono(10)).foregroundStyle(Theme.faint).lineLimit(1).fixedSize()
    }

    /// "claude-haiku-5-5" → "haiku 5.5".
    static func shortModel(_ id: String) -> String {
        let parts = id.split(separator: "-").map(String.init)
        guard parts.first == "claude", parts.count >= 2 else { return id }
        let name = parts[1]
        let version = parts.dropFirst(2).prefix { $0.allSatisfy(\.isNumber) && $0.count <= 2 }
        return version.isEmpty ? name : "\(name) \(version.joined(separator: "."))"
    }

    private func failure(_ failure: AskFailure, question: String, state: SimAskState) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: failure == .disabled ? "power" : "exclamationmark.circle")
                .font(Theme.ui(13)).foregroundStyle(Theme.warn)
            VStack(alignment: .leading, spacing: 6) {
                Text(failure.title).font(Theme.ui(12, .semibold)).foregroundStyle(Theme.text)
                SimAskMarkdown(text: failure.message, manifest: sim.manifest, size: 12, color: Theme.muted, open: navigate)
                SimButton(title: "Try again", icon: "arrow.clockwise") { submit(question) }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warn.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(Theme.warn.opacity(0.18)))
    }

    private func suggestions(_ state: SimAskState) -> some View {
        let questions = AskSuggestions.make(sim.manifest, focus: focus)
        return Group {
            if !questions.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text(state.current == nil ? "Try asking" : "Ask next").font(Theme.label).foregroundStyle(Theme.muted)
                    SimAskFlow(spacing: 6) {
                        ForEach(questions, id: \.self) { question in
                            SimAskChip(title: question) { submit(question) }
                        }
                    }
                }
            }
        }
    }

    private func earlier(_ state: SimAskState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Earlier").font(Theme.label).foregroundStyle(Theme.muted)
                Spacer()
                Button { state.clearHistory() } label: {
                    Label("Clear history", systemImage: "trash").font(Theme.ui(11)).foregroundStyle(Theme.faint)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Deletes this map's questions and answers from ~/.strata/ask")
            }
            ForEach(state.earlier) { record in
                let open = state.expanded.contains(record.id)
                VStack(alignment: .leading, spacing: 6) {
                    Button { state.toggle(record.id) } label: {
                        HStack(spacing: 7) {
                            Image(systemName: open ? "chevron.down" : "chevron.right")
                                .font(Theme.ui(9, .semibold)).foregroundStyle(Theme.faint).frame(width: 10)
                            Text(record.question).font(Theme.ui(12)).foregroundStyle(open ? Theme.text : Theme.muted).lineLimit(1)
                            if record.status != .done {
                                Text(record.status == .stopped ? "stopped" : record.error ?? "failed")
                                    .font(Theme.ui(10)).foregroundStyle(Theme.faint).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Text(Self.relative(record.date)).font(Theme.mono(10)).foregroundStyle(Theme.faint)
                        }
                        .frame(height: 22)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if open, !record.answer.isEmpty {
                        SimAskMarkdown(text: record.answer, manifest: sim.manifest, size: 12, open: navigate)
                            .padding(.leading, 17).padding(.bottom, 6)
                    }
                }
            }
        }
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: Off

    private func off(_ state: SimAskState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Ask is off", systemImage: "sparkle.magnifyingglass").font(Theme.ui(13, .semibold)).foregroundStyle(Theme.text)
            Text("Turned on, Ask sends your question and this map to Claude through your own Claude Code account, "
                 + "and answers with links into the map. Nothing is sent while it is off.")
                .font(Theme.ui(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            SimButton(title: "Turn Ask on", icon: "power") { state.setEnabled(true) }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
    }
}

@MainActor
private struct SimAskChip: View {
    let title: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.ui(12))
                .foregroundStyle(hovered ? Theme.text : Theme.muted)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(hovered ? Theme.hover : Theme.raised, in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(hovered ? Theme.borderStrong : Theme.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// Lays chips out in rows, wrapping when the next one doesn't fit.
private struct SimAskFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
                x += min(size.width, bounds.width) + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let itemWidth = min(size.width, width)
            if !row.items.isEmpty, row.width + spacing + itemWidth > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.items.isEmpty ? 0 : spacing) + itemWidth
            row.height = max(row.height, size.height)
            row.items.append(index)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
