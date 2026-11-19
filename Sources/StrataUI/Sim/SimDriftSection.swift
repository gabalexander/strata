import AppKit
import SwiftUI
import StrataCore

// The inspector's Drift sections (docs/design.md, Drift): the map-level summary with nothing selected,
// and the findings of the selected node or op. Quiet by design: nothing shows for a map without a repo,
// one faint line when the repo isn't on this Mac, and a clean map is a single muted line.

/// With nothing selected: freshness, counts by kind, this level's findings and what the repo has that
/// the map doesn't, with Check again and a prompt for the agent that maintains the map.
@MainActor
struct SimDriftOverview: View {
    let model: AppModel
    let sim: Simulation
    let select: (StageSelection?) -> Void
    @State private var expanded = false
    @State private var kind: DriftKind?
    @State private var showUnmapped = false

    var body: some View {
        let state = SimDriftState.of(model)
        let manifest = sim.manifest
        if manifest.repo != nil, let entry = state.entry(manifest.id) {
            if let missing = entry.missingRepo {
                Text("Drift isn’t checked: \(missing) isn’t on this Mac.")
                    .font(Theme.small).foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let report = entry.report {
                section(report, running: entry.running)
            } else if entry.running {
                SimSection(title: "Drift") {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.mini)
                        Text("Comparing with the repo…").font(Theme.small).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
    }

    private func section(_ report: DriftReport, running: Bool) -> some View {
        let s = report.summary
        let here = levelFindings(report)
        let shown = here.filter { kind == nil || $0.kind == kind }
        let unmapped = report.findings.filter(\.isUnmapped)
        return SimSection(title: "Drift") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if report.isClean {
                        Label("Matches the repo", systemImage: "checkmark").font(Theme.ui(12, .medium)).foregroundStyle(Theme.muted)
                    } else {
                        Text("\(s.freshness)% fresh").font(Theme.ui(12, .semibold)).foregroundStyle(Theme.text)
                        Text(counts(s)).font(Theme.ui(11)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if running { ProgressView().controlSize(.mini) }
                    SimButton(title: "Check again", icon: SimDriftMenus.icon, iconOnly: true) {
                        SimDriftState.of(model).check(sim.manifest, manual: true)
                    }
                    .disabled(running)
                }
                Text(checked(report)).font(Theme.mono(10.5)).foregroundStyle(Theme.faint).lineLimit(1).truncationMode(.middle)
                if !report.isClean {
                    kinds(s)
                    if !shown.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(shown.prefix(expanded ? shown.count : 5).enumerated()), id: \.element.id) { index, finding in
                                if index > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                                SimDriftRow(model: model, sim: sim, finding: finding, select: select, showPlace: true)
                            }
                        }
                        .padding(.horizontal, 9)
                        .card()
                        if shown.count > 5 {
                            SimButton(title: expanded ? "Show fewer" : "Show all \(shown.count)", icon: expanded ? "chevron.up" : "chevron.down") {
                                expanded.toggle()
                            }
                        }
                    } else if here.isEmpty {
                        Text(sim.path.isEmpty ? "Nothing the map says has drifted; the repo has more than it shows."
                                              : "Nothing at this level has drifted.")
                            .font(Theme.small).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !unmapped.isEmpty && sim.path.isEmpty {
                    Button { showUnmapped.toggle() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: showUnmapped ? "chevron.down" : "chevron.right").font(Theme.ui(9, .semibold))
                            Text("Not on the map: " + unmappedSummary(unmapped)).font(Theme.small)
                        }
                        .foregroundStyle(Theme.muted)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showUnmapped {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(unmapped.prefix(40).enumerated()), id: \.element.id) { index, finding in
                                if index > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                                SimDriftRow(model: model, sim: sim, finding: finding, select: select, showPlace: false)
                            }
                        }
                        .padding(.horizontal, 9)
                        .card()
                    }
                }
                if !report.isClean || !unmapped.isEmpty {
                    SimButton(title: "Copy prompt for your agent", icon: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(SimDriftState.agentPrompt(sim.manifest, report: report), forType: .string)
                        model.overlays.toast("Copied a prompt for your agent")
                    }
                }
            }
        }
    }

    /// Findings at this level or below, then (at the root) the map-wide ones (enums).
    private func levelFindings(_ report: DriftReport) -> [DriftFinding] {
        report.findings.filter { finding in
            guard !finding.isUnmapped, let map = finding.map else { return false }
            if map.enumID != nil { return sim.path.isEmpty }
            return map.level.count >= sim.path.count && Array(map.level.prefix(sim.path.count)) == sim.path
        }
    }

    private func kinds(_ s: DriftSummary) -> some View {
        SimOpsChips {
            ForEach(s.kinds.filter { $0.errors + $0.warnings > 0 }, id: \.kind) { row in
                let on = kind == row.kind
                Button { kind = on ? nil : row.kind } label: {
                    Text("\(row.kind.rawValue) \(row.errors + row.warnings)")
                        .font(Theme.mono(10.5, .medium))
                        .foregroundStyle(on ? Theme.accent : row.errors > 0 ? Theme.text : Theme.muted)
                        .padding(.horizontal, 7).frame(height: 20)
                        .background(on ? Theme.accent.opacity(0.12) : Theme.hover, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(on ? Theme.accent.opacity(0.3) : Theme.border))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private func counts(_ s: DriftSummary) -> String {
        [s.errors > 0 ? "\(s.errors) \(s.errors == 1 ? "error" : "errors")" : nil,
         s.warnings > 0 ? "\(s.warnings) \(s.warnings == 1 ? "warning" : "warnings")" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func checked(_ report: DriftReport) -> String {
        let seconds = Date().timeIntervalSince(report.checkedAt)
        let ago = seconds < 60 ? "just now" : RelativeDateTimeFormatter().localizedString(for: report.checkedAt, relativeTo: Date())
        return (["checked \(ago)", report.head.map { String($0.prefix(7)) }, "\(report.files) files"].compactMap { $0 })
            .joined(separator: " · ")
    }

    private func unmappedSummary(_ findings: [DriftFinding]) -> String {
        let groups: [(DriftKind, String, String)] = [(.sql, "query", "queries"), (.binaries, "binary", "binaries"), (.messaging, "name", "names")]
        return groups.compactMap { kind, one, many in
            let n = findings.filter { $0.kind == kind }.count
            return n == 0 ? nil : "\(n) \(n == 1 ? one : many)"
        }.joined(separator: ", ")
    }
}

/// The selected node's findings: its own, then those inside its deep dives.
@MainActor
struct SimDriftNodeSection: View {
    let model: AppModel
    let sim: Simulation
    let node: Node
    let select: (StageSelection?) -> Void

    var body: some View {
        let state = SimDriftState.of(model)
        let _ = state.revision
        if let report = state.report(sim.manifest.id) {
            let findings = report.findings(level: sim.path, node: node.id).filter { $0.severity != .info || $0.map?.level == sim.path }
            if !findings.isEmpty {
                SimSection(title: "Drift") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(findings.prefix(12).enumerated()), id: \.element.id) { index, finding in
                            if index > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                            SimDriftRow(model: model, sim: sim, finding: finding, select: select, showPlace: true, relativeTo: node.id)
                        }
                        if findings.count > 12 {
                            Text("+\(findings.count - 12) more in the overview").font(Theme.small).foregroundStyle(Theme.faint).padding(.vertical, 7)
                        }
                    }
                    .padding(.horizontal, 9)
                    .card()
                }
            }
        }
    }
}

/// An op's findings, in its detail.
@MainActor
struct SimDriftOpSection: View {
    let model: AppModel
    let sim: Simulation
    /// The level the op's node is on (the owner's level for an inherited op).
    let level: [String]
    let node: String
    let op: String

    var body: some View {
        let state = SimDriftState.of(model)
        let _ = state.revision
        if let report = state.report(sim.manifest.id) {
            let findings = report.findings.filter { $0.map?.level == level && $0.map?.node == node && $0.map?.op == op }
            if !findings.isEmpty {
                SimSection(title: "Drift") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(findings.enumerated()), id: \.element.id) { index, finding in
                            if index > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                            SimDriftRow(model: model, sim: sim, finding: finding, select: { _ in }, showPlace: false)
                        }
                    }
                    .padding(.horizontal, 9)
                    .card()
                }
            }
        }
    }
}

/// One finding: a severity dot and the message, where it is in the map (a link to that node) and in the
/// repo (opens the code), the fix, and a changed query's diff.
@MainActor
struct SimDriftRow: View {
    let model: AppModel
    let sim: Simulation
    let finding: DriftFinding
    let select: (StageSelection?) -> Void
    var showPlace = true
    /// The selected node: its own findings drop the node from the place line.
    var relativeTo: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(tint).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 4) {
                Text(finding.message).font(Theme.ui(12)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if showPlace, let map = finding.map, let place = place(map) {
                    Button { reveal(map) } label: {
                        Text(place).font(Theme.mono(10.5)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .disabled(map.node == nil)
                }
                if let repo = finding.repo {
                    codeLink(repo.description, exists: finding.rule != "missing-file")
                }
                if let found = finding.found, found.contains("/") || found.contains(".") {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.turn.down.right").font(Theme.ui(9)).foregroundStyle(Theme.faint)
                        codeLink(found, exists: true)
                    }
                }
                if let diff = finding.diff, !diff.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(diff.enumerated()), id: \.offset) { _, line in
                            Text(line).font(Theme.mono(10.5))
                                .foregroundStyle(line.hasPrefix("+") ? Theme.good : line.hasPrefix("-") ? Theme.bad : Theme.faint)
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                    .textSelection(.enabled)
                }
                // "Point code at x." says no more than the link to x above it.
                if finding.found.map({ finding.fix != "Point code at \($0)." }) ?? true {
                    Text(finding.fix).font(Theme.small).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    private var tint: Color {
        switch finding.severity {
        case .error: Theme.bad
        case .warn: Theme.warn
        case .info: Theme.faint
        }
    }

    private func codeLink(_ text: String, exists: Bool) -> some View {
        Button { model.openCode(text, repo: sim.manifest.repo) } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left.forwardslash.chevron.right").font(Theme.ui(9))
                Text(text).font(Theme.mono(10.5)).lineLimit(1).truncationMode(.middle)
                    .strikethrough(!exists, color: Theme.faint)
            }
            .foregroundStyle(exists ? Theme.info : Theme.faint)
        }
        .buttonStyle(.plain)
        .disabled(!exists)
        .accessibilityLabel(exists ? "Open \(text)" : "\(text), gone")
    }

    /// Where in the map, relative to this level: `orders › handler · op insert-order (code)`; without the
    /// node when it is the selected one.
    private func place(_ map: DriftMapLocation) -> String? {
        var relative = map
        if map.enumID == nil, map.level.count >= sim.path.count, Array(map.level.prefix(sim.path.count)) == sim.path {
            relative.level = Array(map.level.dropFirst(sim.path.count))
        }
        if relative.level.isEmpty, let relativeTo, relative.node == relativeTo {
            relative.node = nil
            if relative.op == nil, relative.mechanism == nil, relative.step == nil { return nil }
        }
        return relative.description
    }

    /// Selects the finding's node, opening the level that holds it first when it is another one.
    private func reveal(_ map: DriftMapLocation) {
        guard let node = map.node else { return }
        if map.level == sim.path {
            select(.node(node))
        } else {
            SimFocus.of(model).reveal(node, in: sim.manifest.id, path: map.level, model: model)
        }
    }
}
