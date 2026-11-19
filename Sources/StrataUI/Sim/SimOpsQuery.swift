import AppKit
import Observation
import SwiftUI
import StrataCore

/// Formatted queries, once per query text. The op detail re-renders on every selection change, and
/// formatting is the one part of it that isn't a lookup.
@MainActor
enum SimOpsQueryCache {
    struct Formatted {
        let statements: [SQLFormat.Statement]
        /// The statements as one text, separated by a blank line: what Copy copies.
        let text: String
        /// Formatting changed more than trailing whitespace, so the raw / formatted toggle is worth showing.
        let changed: Bool
        var work: [SQLFormat.Statement] { statements.filter { !$0.isTransactionControl } }
    }

    /// Lines longer than this wrap in the inspector's code blocks (11 pt mono in a 320 pt inspector).
    static let width = 40

    private static var cache: [String: Formatted?] = [:]

    /// Nil when the text doesn't read as SQL (a JSON search body, a description): it is shown as written.
    static func formatted(_ source: String) -> Formatted? {
        if let hit = cache[source] { return hit }
        var result: Formatted?
        if SQLFormat.looksLikeSQL(source) {
            let statements = SQLFormat.statements(source, width: width)
            let text = statements.map(\.text).joined(separator: "\n\n")
            func normalized(_ s: String) -> String {
                s.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
                    .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            result = Formatted(statements: statements, text: text, changed: normalized(text) != normalized(source))
        }
        if cache.count > 512 { cache.removeAll(keepingCapacity: true) }
        cache[source] = result
        return result
    }
}

/// Which ops show their query as written instead of formatted, per session.
@MainActor
@Observable
final class SimOpsQueryMode {
    private(set) var raw: Set<OpRef> = []

    private static let stores = NSMapTable<Simulation, SimOpsQueryMode>.weakToStrongObjects()

    static func of(_ sim: Simulation) -> SimOpsQueryMode {
        if let store = stores.object(forKey: sim) { return store }
        let store = SimOpsQueryMode()
        stores.setObject(store, forKey: sim)
        return store
    }

    func setRaw(_ ref: OpRef, _ on: Bool) {
        if on { raw.insert(ref) } else { raw.remove(ref) }
    }
}

/// An op's query, formatted: each statement of a multi-statement query in its own numbered block, the
/// `BEGIN`/`COMMIT` around them as small markers, and a toggle back to the text as written.
@MainActor
struct SimOpsQueryBlock: View {
    let title: String
    let source: String
    let formatted: SimOpsQueryCache.Formatted
    let ref: OpRef
    let sim: Simulation
    let overlays: Overlays
    var still = false
    @State private var hovered = false

    /// The hook every statement's text goes through, plain text in and styled text out: keyword, string
    /// and parameter colours. `code` then shows it with `SimEnumCodeText`, which finds enum values on
    /// this displayed text, so formatted statements get the underlines and hover cards too.
    static func highlight(_ statement: String) -> AttributedString { SimOpsCode.sql(statement) }

    var body: some View {
        let raw = formatted.changed && SimOpsQueryMode.of(sim).raw.contains(ref)
        VStack(alignment: .leading, spacing: 7) {
            header(raw: raw)
            if raw {
                code(Self.highlight(source), copy: source, number: nil)
            } else {
                let total = formatted.work.count
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(numbered.enumerated()), id: \.offset) { _, entry in
                        if let number = entry.number {
                            code(Self.highlight(entry.statement.text), copy: entry.statement.text,
                                 number: total > 1 ? "\(number) of \(total)" : nil)
                        } else {
                            marker(entry.statement.text)
                        }
                    }
                }
            }
        }
    }

    /// Each statement with its number among the real work; transaction control has none.
    private var numbered: [(statement: SQLFormat.Statement, number: Int?)] {
        var count = 0
        return formatted.statements.map { statement in
            if statement.isTransactionControl { return (statement, nil) }
            count += 1
            return (statement, count)
        }
    }

    private func header(raw: Bool) -> some View {
        let total = formatted.work.count
        // BEGIN and COMMIT show as markers, so the caption only counts statements.
        let caption = total > 1 ? "\(total) statements" : ""
        return HStack(spacing: 6) {
            Text(title).font(Theme.ui(11, .semibold)).foregroundStyle(Theme.muted)
            if !caption.isEmpty { Text(caption).font(Theme.mono(10)).foregroundStyle(Theme.faint).lineLimit(1) }
            Spacer(minLength: 0)
            if formatted.changed {
                SimOpsQueryToggle(raw: raw) { SimOpsQueryMode.of(sim).setRaw(ref, $0) }
            }
            Button { copy(raw ? source : formatted.text, "Copied query") } label: {
                Image(systemName: "doc.on.doc")
                    .font(Theme.ui(10, .medium))
                    .foregroundStyle(hovered ? Theme.text : Theme.muted)
                    .frame(width: 22, height: 20)
                    .background(hovered ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .accessibilityLabel(raw ? "Copy query as written" : "Copy formatted query")
        }
        .frame(height: 20)
    }

    private func code(_ text: AttributedString, copy value: String, number: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let number {
                Text(number).font(Theme.mono(9.5, .medium)).foregroundStyle(Theme.faint)
            }
            SimEnumCodeText(text)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.text)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .simOpsMenu(still: still) { point in
                    let title = number == nil ? "Copy query" : "Copy statement"
                    overlays.showMenu([MenuItem(title, icon: "doc.on.doc") { copy(value, title.replacingOccurrences(of: "Copy", with: "Copied")) }],
                                      at: point)
                }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .card(Theme.bg, radius: Theme.radiusSmall)
    }

    /// `BEGIN;` and `COMMIT;`: the edges of the transaction, not statements to read.
    private func marker(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath").font(Theme.ui(9, .medium))
            Text(text).font(Theme.mono(10.5, .medium)).lineLimit(1)
        }
        .foregroundStyle(Theme.info.opacity(0.85))
        .padding(.leading, 10)
        .frame(height: 16)
    }

    private func copy(_ value: String, _ toast: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        overlays.toast(toast)
    }
}

/// "Formatted | Raw", small enough to sit in a code block's header.
@MainActor
private struct SimOpsQueryToggle: View {
    let raw: Bool
    let set: (Bool) -> Void

    var body: some View {
        HStack(spacing: 1) {
            segment("Formatted", selected: !raw) { set(false) }
            segment("Raw", selected: raw) { set(true) }
        }
        .padding(1.5)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border))
    }

    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.ui(10, .medium))
                .foregroundStyle(selected ? Theme.text : Theme.muted)
                .padding(.horizontal, 6)
                .frame(height: 16)
                .background(selected ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(title == "Raw" ? "Show the query as written" : "Show the query formatted")
    }
}

/// Offscreen snapshots: show an op's query as written.
@_spi(Snapshots) @MainActor
public enum SimOpsQuerySnapshot {
    public static func showRaw(_ sim: Simulation, node: String, op: String) {
        SimOpsQueryMode.of(sim).setRaw(OpRef(node: node, op: op), true)
    }
}
