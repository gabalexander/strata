import SwiftUI
import StrataCore

// The journey player's panel (docs/design.md, Journeys): under the stage, in the dock's place, so the
// architecture stays in view while the journey steps through it. From the top: the header with the
// transport, the status timeline, then the steps, the step pane and the rows as they are after the step.
// Widths are decided once per size; every step change re-renders the panes on the frame it happens.

@MainActor
struct SimJourneyPanel: View {
    let model: AppModel
    let sim: Simulation
    let terms: TermIndex
    let actions: SimActions
    let player: SimJourneyPlayer
    let select: (StageSelection?) -> Void
    let width: CGFloat
    let height: CGFloat
    var still = false

    /// The panel's height for a stage column this tall: about half, between 300 and 470.
    static func height(for column: CGFloat) -> CGFloat { min(470, max(300, column * 0.48)) }

    /// The steps list and rows pane widths at a panel width; 0 hides one.
    static func columns(_ width: CGFloat) -> (list: CGFloat, rows: CGFloat) {
        let list: CGFloat = width >= 1060 ? 236 : width >= 840 ? 196 : 0
        let rows: CGFloat = width >= 660 ? min(400, max(272, width * 0.3)) : 0
        return (list, rows)
    }

    var body: some View {
        let columns = Self.columns(width)
        let hasMoves = !player.playback.moves.isEmpty
        let bodyHeight = max(0, height - 45 - (hasMoves ? 35 : 0))
        VStack(spacing: 0) {
            SimJourneyHeader(player: player, width: width, narrow: columns.rows == 0, close: { SimJourneyState.of(model).close() })
                .frame(height: 44)
            Rectangle().fill(Theme.border).frame(height: 1)
            if hasMoves {
                SimJourneyTimeline(sim: sim, player: player, width: width)
                    .frame(width: width, height: 34)
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            HStack(spacing: 0) {
                if columns.list > 0 {
                    SimJourneySteps(player: player, sim: sim, height: bodyHeight, still: still)
                        .frame(width: columns.list, height: bodyHeight)
                    Rectangle().fill(Theme.border).frame(width: 1, height: bodyHeight)
                }
                let pane = max(0, width - columns.list - columns.rows - (columns.list > 0 ? 1 : 0) - (columns.rows > 0 ? 1 : 0))
                if columns.rows == 0 && player.narrowRows {
                    SimJourneyRows(model: model, sim: sim, player: player, width: pane, still: still)
                        .frame(width: pane, height: bodyHeight)
                } else {
                    SimJourneyStepPane(model: model, sim: sim, terms: terms, actions: actions, player: player, select: select, still: still)
                        .frame(width: pane, height: bodyHeight)
                }
                if columns.rows > 0 {
                    Rectangle().fill(Theme.border).frame(width: 1, height: bodyHeight)
                    SimJourneyRows(model: model, sim: sim, player: player, width: columns.rows, still: still)
                        .frame(width: columns.rows, height: bodyHeight)
                }
            }
            .frame(width: width, height: bodyHeight)
        }
        .frame(width: width, height: height)
        .background(Theme.surface)
        .simEnumScope(model: model, sim: sim)
    }
}

/// The title, what it follows, the transport and where in the journey it is.
@MainActor
private struct SimJourneyHeader: View {
    let player: SimJourneyPlayer
    let width: CGFloat
    let narrow: Bool
    let close: () -> Void

    var body: some View {
        let playback = player.playback
        let entity = playback.entity.map { id in [playback.role(id), playback.title(id)].compactMap { $0 }.joined(separator: " · ") }
        HStack(spacing: 10) {
            Image(systemName: SimJourneyMenus.icon)
                .font(Theme.ui(13, .semibold)).foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("Journey").font(Theme.ui(11, .semibold)).foregroundStyle(Theme.accent).fixedSize()
                    if let entity, width >= 560 {
                        Text("·").font(Theme.ui(11)).foregroundStyle(Theme.faint)
                        Text(entity).font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                    }
                }
                Text(player.journey.title).font(Theme.ui(13, .semibold)).foregroundStyle(Theme.text)
                    .lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The same transport as the How it works player: frame glyphs, hints with their keys.
            HStack(spacing: 4) {
                SimButton(title: "Back to the start", icon: "backward.end.fill", iconOnly: true, keys: "Home") { player.jump(to: -1) }
                SimButton(title: "Previous step", icon: "backward.frame.fill", iconOnly: true, keys: "←") { player.step(-1) }
                    .disabled(player.shown < 0).opacity(player.shown < 0 ? 0.4 : 1)
                SimButton(title: player.playing ? "Pause" : "Play", icon: player.playing ? "pause.fill" : "play.fill",
                          iconOnly: true, active: player.playing, shortcut: Shortcuts.journeyPlay) { player.toggle() }
                SimButton(title: "Next step", icon: "forward.frame.fill", iconOnly: true, keys: "→") { player.step(1) }
                    .disabled(player.atEnd).opacity(player.atEnd ? 0.4 : 1)
            }
            .fixedSize()
            Text(player.shown < 0 ? "start · \(player.count) steps" : "step \(player.shown + 1) of \(player.count)")
                .font(Theme.mono(11)).foregroundStyle(Theme.muted).monospacedDigit().lineLimit(1).fixedSize()
            if narrow {
                SimSegments(values: [false, true], selected: player.narrowRows, label: { $0 ? "Rows" : "Step" }) { player.narrowRows = $0 }
                    .fixedSize()
                    .strataHint("The step, or the rows as they are after it")
            }
            if width >= 760 { StrataKeycap("Esc") }
            SimButton(title: "Close the journey", icon: "xmark", iconOnly: true, shortcut: Shortcuts.journeyEscape, action: close)
        }
        .padding(.horizontal, 12)
    }
}

/// Every status move so far as a chip, in order; the current step's in the accent. A click jumps to
/// the step that made it. When they don't fit, the earliest give way to a count.
@MainActor
private struct SimJourneyTimeline: View {
    let sim: Simulation
    let player: SimJourneyPlayer
    let width: CGFloat

    private static let font = NSFont.systemFont(ofSize: 11, weight: .medium)
    private static let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)

    struct Chip: Hashable {
        let step: Int
        let row: String
        let code: String
        let name: String?
        let entered: Bool
    }

    var body: some View {
        let chips = self.chips
        let shown = fitted(chips)
        HStack(spacing: 6) {
            Text("Status").font(Theme.ui(11, .semibold)).foregroundStyle(Theme.muted).fixedSize()
            if chips.isEmpty {
                let first = player.playback.moves.first.map { $0.step + 1 }
                Text(first.map { "Nothing has moved yet; the first status moves at step \($0)." } ?? "")
                    .font(Theme.ui(11)).foregroundStyle(Theme.faint).lineLimit(1)
            }
            if shown.dropped > 0 {
                Text("+\(shown.dropped) earlier").font(Theme.ui(10.5, .medium)).foregroundStyle(Theme.faint).fixedSize()
            }
            ForEach(Array(shown.chips.enumerated()), id: \.offset) { index, chip in
                if index > 0 || shown.dropped > 0 {
                    Image(systemName: "chevron.right").font(Theme.ui(8, .semibold)).foregroundStyle(Theme.faint)
                }
                SimJourneyMoveChip(chip: chip, current: chip.step == player.shown) { player.jump(to: chip.step) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
    }

    /// Moves up to the step on screen.
    private var chips: [Chip] {
        let playback = player.playback
        return playback.moves.filter { $0.step <= player.shown }.map { move in
            let def = sim.manifest.enumDef(move.enumID)
            let row = move.row.map { playback.role($0) ?? $0.table } ?? (def?.label ?? move.enumID)
            let name = def?.value(move.to)?.name
            return Chip(step: move.step, row: row, code: move.to, name: name == move.to ? nil : name, entered: move.from == nil)
        }
    }

    private static func width(_ chip: Chip) -> CGFloat {
        SimHowMeasure.width(chip.row, font) + SimHowMeasure.width(chip.code, mono)
            + (chip.name.map { SimHowMeasure.width($0, font) + 5 } ?? 0) + 5 + 18 + 16
    }

    /// The latest chips that fit the row, and how many earlier ones gave way.
    private func fitted(_ chips: [Chip]) -> (chips: [Chip], dropped: Int) {
        var room = width - 24 - 50 - 8
        var kept: [Chip] = []
        for chip in chips.reversed() {
            let need = Self.width(chip) + 14
            let reserve: CGFloat = kept.count + 1 < chips.count ? 78 : 0
            guard need + reserve <= room else { break }
            room -= need
            kept.insert(chip, at: 0)
        }
        return (kept, chips.count - kept.count)
    }
}

@MainActor
private struct SimJourneyMoveChip: View {
    let chip: SimJourneyTimeline.Chip
    let current: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(chip.row).font(Theme.ui(11, .medium)).foregroundStyle(current ? Theme.accent.opacity(0.85) : Theme.muted)
                Text(chip.code).font(Theme.mono(11, .semibold)).foregroundStyle(current ? Theme.accent : Theme.text)
                if let name = chip.name {
                    Text(name).font(Theme.ui(11, .medium)).foregroundStyle(current ? Theme.accent : Theme.text.opacity(0.75))
                }
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(current ? Theme.accent.opacity(0.14) : hovered ? Theme.hover : Theme.raised, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(current ? Theme.accent.opacity(0.35) : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .strataHint(current ? "" : "Go to step \(chip.step + 1), which made this move")
        .accessibilityLabel("\(chip.row) \(chip.code) \(chip.name ?? ""), step \(chip.step + 1)")
    }
}

/// The steps in order: a click jumps to one. The current one is lit and kept in view.
@MainActor
private struct SimJourneySteps: View {
    let player: SimJourneyPlayer
    let sim: Simulation
    let height: CGFloat
    var still = false

    var body: some View {
        let frames = player.playback.frames
        if still {
            // Offscreen there is no scrolling: start the list a few rows above the current step.
            let visible = max(3, Int(height / 44))
            let first = max(0, min(frames.count - visible, player.shown - visible / 2))
            VStack(spacing: 2) {
                ForEach(frames.indices.dropFirst(max(0, first)), id: \.self) { index in row(frames[index]) }
            }
            .padding(6)
            .fixedSize(horizontal: false, vertical: true)
            .frame(height: height, alignment: .top)
            .clipped()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(frames, id: \.index) { frame in row(frame).id(frame.index) }
                    }
                    .padding(6)
                }
                .onChange(of: player.shown) { _, index in
                    proxy.scrollTo(max(0, index), anchor: .center)
                }
            }
        }
    }

    private func row(_ frame: JourneyFrame) -> some View {
        SimJourneyStepRow(frame: frame, state: frame.index == player.shown ? .current : frame.index < player.shown ? .done : .ahead,
                          place: place(frame)) { player.jump(to: frame.index) }
    }

    private func place(_ frame: JourneyFrame) -> String {
        let node = frame.node.flatMap { id in sim.manifest.level(at: frame.path)?.node(id)?.label } ?? frame.node ?? ""
        let op = frame.op.map { $0.op.id }
        return [node, op].compactMap { $0 }.joined(separator: " · ")
    }
}

@MainActor
private struct SimJourneyStepRow: View {
    enum State { case done, current, ahead }
    let frame: JourneyFrame
    let state: State
    let place: String
    let action: () -> Void
    @SwiftUI.State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(frame.index + 1)")
                    .font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(state == .current ? Theme.bg : state == .done ? Theme.accent : Theme.faint)
                    .frame(width: 20, height: 20)
                    .background(state == .current ? Theme.accent : state == .done ? Theme.accent.opacity(0.13) : .clear, in: Circle())
                    .overlay(Circle().strokeBorder(state == .ahead ? Theme.borderStrong : .clear))
                VStack(alignment: .leading, spacing: 2) {
                    Text(frame.step.label).font(Theme.ui(12, state == .current ? .semibold : .medium))
                        .foregroundStyle(state == .ahead ? Theme.muted : Theme.text)
                        .lineLimit(2).truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(place).font(Theme.mono(10)).foregroundStyle(Theme.faint).lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !frame.moves.isEmpty {
                    Circle().fill(state == .ahead ? Theme.faint : Theme.accent).frame(width: 5, height: 5).padding(.top, 7)
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 6)
            .background(state == .current ? Theme.accent.opacity(0.10) : hovered ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("Step \(frame.index + 1): \(frame.step.label)")
        .accessibilityAddTraits(state == .current ? .isSelected : [])
    }
}
