import SwiftUI
import StrataCore

// The mechanism player (docs/manifest.md, How it works): a large panel inside the window, over the
// stage and dock, with the sequence diagram, the state after the current step, playback controls,
// branch chips and the step's note. Never a system window: it is a view in the sim screen.

/// Laid over the stage column: draws nothing until a mechanism is open.
@MainActor
struct SimHowHost: View {
    let model: AppModel
    let sim: Simulation
    let terms: TermIndex
    let actions: SimActions
    let select: (StageSelection?) -> Void
    var still = false

    var body: some View {
        let state = SimHowState.of(sim)
        ZStack {
            if let player = state.player {
                Theme.bg.opacity(0.62)
                    .contentShape(Rectangle())
                    .onTapGesture { state.close() }
                    .accessibilityHidden(true)
                SimHowPanel(model: model, sim: sim, terms: terms, actions: actions, player: player, select: select,
                            close: state.close, still: still)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .id(ObjectIdentifier(player))
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
        }
        .animation(still ? nil : Theme.snappy, value: state.player.map(ObjectIdentifier.init))
    }
}

@MainActor
struct SimHowPanel: View {
    let model: AppModel
    let sim: Simulation
    let terms: TermIndex
    let actions: SimActions
    let player: SimHowPlayer
    let select: (StageSelection?) -> Void
    let close: () -> Void
    var still = false

    var body: some View {
        let colors = keyColors
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.border).frame(height: 1)
            if !player.mechanism.branches.isEmpty {
                branches
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            GeometryReader { proxy in
                let stateWidth = min(318, max(240, proxy.size.width * 0.3))
                HStack(spacing: 0) {
                    SimHowDiagram(player: player, sim: sim, keyColors: colors, select: select, still: still)
                        .frame(width: max(0, proxy.size.width - stateWidth - 1))
                    Rectangle().fill(Theme.border).frame(width: 1)
                    SimHowStatePanel(player: player, keyColors: colors, still: still)
                        .frame(width: stateWidth)
                }
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            SimHowTransport(player: player, still: still)
            Rectangle().fill(Theme.border).frame(height: 1)
            SimHowNotes(model: model, terms: terms, player: player)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.borderStrong))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
        .contentShape(Rectangle())
        .onTapGesture {}   // taps inside the panel never reach the backdrop
    }

    /// One colour per key, in the order keys first appear on the path.
    private var keyColors: [String: Color] {
        var order: [String] = player.playback.initial.map(\.key)
        for frame in player.playback.frames {
            for key in frame.state.map(\.key) + frame.changes.map(\.key) where !order.contains(key) { order.append(key) }
        }
        let palette = [Theme.token(5), Theme.token(1), Theme.token(3), Theme.token(2), Theme.token(4), Theme.token(6)]
        return Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, palette[$0 % palette.count]) })
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: "arrow.left.arrow.right")
                .font(Theme.ui(14, .semibold)).foregroundStyle(Theme.accent)
                .frame(width: 32, height: 32)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("How it works").font(Theme.ui(11, .semibold)).foregroundStyle(Theme.accent)
                    Text("·").foregroundStyle(Theme.faint)
                    Button { select(.node(player.ref.node)) } label: {
                        Text(ownerTitle).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Select it on the stage")
                }
                Text(player.mechanism.title).font(Theme.ui(16, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
            }
            Spacer(minLength: 12)
            stats
            ForEach(player.mechanism.code, id: \.self) { path in
                SimButton(title: (path as NSString).lastPathComponent, icon: "chevron.left.forwardslash.chevron.right") {
                    actions.openCode(path)
                }
            }
            HStack(spacing: 6) {
                StrataKeycap("esc")
                SimButton(title: "Close", icon: "xmark", iconOnly: true, action: close)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
    }

    private var ownerTitle: String {
        let node = sim.level.node(player.ref.node)?.label ?? player.ref.node
        guard let op = player.ref.op else { return node }
        return "\(node) › " + (sim.level.node(player.ref.node)?.ops.first { $0.id == op }?.label ?? op)
    }

    private var stats: some View {
        let mechanism = player.mechanism
        var parts = ["\(mechanism.participants.count) participants", "\(mechanism.steps.count) steps"]
        if !mechanism.branches.isEmpty { parts.append("\(mechanism.branches.count) branch\(mechanism.branches.count == 1 ? "" : "es")") }
        return Text(parts.joined(separator: " · ")).font(Theme.ui(11)).foregroundStyle(Theme.faint).lineLimit(1)
    }

    /// The paths: the main sequence and each branch. Details drop first when the row is narrow, then it scrolls.
    private var branches: some View {
        HStack(spacing: 6) {
            Text("Path").font(Theme.ui(11, .semibold)).foregroundStyle(Theme.muted).padding(.trailing, 4)
            ViewThatFits(in: .horizontal) {
                chips(details: true)
                chips(details: false)
                ScrollView(.horizontal) { chips(details: false) }.scrollIndicators(.hidden)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
    }

    private func chips(details: Bool) -> some View {
        HStack(spacing: 6) {
            SimHowBranchChip(title: "Main sequence", detail: details ? "\(player.mechanism.steps.count) steps" : nil,
                             icon: "arrow.down", selected: player.branch == nil) { player.choose(branch: nil) }
            ForEach(player.mechanism.branches) { branch in
                let index = branch.after.flatMap { after in player.mechanism.steps.firstIndex { $0.id == after } }
                SimHowBranchChip(title: branch.label, detail: details ? index.map { "from step \($0 + 1)" } ?? "from the start" : nil,
                                 icon: "arrow.turn.down.right", selected: player.branch == branch.id) {
                    player.choose(branch: branch.id)
                }
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

@MainActor
private struct SimHowBranchChip: View {
    let title: String
    let detail: String?
    let icon: String
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(Theme.ui(9.5, .semibold))
                Text(title).font(Theme.ui(11.5, .medium)).lineLimit(1)
                if let detail {
                    Text(detail).font(Theme.ui(10)).foregroundStyle(selected ? Theme.accent.opacity(0.7) : Theme.faint).lineLimit(1)
                }
            }
            .foregroundStyle(selected ? Theme.accent : hovered ? Theme.text : Theme.muted)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(selected ? Theme.accent.opacity(0.13) : hovered ? Theme.hover : Theme.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Theme.accent.opacity(0.45) : Theme.border))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Keys and values after the current step. TTL bars drain while the clock runs; changed rows flash;
/// keys that expired or were deleted stay a moment, struck through.
@MainActor
struct SimHowStatePanel: View {
    let player: SimHowPlayer
    let keyColors: [String: Color]
    var still = false

    var body: some View {
        TimelineView(.animation(paused: !player.playing || still)) { tick in
            let position = player.position(at: tick.date)
            content(position)
        }
    }

    private func content(_ position: Double) -> some View {
        let playback = player.playback
        let schedule = player.schedule
        let k = Int(floor(min(schedule.end, max(-1, position)) + 1e-9))
        let now = schedule.time(at: position)
        let state = playback.state(after: k, at: now)
        let frame = k >= 0 ? playback.frames[k] : nil
        let since = schedule.sinceLanding(at: position)
        let flash = max(0, 1 - since / 1.1)
        var gone: [(key: String, kind: MechChange.Kind)] = state.expired.map { ($0, .expire) }
        for change in frame?.changes ?? [] where change.kind == .delete || change.kind == .expire {
            if !gone.contains(where: { $0.key == change.key }) { gone.append((change.key, change.kind)) }
        }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("State").font(Theme.ui(12, .semibold)).foregroundStyle(Theme.text)
                Text(k < 0 ? "before step 1" : "after step \(k + 1)").font(Theme.ui(11)).foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
                if playback.timed {
                    Text(SimHowFormat.clock(now, short: playback.duration < 1)).font(Theme.mono(11, .medium)).foregroundStyle(Theme.accent).monospacedDigit()
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            Rectangle().fill(Theme.border).frame(height: 1)
            if state.keys.isEmpty && gone.isEmpty {
                Text("No state yet.").font(Theme.ui(12)).foregroundStyle(Theme.faint).padding(14)
            }
            let rows = VStack(alignment: .leading, spacing: 4) {
                ForEach(state.keys, id: \.key) { key in
                    let change = frame?.change(of: key.key)
                    SimHowStateRow(key: key.key, value: key.value, ttl: key.ttl, remaining: key.remaining,
                                   color: keyColors[key.key] ?? Theme.muted, change: change, flash: change == nil ? 0 : flash)
                }
                ForEach(gone, id: \.key) { item in
                    SimHowStateRow(key: item.key, value: nil, ttl: nil, remaining: nil, color: keyColors[item.key] ?? Theme.muted,
                                   change: item.kind, flash: flash, fade: 1 - 0.55 * min(1, since / 0.8))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            if still {
                rows
                Spacer(minLength: 0)
            } else {
                ScrollView { rows }.scrollBounceBehavior(.basedOnSize)
            }
            if state.keys.contains(where: { $0.ttl != nil }) || !gone.isEmpty {
                legend.padding(.horizontal, 14).padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var legend: some View {
        HStack(spacing: 6) {
            Image(systemName: "hourglass").font(Theme.ui(10)).foregroundStyle(Theme.faint)
            Text("Bars drain as the clock runs; a renewal refills them. At zero the key is gone.")
                .font(Theme.ui(10.5)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor
private struct SimHowStateRow: View {
    let key: String
    let value: String?
    let ttl: Double?
    let remaining: Double?
    let color: Color
    let change: MechChange.Kind?
    let flash: Double
    var fade: Double = 1

    var body: some View {
        let gone = value == nil
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle().fill(color).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text(key).font(Theme.mono(11.5, .medium)).foregroundStyle(Theme.text)
                    .strikethrough(gone, color: Theme.bad.opacity(0.8))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                if let tag { tagView(tag) }
                if let value {
                    Text(value).font(Theme.mono(11.5)).foregroundStyle(Theme.text.opacity(0.86))
                        .lineLimit(2).multilineTextAlignment(.trailing)
                }
            }
            if let ttl, let remaining {
                HStack(spacing: 8) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.borderStrong)
                            Capsule().fill(barColor(remaining)).frame(width: max(2, proxy.size.width * remaining))
                        }
                    }
                    .frame(height: 4)
                    Text("ttl " + SimHowFormat.ttl(ttl))
                        .font(Theme.mono(10.5, .medium)).foregroundStyle(barColor(remaining)).monospacedDigit()
                        .frame(width: 62, alignment: .trailing)
                }
                .padding(.leading, 13)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(background, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(flash > 0.02 ? tint.opacity(0.35 * flash) : Color.clear))
        .opacity(fade)
    }

    private var tag: String? {
        switch change {
        case .set?: "set"
        case .renew?: "renewed"
        case .delete?: "deleted"
        case .expire?: "expired"
        case nil: nil
        }
    }

    private var tint: Color {
        switch change {
        case .set?: Theme.accent
        case .renew?: Theme.good
        case .delete?, .expire?: Theme.bad
        case nil: Theme.muted
        }
    }

    private var background: Color {
        if flash > 0.02 { return tint.opacity(0.05 + 0.12 * flash) }
        return Theme.raised.opacity(0.6)
    }

    private func tagView(_ text: String) -> some View {
        Text(text).font(Theme.ui(9.5, .semibold)).foregroundStyle(tint)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(tint.opacity(0.13), in: Capsule())
    }

    private func barColor(_ remaining: Double) -> Color {
        remaining > 0.5 ? Theme.good : remaining > 0.25 ? Theme.warn : Theme.bad
    }
}

/// Restart, step back, play or pause, step forward, the scrubber and the clock.
@MainActor
struct SimHowTransport: View {
    let player: SimHowPlayer
    var still = false

    var body: some View {
        HStack(spacing: 8) {
            SimButton(title: "Restart", icon: "backward.end.fill", iconOnly: true) { player.restart() }
            SimButton(title: "Step back", icon: "backward.frame.fill", iconOnly: true) { player.step(-1) }
            SimButton(title: player.playing ? "Pause" : "Play", icon: player.playing ? "pause.fill" : "play.fill",
                      iconOnly: true, active: player.playing) { player.toggle() }
            SimButton(title: "Step forward", icon: "forward.frame.fill", iconOnly: true) { player.step(1) }
            TimelineView(.animation(paused: !player.playing || still)) { tick in
                let position = player.position(at: tick.date)
                HStack(spacing: 10) {
                    SimHowScrubber(player: player, position: position)
                    readout(position)
                }
            }
            SimSegments(values: [0.5, 1, 2, 4], selected: player.speed, label: speedLabel) { player.speed = $0 }
                .accessibilityLabel("Playback speed")
            HStack(spacing: 3) {
                StrataKeycap("space")
                StrataKeycap("←")
                StrataKeycap("→")
            }
            .opacity(0.8)
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    private func readout(_ position: Double) -> some View {
        let count = player.playback.frames.count
        let current = player.schedule.current(at: position)
        return HStack(spacing: 8) {
            if player.playback.timed {
                Text("t = " + SimHowFormat.clock(player.schedule.time(at: position), short: player.playback.duration < 1))
                    .font(Theme.mono(11, .medium)).foregroundStyle(Theme.text).monospacedDigit()
            }
            Text(current < 0 ? "start" : "step \(current + 1)/\(count)")
                .font(Theme.mono(11)).foregroundStyle(Theme.muted).monospacedDigit()
        }
        .frame(width: player.playback.timed ? 148 : 70, alignment: .trailing)
    }

    private func speedLabel(_ speed: Double) -> String { speed == 0.5 ? "½×" : SimFormat.number(speed) + "×" }
}

@MainActor
private struct SimHowScrubber: View {
    let player: SimHowPlayer
    let position: Double

    var body: some View {
        GeometryReader { proxy in
            let count = max(1, player.playback.frames.count)
            let inset: CGFloat = 7
            let width = max(1, proxy.size.width - inset * 2)
            let x = { (p: Double) -> CGFloat in inset + width * CGFloat((p + 1) / Double(count)) }
            let mid = proxy.size.height / 2
            ZStack(alignment: .topLeading) {
                Capsule().fill(Theme.borderStrong).frame(width: width, height: 3).offset(x: inset, y: mid - 1.5)
                if let start = player.playback.branchStart {
                    Capsule().fill(Theme.warn.opacity(0.45))
                        .frame(width: max(0, x(Double(count - 1)) - x(Double(start) - 1)), height: 3)
                        .offset(x: x(Double(start) - 1), y: mid - 1.5)
                }
                Capsule().fill(Theme.accent.opacity(0.85)).frame(width: max(0, x(position) - inset), height: 3)
                    .offset(x: inset, y: mid - 1.5)
                ForEach(0..<count, id: \.self) { index in
                    let done = Double(index) <= position + 1e-9
                    Circle()
                        .fill(done ? Theme.accent : Theme.raised)
                        .overlay(Circle().strokeBorder(done ? Theme.accent : Theme.borderStrong, lineWidth: 1))
                        .frame(width: 7, height: 7)
                        .position(x: x(Double(index)), y: mid)
                }
                Circle().fill(Theme.text).frame(width: 11, height: 11)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .position(x: x(position), y: mid)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                let fraction = Double((event.location.x - inset) / width)
                let target = (fraction * Double(count) - 1).rounded()
                if player.playing { player.pause() }
                player.seek(to: min(Double(count - 1), max(-1, target)))
            })
        }
        .frame(height: 22)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("step \(max(0, player.schedule.current(at: position)) + 1)")
    }
}

/// The current step's note (markdown with glossary links), or the summary before the first step.
@MainActor
struct SimHowNotes: View {
    let model: AppModel
    let terms: TermIndex
    let player: SimHowPlayer

    var body: some View {
        let frames = player.playback.frames
        let index = player.shown
        HStack(alignment: .top, spacing: 12) {
            if index >= 0, index < frames.count {
                let frame = frames[index]
                VStack(alignment: .leading, spacing: 4) {
                    Text("STEP \(index + 1)").font(Theme.mono(10, .semibold)).foregroundStyle(Theme.accent)
                    Text(SimHowFormat.time(frame.time)).font(Theme.mono(10)).foregroundStyle(Theme.faint)
                        .opacity(player.playback.timed ? 1 : 0)
                }
                .frame(width: 52, alignment: .leading)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(frame.step.label).font(Theme.ui(13, .semibold)).foregroundStyle(Theme.text)
                        Text("\(name(frame.step.from)) → \(name(frame.step.to))").font(Theme.ui(11)).foregroundStyle(Theme.muted)
                        if frame.branch != nil, index == player.playback.branchStart {
                            SimPill(title: player.playback.branch?.label ?? "branch", icon: "arrow.turn.down.right", tint: Theme.warn)
                        }
                    }
                    if let note = frame.step.note ?? (index == player.playback.branchStart ? player.playback.branch?.note : nil) {
                        SimMarkdown(source: note, model: model, terms: terms, color: Theme.text.opacity(0.86), size: 13)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("START").font(Theme.mono(10, .semibold)).foregroundStyle(Theme.accent)
                }
                .frame(width: 52, alignment: .leading)
                if let summary = player.mechanism.summary {
                    SimMarkdown(source: summary, model: model, terms: terms, color: Theme.text.opacity(0.86), size: 13)
                } else {
                    Text("Press play or → to take the first step.").font(Theme.ui(13)).foregroundStyle(Theme.muted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
    }

    private func name(_ id: String) -> String { player.mechanism.participants.first { $0.id == id }?.label ?? id }
}
