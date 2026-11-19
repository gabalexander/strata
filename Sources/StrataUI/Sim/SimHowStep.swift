import AppKit
import SwiftUI
import StrataCore

// The step detail (docs/design.md, How it works): everything one step carries, never cut short, in a
// pane beside the sequence diagram where the state panel was. It opens on a click on a step (or Return,
// or the step strip under the transport), follows ← and → and playback, and Esc or a click on empty
// diagram space returns to the state panel.

/// What a How it works step's raw / formatted SQL choice is remembered under (`SimOpsQueryMode`).
struct SimHowStepKey: Hashable {
    let ref: SimHowRef
    let branch: String?
    let step: String
}

@MainActor
struct SimHowStepDetail: View {
    let model: AppModel
    let sim: Simulation
    let terms: TermIndex
    let actions: SimActions
    let player: SimHowPlayer
    let keyColors: [String: Color]
    let select: (StageSelection?) -> Void
    var still = false

    var body: some View {
        let index = player.shown
        let frames = player.playback.frames
        VStack(spacing: 0) {
            bar(index)
            Rectangle().fill(Theme.border).frame(height: 1)
            SimPanelScroll(still: still, resetOn: AnyHashable("\(player.branch ?? "")#\(index)")) {
                VStack(alignment: .leading, spacing: 18) {
                    if index >= 0, index < frames.count { step(frames[index]) } else { start }
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .simEnumScope(model: model, sim: sim)
    }

    // MARK: Bar

    /// Back to the state panel, where this step sits in the path, previous and next.
    private func bar(_ index: Int) -> some View {
        let count = player.playback.frames.count
        return HStack(spacing: 6) {
            SimHowBackButton(title: "State") { player.closeInspector() }
                .strataHint("Back to the keys and values", shortcut: Shortcuts.escape.display)
            Spacer(minLength: 4)
            Text(index < 0 ? "start" : "step \(index + 1) of \(count)")
                .font(Theme.mono(11)).foregroundStyle(Theme.muted).monospacedDigit().lineLimit(1)
            SimButton(title: "Previous step", icon: "chevron.left", iconOnly: true, keys: "←") { player.step(-1) }
                .disabled(index < 0).opacity(index < 0 ? 0.4 : 1)
            SimButton(title: "Next step", icon: "chevron.right", iconOnly: true, keys: "→") { player.step(1) }
                .disabled(index >= count - 1).opacity(index >= count - 1 ? 0.4 : 1)
            StrataKeycap("Esc")
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
    }

    // MARK: A step

    @ViewBuilder
    private func step(_ frame: MechFrame) -> some View {
        let step = frame.step
        heading(frame)
        if let command = step.command.map(SimOpsCode.trimmed), !command.isEmpty { self.command(command, step: step) }
        if let reply = step.reply { self.reply(reply) }
        changes(frame)
        let branchNote = frame.index == player.playback.branchStart ? player.playback.branch?.note : nil
        if let note = step.note ?? branchNote {
            SimSection(title: "Note") {
                SimBriefText(brief: nil, detail: note, key: SimBriefKey.step(sim, player.ref, branch: frame.branch, step: step.id),
                             model: model, terms: terms, color: Theme.text.opacity(0.88), size: 13)
                if step.note != nil, let branchNote {
                    SimBriefText(brief: nil, detail: branchNote, key: SimBriefKey.step(sim, player.ref, branch: frame.branch, step: "branch"),
                                 model: model, terms: terms, color: Theme.text.opacity(0.88), size: 13)
                }
            }
        }
        branches(frame)
        if !step.code.isEmpty {
            SimSection(title: "Code") {
                ForEach(step.code, id: \.self) { path in
                    SimButton(title: path, icon: "chevron.left.forwardslash.chevron.right", hint: "Open \(path) in your editor") { actions.openCode(path) }
                }
            }
        }
    }

    private func heading(_ frame: MechFrame) -> some View {
        let step = frame.step
        let previous = frame.index > 0 ? player.playback.frames[frame.index - 1].time : 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("STEP \(frame.index + 1)").font(Theme.mono(10, .semibold)).foregroundStyle(Theme.accent)
                if player.playback.timed {
                    Text(timeLine(frame.time, previous: previous, first: frame.index == 0))
                        .font(Theme.mono(10)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Text(step.label).font(Theme.heading).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .strataSelectable { step.label }
            SimOpsChips {
                participant(step.from)
                if step.from != step.to {
                    Image(systemName: "arrow.right").font(Theme.ui(10, .semibold)).foregroundStyle(Theme.faint).frame(height: 24)
                    participant(step.to)
                } else {
                    Text("to itself").font(Theme.ui(11)).foregroundStyle(Theme.muted).frame(height: 24)
                }
            }
            if let branch = frame.branch.flatMap(player.mechanism.branch) {
                SimPill(title: branch.label, icon: "arrow.turn.down.right", tint: Theme.warn)
            }
        }
    }

    private func timeLine(_ time: Double, previous: Double, first: Bool) -> String {
        let at = "at " + SimHowFormat.time(time)
        guard !first, time > previous else { return at }
        return at + " · +" + SimHowFormat.time(time - previous)
    }

    private func participant(_ id: String) -> some View {
        let participant = player.mechanism.participants.first { $0.id == id } ?? Participant(id: id)
        return SimHowParticipantChip(participant: participant, node: participant.node.flatMap(sim.level.node), select: select)
    }

    // MARK: Command and reply

    @ViewBuilder
    private func command(_ command: String, step: MechStep) -> some View {
        switch StepCommand.kind(command) {
        case .sql:
            if let formatted = SimOpsQueryCache.formatted(command) {
                SimOpsQueryBlock(title: "SQL", source: command, formatted: formatted,
                                 ref: AnyHashable(SimHowStepKey(ref: player.ref, branch: player.branch, step: step.id)),
                                 sim: sim, overlays: model.overlays, still: still)
                    .environment(\.simEnumTables, tables(for: step, query: command))
            } else {
                plain(command)
            }
        case .redis:
            if let parts = StepCommand.redis(command) {
                SimHowRedisBlock(parts: parts, raw: command, overlays: model.overlays, still: still)
            } else {
                plain(command)
            }
        case .other:
            plain(command)
        }
    }

    private func plain(_ command: String) -> some View {
        let formatted = SimOpsCode.message(command)
        return SimOpsCodeBlock(title: "Command", text: formatted.text, raw: SimOpsCode.json(command) ?? command,
                               copyTitle: "Copy command", overlays: model.overlays, caption: formatted.isJSON ? "json" : nil, still: still)
    }

    /// The tables of the store the step talks to that its query names, so a `status` resolves to their enum first.
    private func tables(for step: MechStep, query: String) -> [TableRef] {
        let ids = [step.to, step.from].compactMap { id in player.mechanism.participants.first { $0.id == id }?.node }
        let words = Set(query.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "_") }.map(String.init))
        return ids.compactMap(sim.level.node).flatMap { node in
            node.schema.filter { words.contains($0.name.lowercased()) }.map { TableRef(node: node.id, table: $0.name) }
        }
    }

    private func reply(_ reply: String) -> some View {
        SimSection(title: "Reply") {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("→").font(Theme.mono(11)).foregroundStyle(Theme.faint)
                Text(reply).font(Theme.mono(11)).foregroundStyle(SimHowReply(reply).color)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .strataSelectable("Copy reply") { reply }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .card(Theme.bg, radius: Theme.radiusSmall)
        }
    }

    // MARK: State

    /// What this step did to each key: expiries before it, then its own sets, renewals and deletes.
    @ViewBuilder
    private func changes(_ frame: MechFrame) -> some View {
        let order = Self.changedKeys(frame)
        if !order.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Text("State").font(Theme.ui(11, .semibold)).foregroundStyle(Theme.muted)
                    Text("\(order.count) change\(order.count == 1 ? "" : "s")").font(Theme.mono(10)).foregroundStyle(Theme.faint)
                    Spacer(minLength: 0)
                    SimHowLinkButton(title: "All keys", icon: "list.bullet") { player.closeInspector() }
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(order, id: \.self) { key in
                        let kind = frame.change(of: key) ?? .set
                        let now = frame.state.first { $0.key == key }
                        SimHowChangeRow(key: key, value: kind == .delete || kind == .expire ? nil : now?.value,
                                        ttl: kind == .delete || kind == .expire ? nil : now?.ttl, kind: kind,
                                        color: keyColors[key] ?? Theme.muted)
                    }
                }
            }
        }
    }

    /// Each key the step changed, once, in the order the changes happened.
    private static func changedKeys(_ frame: MechFrame) -> [String] {
        var order: [String] = []
        for change in frame.changes where !order.contains(change.key) { order.append(change.key) }
        return order
    }

    // MARK: Branches

    /// The paths that leave the main sequence after this step, one click away.
    @ViewBuilder
    private func branches(_ frame: MechFrame) -> some View {
        let leaving = frame.branch == nil ? player.mechanism.branches.filter { $0.after == frame.step.id } : []
        if !leaving.isEmpty {
            SimSection(title: "Branches from here") {
                SimOpsChips {
                    ForEach(leaving) { branch in
                        SimHowBranchChip(title: branch.label, detail: "\(branch.steps.count) step\(branch.steps.count == 1 ? "" : "s")",
                                         icon: "arrow.turn.down.right", selected: player.branch == branch.id) {
                            player.choose(branch: branch.id)
                        }
                    }
                }
            }
        }
    }

    // MARK: The start

    /// Before the first step: the idea, who takes part, and the keys that exist already.
    @ViewBuilder
    private var start: some View {
        let mechanism = player.mechanism
        VStack(alignment: .leading, spacing: 8) {
            Text("START").font(Theme.mono(10, .semibold)).foregroundStyle(Theme.accent)
            Text(mechanism.title).font(Theme.heading).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        SimBriefText(brief: mechanism.brief, detail: mechanism.summary, key: SimBriefKey.mechanism(sim, player.ref),
                     model: model, terms: terms, color: Theme.text.opacity(0.88), leadColor: Theme.text, size: 13)
        SimSection(title: "Participants") {
            SimOpsChips {
                ForEach(mechanism.participants) { participant in
                    SimHowParticipantChip(participant: participant, node: participant.node.flatMap(sim.level.node), select: select)
                }
            }
        }
        if !player.playback.initial.isEmpty {
            SimSection(title: "State at the start") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(player.playback.initial, id: \.key) { key in
                        SimHowChangeRow(key: key.key, value: key.value, ttl: key.ttl, kind: nil, color: keyColors[key.key] ?? Theme.muted)
                    }
                }
            }
        }
        if !mechanism.code.isEmpty {
            SimSection(title: "Code") {
                ForEach(mechanism.code, id: \.self) { path in
                    SimButton(title: path, icon: "chevron.left.forwardslash.chevron.right", hint: "Open \(path) in your editor") { actions.openCode(path) }
                }
            }
        }
    }
}

/// A Valkey/Redis command taken apart: the verb, then each key on its own line, broken between its
/// segments when it wraps, then the arguments. Copy copies the command as written.
@MainActor
struct SimHowRedisBlock: View {
    let parts: StepCommand.Redis
    let raw: String
    let overlays: Overlays
    var still = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("Command").font(Theme.ui(11, .semibold)).foregroundStyle(Theme.muted)
                Text("valkey").font(Theme.mono(10)).foregroundStyle(Theme.faint)
                Spacer(minLength: 0)
                SimCopyButton(title: "Copy the command", action: copy)
            }
            .frame(height: 20)
            VStack(alignment: .leading, spacing: 6) {
                Text(parts.verb).font(Theme.mono(11.5, .semibold)).foregroundStyle(Theme.token(2))
                if let script = parts.script { row(parts.verb.hasPrefix("FCALL") ? "function" : "script", [script]) }
                if !parts.keys.isEmpty { row(parts.keys.count == 1 ? "key" : "keys", parts.keys.map(TextFit.softBreaks), strong: true) }
                if !parts.args.isEmpty { row("args", [parts.args.joined(separator: " ")]) }
            }
            .textSelection(.enabled)
            .padding(.horizontal, 10).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(Theme.bg, radius: Theme.radiusSmall)
            .simOpsMenu(still: still) { point in
                overlays.showMenu([MenuItem("Copy command", icon: "doc.on.doc", action: copy)], at: point)
            }
        }
    }

    private func row(_ title: String, _ values: [String], strong: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(Theme.ui(10.5)).foregroundStyle(Theme.faint)
                .frame(width: 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    Text(value).font(Theme.mono(11)).foregroundStyle(strong ? Theme.text : Theme.text.opacity(0.8))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(raw, forType: .string)
        overlays.toast("Copied command")
    }
}

/// One key a step changed (or one that exists at the start): the whole key, wrapped between segments,
/// what happened to it, its value and TTL.
@MainActor
struct SimHowChangeRow: View {
    let key: String
    let value: String?
    let ttl: Double?
    let kind: MechChange.Kind?
    let color: Color

    var body: some View {
        let gone = kind == .delete || kind == .expire
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle().fill(color).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text(TextFit.softBreaks(key)).font(Theme.mono(11, .medium)).foregroundStyle(Theme.text)
                    .strikethrough(gone, color: Theme.bad.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let kind { SimHowChangeTag(kind: kind) }
            }
            if value != nil || ttl != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let value {
                        Text(value).font(Theme.mono(11)).foregroundStyle(Theme.text.opacity(0.82))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if let ttl {
                        Text("ttl " + SimHowFormat.ttl(ttl)).font(Theme.mono(10.5, .medium)).foregroundStyle(Theme.muted)
                            .monospacedDigit().fixedSize()
                    }
                }
                .padding(.leading, 13)
            }
        }
        .strataSelectable { [key, value].compactMap { $0 }.joined(separator: " ") }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(Theme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
    }
}

/// `set`, `renewed`, `deleted`, `expired`, tinted by what it means.
struct SimHowChangeTag: View {
    let kind: MechChange.Kind

    var body: some View {
        Text(title).font(Theme.ui(9.5, .semibold)).foregroundStyle(Self.tint(kind))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(Self.tint(kind).opacity(0.13), in: Capsule())
            .fixedSize()
    }

    private var title: String {
        switch kind {
        case .set: "set"
        case .renew: "renewed"
        case .delete: "deleted"
        case .expire: "expired"
        }
    }

    static func tint(_ kind: MechChange.Kind?) -> Color {
        switch kind {
        case .set?: Theme.accent
        case .renew?: Theme.good
        case .delete?, .expire?: Theme.bad
        case nil: Theme.muted
        }
    }
}

/// A participant as a small chip: its kind icon and name; linked ones select their node on the stage.
@MainActor
struct SimHowParticipantChip: View {
    let participant: Participant
    let node: Node?
    let select: (StageSelection?) -> Void
    @State private var hovered = false

    var body: some View {
        let kind = node?.kind ?? participant.kind ?? .service
        let tint = Node(id: participant.id, kind: kind).simTint
        let content = HStack(spacing: 5) {
            Image(systemName: node?.icon ?? kind.symbol)
                .font(Theme.ui(9, .semibold)).foregroundStyle(tint)
                .frame(width: 16, height: 16)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            Text(participant.label).font(Theme.ui(11.5, .medium)).foregroundStyle(hovered ? Theme.accent : Theme.text).lineLimit(1)
            if node != nil {
                Image(systemName: "arrow.up.forward").font(Theme.ui(7, .bold)).foregroundStyle(hovered ? Theme.accent : Theme.faint)
            }
        }
        .padding(.leading, 4).padding(.trailing, 8)
        .frame(height: 24)
        .background(hovered ? Theme.hover : Theme.raised, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(Theme.border))
        if let node {
            Button { select(.node(node.id)) } label: { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
                .strataHint("Select \(node.label) on the stage")
                .accessibilityLabel("\(participant.label), select \(node.label) on the stage")
        } else {
            content
        }
    }
}

@MainActor
struct SimHowBackButton: View {
    let title: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left").font(Theme.ui(10, .semibold))
                Text(title).font(Theme.ui(12, .medium)).lineLimit(1)
            }
            .foregroundStyle(hovered ? Theme.text : Theme.muted)
            .padding(.horizontal, 7).frame(height: 24)
            .background(hovered ? Theme.hover : Theme.raised, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("Back to \(title)")
    }
}

/// A quiet text button for a section header: `All keys`, `Step details`.
@MainActor
struct SimHowLinkButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).font(Theme.ui(11, .medium))
                Image(systemName: icon).font(Theme.ui(9, .semibold))
            }
            .foregroundStyle(hovered ? Theme.accent : Theme.muted)
            .padding(.horizontal, 6).frame(height: 20)
            .background(hovered ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
