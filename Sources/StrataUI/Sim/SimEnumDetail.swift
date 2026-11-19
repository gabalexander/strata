import AppKit
import SwiftUI
import StrataCore

/// Laid over the stage: draws nothing until an enum's detail is open for this manifest, then shows it
/// as a panel at the top of the stage, which stays interactive around it. Escape or × closes it.
@MainActor
struct SimEnumDetailHost: View {
    let model: AppModel
    let sim: Simulation
    var still = false

    var body: some View {
        let state = SimEnumState.of(model)
        if let detail = state.detail, detail.manifest == sim.manifest.id, let def = SimEnumIndex.of(sim).def(detail.enumID) {
            GeometryReader { proxy in
                SimEnumDetailPanel(model: model, sim: sim, def: def, highlight: detail.value,
                                   width: min(860, max(0, proxy.size.width - 28)), maxHeight: max(0, proxy.size.height - 28), still: still)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 14)
            }
            .background {
                // Stills can't draw AppKit views (and have no keys).
                if !still { escape(state) }
            }
            .onDisappear { state.close() }
        }
    }

    private func escape(_ state: SimEnumState) -> some View {
                WindowEvents(matching: .keyDown) { event, _ in
                    guard event.keyCode == 53, !event.hasCommandModifiers, model.overlays.menu == nil, model.overlays.card == nil,
                          !model.paletteOpen, !model.switcherOpen else { return event }
                    if !event.isARepeat { state.close() }
                    return nil
                }
                .accessibilityHidden(true)
    }
}

/// One enum: what it is, its state machine, its values, and what uses it.
@MainActor
struct SimEnumDetailPanel: View {
    let model: AppModel
    let sim: Simulation
    let def: EnumDef
    let highlight: String?
    let width: CGFloat
    let maxHeight: CGFloat
    var still = false
    @State private var hovered: String?
    @State private var contentHeight: CGFloat = 400

    private var state: SimEnumState { SimEnumState.of(model) }
    private var index: SimEnumIndex { SimEnumIndex.of(sim) }

    var body: some View {
        let height = min(contentHeight, maxHeight)
        Group {
            if still {
                content.frame(width: width, height: height, alignment: .top).clipped()
            } else {
                ScrollView { content }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(width: width, height: height)
            }
        }
        .background(Theme.overlay, in: RoundedRectangle(cornerRadius: Theme.radius + 2, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius + 2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius + 2, style: .continuous).strokeBorder(Theme.borderStrong).allowsHitTesting(false))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(def.label) enum")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let doc = def.doc {
                Text(doc).font(Theme.ui(12.5)).foregroundStyle(Theme.muted).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !def.transitions.isEmpty { machine }
            let wide = width >= 700
            if wide {
                HStack(alignment: .top, spacing: 18) {
                    valuesTable.frame(maxWidth: .infinity, alignment: .leading)
                    usedBy.frame(width: 248, alignment: .leading)
                }
            } else {
                valuesTable
                usedBy
            }
        }
        .padding(16)
        .frame(width: width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = ceil($0) }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "tag")
                .font(Theme.ui(13, .semibold)).foregroundStyle(simEnumTint).frame(width: 32, height: 32)
                .background(simEnumTint.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
            VStack(alignment: .leading, spacing: 3) {
                Text(def.label).font(Theme.heading).foregroundStyle(Theme.text)
                Text(summary).font(Theme.mono(10.5)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            ForEach(def.code, id: \.self) { path in
                SimButton(title: (path as NSString).lastPathComponent, icon: "chevron.left.forwardslash.chevron.right") {
                    model.openCode(path, repo: sim.manifest.repo)
                }
            }
            Text("Esc").font(Theme.mono(10)).foregroundStyle(Theme.faint)
            SimButton(title: "Close", icon: "xmark", iconOnly: true) { state.close() }
        }
    }

    private var summary: String {
        let values = def.values.count, transitions = def.transitions.count
        return "\(def.id) · \(values) \(values == 1 ? "value" : "values")" +
            (transitions == 0 ? "" : " · \(transitions) \(transitions == 1 ? "transition" : "transitions")")
    }

    // MARK: State machine

    private var machine: some View {
        let layout = SimEnumDiagramLayout(def)
        let diagram = SimEnumDiagram(def: def, layout: layout, highlight: highlight, hovered: hovered,
                                     select: { state.highlight(highlight == $0 ? nil : $0) },
                                     hover: { hovered = $0 },
                                     openActor: { SimEnumNav.open(actor: $0, sim: sim, model: model) },
                                     actorTitle: index.actorTitle)
        let available = width - 32
        return VStack(alignment: .leading, spacing: 8) {
            Group {
                if layout.size.width <= available {
                    diagram.frame(maxWidth: .infinity)
                } else if still {
                    // Stills can't scroll: shrink to fit.
                    diagram.scaleEffect(available / layout.size.width, anchor: .topLeading)
                        .frame(width: available, height: layout.size.height * available / layout.size.width, alignment: .topLeading)
                } else {
                    ScrollView(.horizontal) { diagram }.scrollIndicators(.never)
                }
            }
            .padding(.vertical, 6)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
            legend
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem("start") {
                HStack(spacing: 0) {
                    Circle().fill(Theme.muted).frame(width: 6, height: 6)
                    Rectangle().fill(Theme.muted).frame(width: 9, height: 1.2)
                }
            }
            legendItem("terminal") {
                RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.borderStrong).frame(width: 15, height: 11)
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.borderStrong).padding(2.5))
            }
            if def.lifecycle().back.isEmpty == false {
                legendItem("goes back") {
                    Path { path in path.move(to: CGPoint(x: 0, y: 5)); path.addLine(to: CGPoint(x: 16, y: 5)) }
                        .stroke(Theme.text.opacity(0.4), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                        .frame(width: 16, height: 10)
                }
            }
            Spacer(minLength: 0)
            Text("Click a value to follow it · click by to open who moves it").font(Theme.ui(10.5)).foregroundStyle(Theme.faint)
                .lineLimit(1)
        }
    }

    private func legendItem<Mark: View>(_ title: String, @ViewBuilder mark: () -> Mark) -> some View {
        HStack(spacing: 5) {
            mark()
            Text(title).font(Theme.ui(10.5)).foregroundStyle(Theme.muted)
        }
    }

    // MARK: Values

    private var valuesTable: some View {
        let coded = def.values.contains { $0.value != $0.name }
        let starts = Set(def.values.map(\.value).filter { code in
            def.transitions(to: code).allSatisfy { $0.from == code } && def.transitions(from: code).contains { $0.to != code }
        })
        return VStack(alignment: .leading, spacing: 8) {
            Text("Values").font(Theme.ui(11, .semibold)).foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(def.values.enumerated()), id: \.offset) { offset, value in
                    if offset > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                    SimEnumValueRow(value: value, coded: coded, codeWidth: coded ? codeColumnWidth : 0,
                                    start: starts.contains(value.value), next: nextNames(value),
                                    highlighted: highlight == value.value, hovered: hovered == value.value) {
                        state.highlight(highlight == value.value ? nil : value.value)
                    } hover: { inside in
                        if inside { hovered = value.value } else if hovered == value.value { hovered = nil }
                    }
                }
            }
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border).allowsHitTesting(false))
        }
    }

    private var codeColumnWidth: CGFloat {
        max(28, CGFloat(def.values.map(\.value.count).max() ?? 0) * 6.7 + 4)
    }

    private func nextNames(_ value: EnumValue) -> [String] {
        def.transitions(from: value.value).compactMap { def.value($0.to)?.name }
    }

    // MARK: Used by

    @ViewBuilder
    private var usedBy: some View {
        let usage = index.usage(def.id)
        VStack(alignment: .leading, spacing: 12) {
            if !usage.columns.isEmpty {
                SimSection(title: "Columns") {
                    SimOpsChips {
                        ForEach(Array(usage.columns.enumerated()), id: \.offset) { _, column in
                            SimDataChipButton(title: columnTitle(column), symbol: "tablecells", mono: true) {
                                SimEnumNav.open(column, sim: sim, model: model)
                            }
                            .accessibilityHint("Opens the table")
                        }
                    }
                }
            }
            if !usage.ops.isEmpty {
                SimSection(title: "Used by") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(usage.ops.enumerated()), id: \.offset) { offset, use in
                            if offset > 0 { Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 28) }
                            SimEnumOpRow(use: use, op: operation(use), nodeLabel: nodeLabel(use), def: def, highlight: highlight) {
                                SimEnumNav.open(op: use.op, node: use.node, path: use.path, sim: sim, model: model)
                            }
                        }
                    }
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border).allowsHitTesting(false))
                }
            }
            if usage.columns.isEmpty && usage.ops.isEmpty {
                Text("No column links to this enum yet. Add enum: \(def.id) to a column.")
                    .font(Theme.small).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func columnTitle(_ column: EnumColumn) -> String {
        let level = column.path.map { SimOpsPath.crumb($0, in: nil) }.joined(separator: " › ")
        return (level.isEmpty ? "" : level + " › ") + "\(column.column.table).\(column.column.column)"
    }

    private func operation(_ use: EnumUsage.OpUse) -> StrataCore.Operation? {
        sim.manifest.level(at: use.path)?.node(use.node)?.ops.first { $0.id == use.op }
    }

    private func nodeLabel(_ use: EnumUsage.OpUse) -> String {
        sim.manifest.level(at: use.path)?.node(use.node)?.label ?? use.node
    }
}

/// `20  paid  The provider captured the payment.  → shipped, cancelled`.
@MainActor
private struct SimEnumValueRow: View {
    let value: EnumValue
    let coded: Bool
    let codeWidth: CGFloat
    let start: Bool
    let next: [String]
    let highlighted: Bool
    let hovered: Bool
    let tap: () -> Void
    let hover: (Bool) -> Void

    var body: some View {
        Button(action: tap) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if coded {
                    Text(value.value).font(Theme.mono(11, .semibold)).foregroundStyle(highlighted ? Theme.accent : Theme.text)
                        .frame(width: codeWidth, alignment: .leading)
                }
                Text(value.name).font(Theme.ui(12, .semibold)).foregroundStyle(coded ? Theme.text : highlighted ? Theme.accent : Theme.text)
                    .frame(minWidth: 70, alignment: .leading)
                    .fixedSize()
                VStack(alignment: .leading, spacing: 2) {
                    if let doc = value.doc {
                        Text(doc).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    if !next.isEmpty {
                        Text("→ " + next.joined(separator: ", ")).font(Theme.ui(10.5)).foregroundStyle(Theme.faint)
                    }
                }
                Spacer(minLength: 4)
                if value.terminal { SimEnumFlag(title: "terminal", symbol: "circle.circle") }
                else if start { SimEnumFlag(title: "start", symbol: "smallcircle.filled.circle") }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? Theme.accent.opacity(0.10) : hovered ? Theme.hover : .clear)
            .overlay(alignment: .leading) { if highlighted { Rectangle().fill(Theme.accent).frame(width: 2) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover(perform: hover)
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }
}

/// An op that uses the enum: its node, its label, and the values its text names.
@MainActor
private struct SimEnumOpRow: View {
    let use: EnumUsage.OpUse
    let op: StrataCore.Operation?
    let nodeLabel: String
    let def: EnumDef
    let highlight: String?
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: op?.kind.symbol ?? "circle").font(Theme.ui(10)).foregroundStyle(Theme.muted).frame(width: 14)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(nodeLabel).font(Theme.ui(11, .medium)).foregroundStyle(Theme.muted).lineLimit(1).fixedSize()
                        Text(op?.label ?? use.op).font(Theme.ui(12, .medium)).foregroundStyle(hovered ? Theme.text : Theme.text.opacity(0.9))
                            .lineLimit(1).truncationMode(.tail)
                    }
                    if !use.values.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(use.values, id: \.self) { code in
                                let name = def.value(code).map { $0.name == $0.value ? $0.name : "\(code) \($0.name)" } ?? code
                                Text(name).font(Theme.mono(9.5, .medium))
                                    .foregroundStyle(code == highlight ? Theme.accent : Theme.muted)
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background((code == highlight ? Theme.accent : Theme.muted).opacity(0.10), in: RoundedRectangle(cornerRadius: 3))
                                    .lineLimit(1).fixedSize()
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(Theme.ui(9, .semibold)).foregroundStyle(hovered ? Theme.muted : Theme.faint)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(hovered ? Theme.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("\(nodeLabel), \(op?.label ?? use.op)")
        .accessibilityHint("Opens the operation")
    }
}

// MARK: - Inspector and chips

/// A node whose tables hold enums: `Enums  Order status · Payment status`, each opening its detail.
@MainActor
struct SimEnumInspectorRow: View {
    let model: AppModel
    let sim: Simulation
    let node: Node

    var body: some View {
        let index = SimEnumIndex.of(sim)
        let enums = index.enums(of: node)
        if !enums.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Enums").font(Theme.ui(11, .semibold)).foregroundStyle(Theme.muted)
                SimOpsChips {
                    ForEach(enums) { def in
                        SimEnumChip(title: def.label) {
                            SimEnumState.of(model).open(index, enumID: def.id, value: nil, model: model)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A column's enum in the table view: opens the enum.
@MainActor
struct SimEnumColumnChip: View {
    let enumID: String
    @Environment(\.simEnums) private var scope

    var body: some View {
        if let scope, let def = scope.index.def(enumID) {
            SimEnumChip(title: def.label, compact: true) { scope.open(enumID, value: nil) }
                .accessibilityHint("Opens the enum's values and state machine")
        }
    }
}

/// A violet chip with a tag glyph.
@MainActor
struct SimEnumChip: View {
    let title: String
    var compact = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "tag").font(Theme.ui(compact ? 8 : 9, .semibold))
                Text(title).font(Theme.ui(compact ? 10.5 : 11, .medium)).lineLimit(1)
            }
            .foregroundStyle(simEnumTint)
            .padding(.horizontal, compact ? 5 : 7).padding(.vertical, compact ? 1.5 : 3)
            .background(simEnumTint.opacity(hovered ? 0.2 : 0.11), in: RoundedRectangle(cornerRadius: compact ? 4 : 5))
            .overlay(RoundedRectangle(cornerRadius: compact ? 4 : 5).strokeBorder(simEnumTint.opacity(hovered ? 0.36 : 0.2)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .fixedSize()
    }
}
