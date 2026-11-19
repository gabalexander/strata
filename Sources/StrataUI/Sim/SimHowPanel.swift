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
                GeometryReader { proxy in
                    SimHowPanel(model: model, sim: sim, terms: terms, actions: actions, player: player, select: select,
                                close: state.close, width: max(0, proxy.size.width - 28), still: still)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }
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
    /// The panel's width, which decides how many path chips fit on their two lines.
    var width: CGFloat = 1000
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
                // The step detail takes the state panel's place, a little wider: commands read better there.
                let side = player.inspecting ? Self.detailWidth(proxy.size.width) : Self.stateWidth(proxy.size.width)
                HStack(spacing: 0) {
                    SimHowDiagram(player: player, sim: sim, keyColors: colors, select: select, still: still)
                        .frame(width: max(0, proxy.size.width - side - 1))
                    Rectangle().fill(Theme.border).frame(width: 1)
                    Group {
                        if player.inspecting {
                            SimHowStepDetail(model: model, sim: sim, terms: terms, actions: actions, player: player, keyColors: colors,
                                             select: select, still: still)
                        } else {
                            SimHowStatePanel(player: player, keyColors: colors, width: side, still: still)
                        }
                    }
                    .frame(width: side)
                }
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            SimHowTransport(player: player, still: still)
            if !player.inspecting {
                // The step detail shows the note in full, so the strip steps aside while it is open.
                Rectangle().fill(Theme.border).frame(height: 1)
                SimHowNotes(model: model, terms: terms, player: player)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.borderStrong))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
        .contentShape(Rectangle())
        .onTapGesture {}   // taps inside the panel never reach the backdrop
    }

    static func stateWidth(_ width: CGFloat) -> CGFloat { min(318, max(240, width * 0.3)) }
    static func detailWidth(_ width: CGFloat) -> CGFloat { min(460, max(320, width * 0.4)) }

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
                    Text("How it works").font(Theme.ui(11, .semibold)).foregroundStyle(Theme.accent).fixedSize()
                    Text("·").foregroundStyle(Theme.faint)
                    Button { select(sim.level.node(player.ref.node) == nil ? nil : .node(player.ref.node)) } label: {
                        Text(ownerTitle).font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Select it on the stage")
                }
                Text(player.mechanism.title).font(Theme.ui(16, .semibold)).foregroundStyle(Theme.text)
                    .lineLimit(2).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            ViewThatFits(in: .horizontal) {
                stats(long: true)
                stats(long: false)
                Color.clear.frame(width: 0, height: 0)
            }
            ForEach(player.mechanism.code, id: \.self) { path in
                SimButton(title: (path as NSString).lastPathComponent, icon: "chevron.left.forwardslash.chevron.right") {
                    actions.openCode(path)
                }
                .fixedSize()
            }
            HStack(spacing: 6) {
                StrataKeycap("esc")
                SimButton(title: "Close", icon: "xmark", iconOnly: true, action: close)
            }
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 58)
    }

    private var ownerTitle: String {
        // `..`: an op of the node this deep dive is inside (InheritedOps).
        let owner = player.ref.node == InheritedOps.ownerKey ? SimOpsState.of(sim).index.inheritance?.owner : sim.level.node(player.ref.node)
        let node = owner?.label ?? player.ref.node
        guard let op = player.ref.op else { return node }
        return "\(node) › " + (owner?.ops.first { $0.id == op }?.label ?? op)
    }

    private func stats(long: Bool) -> some View {
        let mechanism = player.mechanism
        var parts = long ? ["\(mechanism.participants.count) participants", "\(mechanism.steps.count) steps"] : ["\(mechanism.steps.count) steps"]
        if long, !mechanism.branches.isEmpty { parts.append("\(mechanism.branches.count) branch\(mechanism.branches.count == 1 ? "" : "es")") }
        return Text(parts.joined(separator: " · ")).font(Theme.ui(11)).foregroundStyle(Theme.faint).lineLimit(1).fixedSize()
    }

    /// The paths: the main sequence and each branch, on one line with where each leaves. When they don't
    /// fit, without that, on up to two lines; the branches past those wait behind "+N more", a menu
    /// (the chosen one always shows).
    private var branches: some View {
        let paths = self.paths
        let line = width - 28 - 36
        let withDetails = paths.reduce(0) { $0 + Self.chipWidth($1.title, detail: $1.detail) + 6 } - 6
        let selected = paths.firstIndex { $0.selected }
        let shown = withDetails <= line ? Array(paths.indices)
            : SequenceGeometry.fitChips(paths.map { Double(Self.chipWidth($0.title, detail: nil)) }, lineWidth: Double(line), maxLines: 2,
                                        spacing: 6, more: { Double(Self.chipWidth("+\($0) more", detail: nil)) }, keep: selected)
        let hidden = paths.indices.filter { !shown.contains($0) }
        return HStack(alignment: .top, spacing: 6) {
            Text("Path").font(Theme.ui(11, .semibold)).foregroundStyle(Theme.muted).padding(.trailing, 4).frame(height: 26)
            Group {
                if withDetails <= line {
                    HStack(spacing: 6) { ForEach(paths.indices, id: \.self) { chip(paths[$0], details: true) } }
                } else {
                    SimOpsChips {
                        ForEach(shown, id: \.self) { chip(paths[$0], details: false) }
                        if !hidden.isEmpty {
                            SimHowMoreChip(count: hidden.count, overlays: model.overlays) {
                                hidden.map { index in
                                    let path = paths[index]
                                    return MenuItem(path.title, icon: "arrow.turn.down.right", shortcut: path.detail, checked: path.selected) {
                                        player.choose(branch: path.id)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private struct PathChip {
        let id: String?
        let title: String
        let detail: String
        let icon: String
        let selected: Bool
    }

    private var paths: [PathChip] {
        let mechanism = player.mechanism
        return [PathChip(id: nil, title: "Main sequence", detail: "\(mechanism.steps.count) steps", icon: "arrow.down", selected: player.branch == nil)]
            + mechanism.branches.map { branch in
                let index = branch.after.flatMap { after in mechanism.steps.firstIndex { $0.id == after } }
                return PathChip(id: branch.id, title: branch.label, detail: index.map { "from step \($0 + 1)" } ?? "from the start",
                                icon: "arrow.turn.down.right", selected: player.branch == branch.id)
            }
    }

    private func chip(_ path: PathChip, details: Bool) -> some View {
        SimHowBranchChip(title: path.title, detail: details ? path.detail : nil, icon: path.icon, selected: path.selected) {
            player.choose(branch: path.id)
        }
    }

    private static let chipTitle = NSFont.systemFont(ofSize: 11.5, weight: .medium)
    private static let chipDetail = NSFont.systemFont(ofSize: 10)

    /// A path chip's width: insets, icon and spacing, the title, and the detail after it.
    static func chipWidth(_ title: String, detail: String?) -> CGFloat {
        20 + 11 + 6 + SimHowMeasure.width(title, chipTitle) + (detail.map { 6 + SimHowMeasure.width($0, chipDetail) } ?? 0) + 2
    }
}

/// "+3 more": the paths that didn't fit, as an in-window menu under the chip.
@MainActor
private struct SimHowMoreChip: View {
    let count: Int
    let overlays: Overlays
    let items: () -> [MenuItem]
    @State private var hovered = false
    @State private var frame: CGRect = .zero

    var body: some View {
        Button { overlays.showMenu(items(), at: CGPoint(x: frame.minX, y: frame.maxY + 4)) } label: {
            HStack(spacing: 5) {
                Text("+\(count) more").font(Theme.ui(11.5, .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(Theme.ui(8.5, .semibold))
            }
            .foregroundStyle(hovered ? Theme.text : Theme.muted)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(hovered ? Theme.hover : Theme.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.border))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame = $0 }
        .accessibilityLabel("\(count) more paths")
    }
}

@MainActor
struct SimHowBranchChip: View {
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
                Text(title).font(Theme.ui(11.5, .medium)).lineLimit(1).truncationMode(.tail)
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
/// keys that expired or were deleted stay a moment, struck through. A long key is cut in the middle
/// between its segments (`app:…:nightly-sweep`) and a long value at its end; a click on such a row
/// shows all of it.
@MainActor
struct SimHowStatePanel: View {
    let player: SimHowPlayer
    let keyColors: [String: Color]
    /// The panel's width, which decides how much of a key fits.
    var width: CGFloat = 318
    var still = false
    @State private var expanded: Set<String> = []

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
                Text(k < 0 ? "before step 1" : "after step \(k + 1)").font(Theme.ui(11)).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer(minLength: 0)
                if playback.timed {
                    Text(SimHowFormat.clock(now, short: playback.duration < 1)).font(Theme.mono(11, .medium)).foregroundStyle(Theme.accent)
                        .monospacedDigit().fixedSize()
                }
                SimHowLinkButton(title: "Step", icon: "sidebar.right") { player.inspect(player.shown) }
                    .accessibilityLabel("Open the step detail")
            }
            .padding(.leading, 14).padding(.trailing, 8)
            .frame(height: 40)
            Rectangle().fill(Theme.border).frame(height: 1)
            if state.keys.isEmpty && gone.isEmpty {
                Text("No state yet.").font(Theme.ui(12)).foregroundStyle(Theme.faint).padding(14)
            }
            let rows = VStack(alignment: .leading, spacing: 4) {
                ForEach(state.keys, id: \.key) { key in
                    let change = frame?.change(of: key.key)
                    SimHowStateRow(key: key.key, value: key.value, ttl: key.ttl, remaining: key.remaining,
                                   color: keyColors[key.key] ?? Theme.muted, change: change, flash: change == nil ? 0 : flash,
                                   width: width, expanded: expanded.contains(key.key)) { toggle(key.key) }
                }
                ForEach(gone, id: \.key) { item in
                    SimHowStateRow(key: item.key, value: nil, ttl: nil, remaining: nil, color: keyColors[item.key] ?? Theme.muted,
                                   change: item.kind, flash: flash, fade: 1 - 0.55 * min(1, since / 0.8),
                                   width: width, expanded: expanded.contains(item.key)) { toggle(item.key) }
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

    private func toggle(_ key: String) {
        if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
    }

    private var legend: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
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
    let width: CGFloat
    let expanded: Bool
    let toggle: () -> Void
    @State private var hovered = false

    static let keyAdvance = SimHowMeasure.advance(NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium))
    static let valueAdvance = SimHowMeasure.advance(NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular))

    var body: some View {
        let gone = value == nil
        // Row insets: the list's 8 + the row's 8 each side, the dot and its spacing, the tag and the chevron.
        let tagRoom: CGFloat = tag.map { CGFloat($0.count) * 6 + 18 } ?? 0
        let keyChars = max(10, Int((width - 32 - 13 - tagRoom - 18) / Self.keyAdvance))
        let ttlRoom: CGFloat = ttl == nil ? 0 : 72
        let valueChars = max(6, Int((width - 32 - 13 - ttlRoom) / Self.valueAdvance))
        let cut = key.count > keyChars || (value.map { $0.count > valueChars || $0.contains("\n") } ?? false)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle().fill(color).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text(expanded ? TextFit.softBreaks(key) : SimHowMeasure.middle(key, keyChars))
                    .font(Theme.mono(11.5, .medium)).foregroundStyle(Theme.text)
                    .strikethrough(gone, color: Theme.bad.opacity(0.8))
                    .lineLimit(expanded ? nil : 1).truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let change { SimHowChangeTag(kind: change) }
                if cut || expanded {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(Theme.ui(8.5, .semibold)).foregroundStyle(hovered ? Theme.text : Theme.faint)
                        .frame(width: 11)
                }
            }
            if let value {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(value).font(Theme.mono(11.5)).foregroundStyle(Theme.text.opacity(0.86))
                        .lineLimit(expanded ? nil : 1).truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if let ttl, let remaining {
                        Text("ttl " + SimHowFormat.ttl(ttl))
                            .font(Theme.mono(10.5, .medium)).foregroundStyle(barColor(remaining)).monospacedDigit()
                            .fixedSize()
                    }
                }
                .padding(.leading, 13)
            }
            if ttl != nil, let remaining {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.borderStrong)
                        Capsule().fill(barColor(remaining)).frame(width: max(2, proxy.size.width * remaining))
                    }
                }
                .frame(height: 4)
                .padding(.leading, 13)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(background(hover: hovered && (cut || expanded)), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(flash > 0.02 ? tint.opacity(0.35 * flash) : Color.clear))
        .opacity(fade)
        .contentShape(Rectangle())
        .onTapGesture { if cut || expanded { toggle() } }
        .onHover { hovered = $0 }
        .pointerStyle(cut || expanded ? .link : nil)
        .accessibilityHint(cut ? "Shows the whole key and value" : "")
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

    private var tint: Color { SimHowChangeTag.tint(change) }

    private func background(hover: Bool) -> Color {
        if flash > 0.02 { return tint.opacity(0.05 + 0.12 * flash) }
        return hover ? Theme.hover : Theme.raised.opacity(0.6)
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

/// The current step: its label, who talks to whom and its note (markdown with glossary links, three
/// lines at most), or the summary before the first step. The title and the Step details button open the
/// step detail, which has all of it.
@MainActor
struct SimHowNotes: View {
    let model: AppModel
    let terms: TermIndex
    let player: SimHowPlayer
    @State private var hovered = false

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
                    Button { player.inspect(index) } label: {
                        Text("\(Text(frame.step.label).font(Theme.ui(13, .semibold)).foregroundStyle(hovered ? Theme.accent : Theme.text))   \(Text("\(name(frame.step.from)) → \(name(frame.step.to))").font(Theme.ui(11)).foregroundStyle(Theme.muted))")
                            .lineLimit(2).truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 }
                    .pointerStyle(.link)
                    .accessibilityHint("Opens the step detail")
                    if frame.branch != nil, index == player.playback.branchStart {
                        SimPill(title: player.playback.branch?.label ?? "branch", icon: "arrow.turn.down.right", tint: Theme.warn)
                    }
                    // A long note shows its first sentence here; the step detail has all of it.
                    if let note = frame.step.note ?? (index == player.playback.branchStart ? player.playback.branch?.note : nil),
                       let lead = Brief.parts(brief: nil, detail: note)?.lead {
                        SimMarkdown(source: lead, model: model, terms: terms, color: Theme.text.opacity(0.86), size: 13, lineLimit: 3)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("START").font(Theme.mono(10, .semibold)).foregroundStyle(Theme.accent)
                }
                .frame(width: 52, alignment: .leading)
                if let lead = Brief.parts(brief: player.mechanism.brief, detail: player.mechanism.summary)?.lead {
                    SimMarkdown(source: lead, model: model, terms: terms, color: Theme.text.opacity(0.86), size: 13, lineLimit: 3)
                } else {
                    Text("Press play or → to take the first step.").font(Theme.ui(13)).foregroundStyle(Theme.muted)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                SimButton(title: "Step details", icon: "sidebar.right") { player.inspect(index) }
                StrataKeycap("↩").opacity(0.8)
            }
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
    }

    private func name(_ id: String) -> String { player.mechanism.participants.first { $0.id == id }?.label ?? id }
}
