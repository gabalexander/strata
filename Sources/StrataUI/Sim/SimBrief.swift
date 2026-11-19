import SwiftUI
import StrataCore

// Brief first, detail on demand (docs/design.md, Explain in place): a node, op, flow, mechanism or level
// shows its one-line `brief` (or the short form of a long text) and keeps the rest behind a quiet
// "More" that opens in place. A short text without a brief shows as it is, with no disclosure.

/// Which "More" disclosures are open, for the app session. Keyed by manifest, level and item, so an item
/// stays open across selections, deep dives and reloads.
@MainActor
@Observable
final class SimBriefMemory {
    static let shared = SimBriefMemory()
    private(set) var open: Set<String> = []
    /// Offscreen snapshots: every disclosure starts open.
    var openAll = false

    func isOpen(_ key: String) -> Bool { openAll || open.contains(key) }

    func toggle(_ key: String) {
        if open.contains(key) { open.remove(key) } else { open.insert(key) }
    }
}

/// The keys of `SimBriefMemory`: the item, within its manifest and level.
@MainActor
enum SimBriefKey {
    static func level(_ sim: Simulation) -> String { scope(sim) + "level" }
    static func node(_ sim: Simulation, _ id: String) -> String { scope(sim) + "node:" + id }
    static func op(_ sim: Simulation, node: String, op: String) -> String { scope(sim) + "op:\(node)/\(op)" }
    static func mechanism(_ sim: Simulation, _ ref: SimHowRef) -> String {
        scope(sim) + "how:\(ref.node)/\(ref.op ?? "")/\(ref.mechanism)"
    }
    static func step(_ sim: Simulation, _ ref: SimHowRef, branch: String?, step: String) -> String {
        mechanism(sim, ref) + "#\(branch ?? "")/\(step)"
    }
    /// Anything else with a doc, such as a table (`table:orders-db.orders`) or an entity.
    static func item(_ sim: Simulation, _ id: String) -> String { scope(sim) + id }

    private static func scope(_ sim: Simulation) -> String {
        sim.manifest.id + "|" + sim.path.joined(separator: "/") + "|"
    }
}

/// The brief (or the short form of a long text), then "More" for the rest, with glossary terms and
/// links working in both. An author's brief leads in the text colour and stays above the rest when it
/// opens; a short form is replaced by the whole text.
@MainActor
struct SimBriefText: View {
    let brief: String?
    let detail: String?
    let key: String
    let model: AppModel
    let terms: TermIndex
    /// The colour of the longer text (and of a short form).
    var color = Theme.muted
    /// The colour of an author's brief.
    var leadColor = Theme.text.opacity(0.9)
    var size: CGFloat = 13

    var body: some View {
        if let parts = Brief.parts(brief: brief, detail: detail) {
            let open = parts.more != nil && SimBriefMemory.shared.isOpen(key)
            VStack(alignment: .leading, spacing: 5) {
                if parts.leadIsBrief {
                    SimMarkdown(source: parts.lead, model: model, terms: terms, color: leadColor, size: size)
                } else if !open {
                    // A short form is about two lines; a narrow panel ends it a little sooner.
                    SimMarkdown(source: parts.lead, model: model, terms: terms, color: color, size: size,
                                lineLimit: parts.more == nil ? nil : 2)
                }
                if open, let more = parts.more {
                    SimMarkdown(source: more, model: model, terms: terms, color: color, size: size)
                }
                if parts.more != nil {
                    SimMoreButton(open: open) { SimBriefMemory.shared.toggle(key) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A brief for a card that isn't interactive (a hover card, the processes card): `[[target|label]]`
/// links become their label.
enum SimBriefPlain {
    static func text(_ markdown: String) -> String {
        markdown.replacing(#/\[\[([^\]\n|]+)(?:\|([^\]\n]+))?\]\]/#) { match in String(match.2 ?? match.1) }
    }
}

/// The quiet disclosure under a brief: "More ⌄" or "Less ⌃".
@MainActor
struct SimMoreButton: View {
    let open: Bool
    let toggle: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 3) {
                Text(open ? "Less" : "More")
                Image(systemName: open ? "chevron.up" : "chevron.down").font(Theme.ui(8, .semibold))
            }
            .font(Theme.ui(11, .medium))
            .foregroundStyle(hovered ? Theme.accent : Theme.faint)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .pointerStyle(.link)
        .accessibilityLabel(open ? "Show less" : "Show more")
    }
}

/// Offscreen snapshots: open every "More".
@_spi(Snapshots) @MainActor
public enum SimBriefSnapshot {
    public static func openAll(_ on: Bool = true) { SimBriefMemory.shared.openAll = on }

    /// Hovers a node's card as the pointer would: the processes card for a card with process chips,
    /// else its term, formula or brief card.
    public static func hoverNode(_ sim: Simulation, node: String) {
        if let card = sim.level.node(node), StageLayout.hasChips(card) {
            SimComponentsSnapshot.hover(sim, node: node)
        } else {
            SimFormulaStage.requestedHover[ObjectIdentifier(sim)] = node
        }
    }
}
