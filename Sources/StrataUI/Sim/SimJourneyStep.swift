import AppKit
import SwiftUI
import StrataCore

// The journey's step pane: everything one step carries, never cut short. Where it happens and what it
// talks to (chips that select the node), the op with its query formatted and its binds filled in (the
// op detail's query block, the How player's Valkey block), the message or request it sends, the rows
// it changes, the status codes it moves, its note, the mechanism that explains it, and its code.

/// What a journey step's raw / formatted SQL choice is remembered under (`SimOpsQueryMode`).
struct SimJourneyStepKey: Hashable {
    let journey: String
    let step: String
}

@MainActor
struct SimJourneyStepPane: View {
    let model: AppModel
    let sim: Simulation
    let terms: TermIndex
    let actions: SimActions
    let player: SimJourneyPlayer
    let select: (StageSelection?) -> Void
    var still = false

    var body: some View {
        SimPanelScroll(still: still, resetOn: AnyHashable(player.shown)) {
            VStack(alignment: .leading, spacing: 16) {
                if let frame = player.frame { step(frame) } else { start }
            }
            .padding(.horizontal, 14)
            .padding(.top, 13)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var manifest: Manifest { sim.manifest }
    private var playback: JourneyPlayback { player.playback }

    // MARK: The start

    @ViewBuilder
    private var start: some View {
        let journey = player.journey
        VStack(alignment: .leading, spacing: 7) {
            Text("START").font(Theme.mono(10, .semibold)).foregroundStyle(Theme.accent)
            Text(journey.title).font(Theme.heading).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            if let brief = journey.brief {
                Text(brief).font(Theme.ui(13)).foregroundStyle(Theme.text.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            }
        }
        SimSection(title: "Follows") {
            SimOpsChips {
                ForEach([playback.entity].compactMap { $0 } + playback.related, id: \.self) { id in
                    SimJourneyRowChip(title: playback.title(id), role: playback.role(id), entity: id == playback.entity)
                }
            }
        }
        let rows = Set(playback.frames.flatMap { $0.diffs.map(\.row) }).count
        let moves = playback.moves.count
        let first = playback.frames.first?.instant, last = playback.frames.last?.instant
        let span = [first.map(JourneyClock.format), last.map(JourneyClock.format)].compactMap { $0 }
        Text(["\(player.count) steps", "\(moves) status move\(moves == 1 ? "" : "s")", "\(rows) row\(rows == 1 ? "" : "s") changed",
              span.count == 2 && span[0] != span[1] ? "\(span[0]) to \(span[1])" : nil].compactMap { $0 }.joined(separator: " · "))
            .font(Theme.mono(11)).foregroundStyle(Theme.muted)
        HStack(spacing: 6) {
            StrataKeycap("→")
            Text("or").font(Theme.ui(11)).foregroundStyle(Theme.faint)
            StrataKeycap("Space")
            Text("to step through, a click on a step to jump,").font(Theme.ui(11)).foregroundStyle(Theme.muted)
            StrataKeycap("Esc")
            Text("to close").font(Theme.ui(11)).foregroundStyle(Theme.muted)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.9)
    }

    // MARK: A step

    @ViewBuilder
    private func step(_ frame: JourneyFrame) -> some View {
        heading(frame)
        if let op = frame.op { opLine(op, frame: frame) }
        if let command = frame.command { self.command(command, frame: frame) }
        if !frame.step.binds.isEmpty { binds(frame) }
        if !frame.diffs.isEmpty { rows(frame) }
        if !frame.moves.isEmpty { moves(frame) }
        if let note = frame.step.note {
            SimSection(title: "Note") {
                SimMarkdown(source: note, model: model, terms: terms, color: Theme.text.opacity(0.88), size: 13)
            }
        }
        if let how = frame.step.how, let found = manifest.resolveJourneyHow(how) { self.how(found) }
        if let code = frame.op?.op.code, !code.isEmpty {
            SimSection(title: "Code") {
                ForEach(code, id: \.self) { path in
                    SimButton(title: path, icon: "chevron.left.forwardslash.chevron.right", hint: "Open \(path) in your editor") { actions.openCode(path) }
                }
            }
        }
    }

    private func heading(_ frame: JourneyFrame) -> some View {
        let previous = frame.index > 0 ? playback.frames[frame.index - 1].instant : nil
        let time = [frame.instant.map(JourneyClock.format), JourneyClock.delta(frame.instant, after: previous)].compactMap { $0 }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text("STEP \(frame.index + 1) OF \(player.count)").font(Theme.mono(10, .semibold)).foregroundStyle(Theme.accent)
                if !time.isEmpty { Text(time.joined(separator: " · ")).font(Theme.mono(10)).foregroundStyle(Theme.muted).lineLimit(1) }
                Spacer(minLength: 0)
            }
            Text(frame.step.label).font(Theme.heading).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .strataSelectable { frame.step.label }
            places(frame)
            dive(frame)
        }
    }

    /// Where it happens, then what it talks to: chips that select their node on this level.
    private func places(_ frame: JourneyFrame) -> some View {
        let level = manifest.level(at: frame.path)
        let here = frame.path == sim.path
        return SimOpsChips {
            if !frame.path.isEmpty {
                let owner = frame.path.last.flatMap { last in
                    manifest.level(at: Array(frame.path.dropLast()))?.node(last.split(separator: "#").first.map(String.init) ?? last)?.label
                }
                SimJourneyPathChip(title: "in " + (owner ?? frame.path.joined(separator: " › ")))
            }
            if let id = frame.node {
                SimJourneyNodeChip(node: level?.node(id), id: id, select: here ? { select(.node(id)) } : nil)
            }
            ForEach(Array(Set([frame.target, frame.buffer].compactMap { $0 }.filter { $0 != frame.node })).sorted(), id: \.self) { other in
                Image(systemName: frame.op?.op.kind == .consume ? "arrow.left" : "arrow.right")
                    .font(Theme.ui(10, .semibold)).foregroundStyle(Theme.faint).frame(height: 24)
                SimJourneyNodeChip(node: level?.node(other), id: other, select: here ? { select(.node(other)) } : nil)
            }
        }
    }

    /// A step on another level than the stage shows: the way there.
    @ViewBuilder
    private func dive(_ frame: JourneyFrame) -> some View {
        if frame.path != sim.path {
            let deeper = frame.path.count > sim.path.count && Array(frame.path.prefix(sim.path.count)) == sim.path
            if deeper, let next = frame.path[sim.path.count].split(separator: "#").first.map(String.init), let node = sim.level.node(next),
               frame.path.count == sim.path.count + 1, node.inside != nil {
                SimButton(title: "Dive into \(node.label)", icon: "square.3.layers.3d", active: true) { actions.dive(node) }
            } else {
                let title = frame.path.isEmpty ? manifest.title : (frame.path.last ?? "")
                SimButton(title: "Go to \(title)", icon: "arrow.up.left", active: true) {
                    model.open(.sim(manifest.id, path: frame.path))
                }
            }
        }
    }

    private func opLine(_ site: JourneyOpSite, frame: JourneyFrame) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: site.op.kind.symbol).font(Theme.ui(11, .medium)).foregroundStyle(Theme.info)
                .frame(width: 22, height: 22)
                .background(Theme.info.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 1) {
                Text(site.op.label).font(Theme.ui(12.5, .medium)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(site.reference).font(Theme.mono(10.5)).foregroundStyle(Theme.faint).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if site.path == sim.path, sim.level.node(site.node) != nil {
                SimHowLinkButton(title: "Op details", icon: "chevron.right") {
                    select(.node(site.node))
                    SimOpsState.of(sim).open(OpRef(node: site.node, op: site.op.id), from: .node(site.node))
                    model.inspectorVisible = true
                }
            }
        }
    }

    // MARK: The command

    @ViewBuilder
    private func command(_ command: JourneyCommand, frame: JourneyFrame) -> some View {
        let filled = !frame.step.binds.isEmpty && !(command.fill?.placeholders.isEmpty ?? true)
        switch command.kind {
        case .sql:
            if let formatted = SimOpsQueryCache.formatted(command.text) {
                SimOpsQueryBlock(title: filled ? "SQL, binds filled" : "SQL", source: command.text, formatted: formatted,
                                 ref: AnyHashable(SimJourneyStepKey(journey: player.journey.id, step: frame.step.id)),
                                 sim: sim, overlays: model.overlays, still: still)
                    .environment(\.simEnumTables, tables(frame))
            } else {
                plain("SQL", command.text, caption: nil)
            }
        case .redis:
            if let parts = StepCommand.redis(command.text) {
                SimHowRedisBlock(parts: parts, raw: command.text, overlays: model.overlays, still: still)
            } else {
                plain("Command", command.text, caption: nil)
            }
        case .message:
            let to = frame.buffer ?? frame.target
            let caption = [command.title, to.map { (frame.op?.op.kind == .consume ? "from " : "to ") + $0 }].compactMap { $0 }.joined(separator: " · ")
            plain(frame.op?.op.kind == .consume ? "Message received" : "Message", command.text, caption: caption)
                .environment(\.simEnumTables, tables(frame))
        case .request:
            if command.text.isEmpty {
                plain("Request", command.title, caption: nil)
            } else {
                plain("Request", command.text, caption: command.title)
                    .environment(\.simEnumTables, tables(frame))
            }
        }
    }

    private func plain(_ title: String, _ text: String, caption: String?) -> some View {
        let formatted = SimOpsCode.message(text)
        return SimOpsCodeBlock(title: title, text: formatted.text, raw: SimOpsCode.json(text) ?? text, copyTitle: "Copy \(title.lowercased())",
                               overlays: model.overlays, caption: caption ?? (formatted.isJSON ? "json" : nil), still: still)
    }

    /// The tables the step's op names, so a `status` in its query resolves to their enum first.
    private func tables(_ frame: JourneyFrame) -> [TableRef] {
        guard let site = frame.op, let level = manifest.level(at: site.path) else { return [] }
        let touched = level.tables(touchedBy: site.op, on: site.node).compactMap { touched in touched.node.map { TableRef(node: $0, table: touched.name) } }
        let written = frame.diffs.map { TableRef(node: $0.row.node, table: $0.row.table) }
        var all: [TableRef] = []
        for table in written + touched where !all.contains(table) { all.append(table) }
        return all
    }

    // MARK: Binds, rows, statuses

    private func binds(_ frame: JourneyFrame) -> some View {
        let placeholders = frame.command?.fill?.placeholders ?? []
        let numbered = placeholders.contains { $0.hasPrefix("$") }
        return SimSection(title: "Binds") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(frame.step.binds.enumerated()), id: \.offset) { index, bind in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(bind.name ?? (numbered ? "$\(index + 1)" : "?\(index + 1)"))
                            .font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
                            .frame(width: 92, alignment: .leading).lineLimit(1).truncationMode(.middle)
                        Text(bind.value ?? "NULL").font(Theme.mono(11)).foregroundStyle(bind.value == nil ? Theme.muted : Theme.text)
                            .lineLimit(3).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .strataSelectable("Copy value") { bind.value ?? "NULL" }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .card(Theme.bg, radius: Theme.radiusSmall)
        }
    }

    private func rows(_ frame: JourneyFrame) -> some View {
        SimSection(title: "Rows") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(frame.diffs.enumerated()), id: \.offset) { _, diff in
                    SimJourneyDiffRow(diff: diff, title: playback.title(diff.row), role: playback.role(diff.row), manifest: manifest)
                }
            }
        }
    }

    private func moves(_ frame: JourneyFrame) -> some View {
        SimSection(title: "Status") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(frame.moves.enumerated()), id: \.offset) { _, move in
                    SimJourneyMoveRow(move: move, row: move.row.map { playback.role($0) ?? playback.title($0) }, manifest: manifest)
                }
            }
        }
    }

    // MARK: How it works

    @ViewBuilder
    private func how(_ found: (path: [String], node: String, op: String?, mechanism: Mechanism)) -> some View {
        let here = found.path == sim.path
        let owner = manifest.level(at: found.path)?.node(found.node)
        SimSection(title: "How it works") {
            let level = found.path.last.flatMap { last in
                manifest.level(at: Array(found.path.dropLast()))?.node(last.split(separator: "#").first.map(String.init) ?? last)?.label
            } ?? manifest.title
            SimButton(title: found.mechanism.title + (here ? "" : " (in \(level))"),
                      icon: SimHowMenus.icon, active: true, hint: "Play “\(found.mechanism.title)” step by step") {
                if here {
                    player.pause()
                    let label = found.op.flatMap { op in owner?.ops.first { $0.id == op }?.label } ?? owner?.label ?? found.node
                    SimHowState.of(sim).open(found.mechanism, ref: SimHowRef(node: found.node, op: found.op, mechanism: found.mechanism.id), owner: label)
                } else {
                    player.pause()
                    SimJourneyState.of(model).pendingHow = (manifest.id, found.path, found.node, found.op, found.mechanism.id)
                    model.open(.sim(manifest.id, path: found.path))
                }
            }
        }
    }
}

// MARK: - Pieces

/// A node a step happens at or talks to; selects it on the stage when it is on this level.
@MainActor
struct SimJourneyNodeChip: View {
    let node: Node?
    let id: String
    let select: (() -> Void)?
    @State private var hovered = false

    var body: some View {
        let kind = node?.kind ?? .service
        let tint = (node ?? Node(id: id, kind: kind)).simTint
        let content = HStack(spacing: 5) {
            Image(systemName: node?.icon ?? kind.symbol)
                .font(Theme.ui(9, .semibold)).foregroundStyle(tint)
                .frame(width: 16, height: 16)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            Text(node?.label ?? id).font(Theme.ui(11.5, .medium)).foregroundStyle(hovered ? Theme.accent : Theme.text).lineLimit(1)
            if select != nil {
                Image(systemName: "arrow.up.forward").font(Theme.ui(7, .bold)).foregroundStyle(hovered ? Theme.accent : Theme.faint)
            }
        }
        .padding(.leading, 4).padding(.trailing, 8)
        .frame(height: 24)
        .background(hovered ? Theme.hover : Theme.raised, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(Theme.border))
        if let select {
            Button(action: select) { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
                .strataHint("Select \(node?.label ?? id) on the stage")
                .accessibilityLabel("Select \(node?.label ?? id) on the stage")
        } else {
            content
        }
    }
}

struct SimJourneyPathChip: View {
    let title: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "square.3.layers.3d").font(Theme.ui(9, .semibold))
            Text(title).font(Theme.ui(11, .medium)).lineLimit(1)
        }
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(Theme.hover, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
    }
}

/// A row the journey follows: its role and table and key.
struct SimJourneyRowChip: View {
    let title: String
    let role: String?
    var entity = false
    var body: some View {
        HStack(spacing: 5) {
            if let role { Text(role).font(Theme.ui(11, .semibold)).foregroundStyle(entity ? Theme.accent : Theme.muted) }
            Text(title).font(Theme.mono(11)).foregroundStyle(Theme.text)
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(entity ? Theme.accent.opacity(0.10) : Theme.raised, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(entity ? Theme.accent.opacity(0.28) : Theme.border))
    }
}

/// `insert`, `update`, `delete`, tinted by what it does to the row.
struct SimJourneyKindTag: View {
    let kind: JourneyRowKind
    var body: some View {
        Text(kind == .insert ? "inserted" : kind == .update ? "updated" : "deleted")
            .font(Theme.ui(9.5, .semibold)).foregroundStyle(Self.tint(kind))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(Self.tint(kind).opacity(0.13), in: Capsule())
            .fixedSize()
    }

    static func tint(_ kind: JourneyRowKind) -> Color {
        switch kind {
        case .insert: Theme.good
        case .update: Theme.accent
        case .delete: Theme.bad
        }
    }
}

/// One row a step changed: what happened to it, then each changed cell.
@MainActor
private struct SimJourneyDiffRow: View {
    let diff: JourneyRowDiff
    let title: String
    let role: String?
    let manifest: Manifest

    var body: some View {
        let enums = SimJourneyRows.enumColumns(diff.row, in: manifest)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                SimJourneyKindTag(kind: diff.kind)
                if let role { Text(role).font(Theme.ui(11, .semibold)).foregroundStyle(Theme.muted) }
                Text(title).font(Theme.mono(11, .medium)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            switch diff.kind {
            case .update:
                ForEach(diff.cells, id: \.column) { cell in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(cell.column).font(Theme.mono(10.5)).foregroundStyle(Theme.faint).lineLimit(1)
                        Text(SimJourneyRows.display(cell.before, enum: enums[cell.column], manifest)).font(Theme.mono(10.5))
                            .foregroundStyle(Theme.muted).strikethrough(color: Theme.faint).lineLimit(2)
                        Image(systemName: "arrow.right").font(Theme.ui(8, .semibold)).foregroundStyle(Theme.faint)
                        Text(SimJourneyRows.display(cell.after, enum: enums[cell.column], manifest)).font(Theme.mono(10.5, .medium))
                            .foregroundStyle(Theme.text).lineLimit(2)
                    }
                }
            case .insert:
                Text("\(diff.cells.count) value\(diff.cells.count == 1 ? "" : "s"): "
                     + diff.cells.prefix(4).map { "\($0.column) \(SimJourneyRows.display($0.after, enum: enums[$0.column], manifest))" }.joined(separator: ", ")
                     + (diff.cells.count > 4 ? ", …" : ""))
                    .font(Theme.mono(10.5)).foregroundStyle(Theme.muted).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            case .delete:
                EmptyView()
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(Theme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
    }
}

/// A status code moving: the enum, from, to, with the names, and the transition it follows.
@MainActor
private struct SimJourneyMoveRow: View {
    let move: JourneyMove
    let row: String?
    let manifest: Manifest

    var body: some View {
        let def = manifest.enumDef(move.enumID)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "tag").font(Theme.ui(9, .semibold)).foregroundStyle(simEnumTint)
                Text(def?.label ?? move.enumID).font(Theme.ui(11, .medium)).foregroundStyle(simEnumTint).lineLimit(1)
                if let row { Text(row + (move.column.map { ".\($0)" } ?? "")).font(Theme.mono(10.5)).foregroundStyle(Theme.faint).lineLimit(1) }
                Spacer(minLength: 0)
            }
            SimOpsChips {
                if let from = move.from {
                    code(from, def: def, current: false)
                    Image(systemName: "arrow.right").font(Theme.ui(9, .semibold)).foregroundStyle(Theme.faint).frame(height: 22)
                } else {
                    Text("enters").font(Theme.ui(11)).foregroundStyle(Theme.muted).frame(height: 22)
                }
                code(move.to, def: def, current: true)
            }
            if let transition = move.transition, transition.label != nil || transition.by != nil {
                Text([transition.label, transition.by.map { "by \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.ui(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(Theme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
    }

    private func code(_ value: String, def: EnumDef?, current: Bool) -> some View {
        let name = def?.value(value)?.name
        return HStack(spacing: 5) {
            Text(value).font(Theme.mono(11, .semibold)).foregroundStyle(current ? Theme.accent : Theme.text)
            if let name, name != value { Text(name).font(Theme.ui(11, .medium)).foregroundStyle(current ? Theme.accent : Theme.muted) }
        }
        .lineLimit(1)
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(current ? Theme.accent.opacity(0.12) : Theme.bg, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(current ? Theme.accent.opacity(0.3) : Theme.border))
    }
}
