import SwiftUI
import StrataCore

// Enum values where they appear: a grid cell (`3200 · scheduled`), a value in a query or payload
// (a dotted underline), and the hover card both lead to. Hovering shows the card after a short delay;
// clicking opens the enum's detail with the value highlighted.

/// A sample value of an enum column: the value, then its name, faint (`3200 · scheduled`). String
/// enums whose values are their names show the value alone. The dotted underline says it explains itself.
struct SimEnumValueLabel: View {
    let literal: String
    let shown: String
    let def: EnumDef
    var tint: Color = Theme.text
    var weight: Font.Weight = .regular
    var size: CGFloat = 11

    var body: some View {
        let value = def.value(literal)
        let name = value.flatMap { $0.name == $0.value ? nil : $0.name }
        let mark = Text(shown).font(Theme.mono(size, weight)).foregroundStyle(tint)
            .underline(true, pattern: .dot, color: Theme.accent.opacity(0.55))
        if let name {
            Text("\(mark)\(Text(" · \(name)").font(Theme.mono(size)).foregroundStyle(Theme.faint))")
        } else if value == nil {
            Text("\(mark)\(Text(" · ?").font(Theme.mono(size)).foregroundStyle(Theme.warn.opacity(0.8)))")
        } else {
            mark
        }
    }

    /// The label's width in SF Mono (0.6 em), for stills that can't measure a scroll view.
    static func estimatedCharacters(_ literal: String, shown: String, def: EnumDef) -> Int {
        guard let value = def.value(literal) else { return shown.count + 4 }
        return shown.count + (value.name == value.value ? 0 : value.name.count + 3)
    }
}

extension View {
    /// Hovering shows the value's card; a click opens the enum (or runs `tap`, for a key cell).
    func simEnumHover(_ scope: SimEnumScope, enumID: String, literal: String, key: String,
                      tap: (() -> Void)? = nil) -> some View {
        modifier(SimEnumHover(scope: scope, enumID: enumID, literal: literal, key: key, tap: tap))
    }
}

private struct SimEnumHover: ViewModifier {
    let scope: SimEnumScope
    let enumID: String
    let literal: String
    let key: String
    let tap: (() -> Void)?
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background(hovered ? Theme.hover : .clear)
            .overlay {
                GeometryReader { proxy in
                    Color.clear
                        .contentShape(Rectangle())
                        .onHover { inside in
                            hovered = inside
                            let state = scope.state
                            if inside {
                                state.hover(key, index: scope.index, enumID: enumID, literal: literal) { proxy.frame(in: .global) }
                            } else {
                                state.unhover(key)
                            }
                        }
                        .onTapGesture {
                            scope.state.hideCard()
                            if let tap { tap() } else { scope.open(enumID, value: literal) }
                        }
                        .onAppear {
                            let index = scope.index, state = scope.state
                            state.offerPreview(literal) {
                                state.show(index: index, enumID: enumID, literal: literal, anchor: proxy.frame(in: .global))
                            }
                        }
                }
            }
            .onDisappear { scope.state.unhover(key) }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens the enum")
    }
}

// MARK: - Code

/// A query or payload with its enum values underlined: `status = 3200`, `"status": "paid"`. A drop-in
/// for the code block's `Text`; without enums, or with none found, it is that `Text`. The values are
/// found once per text (`SimEnumIndex.occurrences`), and the underline is drawn by the text renderer.
struct SimEnumCodeText: View {
    let text: AttributedString
    @Environment(\.simEnums) private var scope
    @Environment(\.simEnumTables) private var tables
    @State private var layout = SimEnumRunLayout()

    init(_ text: AttributedString) { self.text = text }

    var body: some View {
        if let scope {
            let found = scope.index.occurrences(in: String(text.characters), tables: tables)
            if found.isEmpty {
                Text(text)
            } else {
                // Selectable text is drawn by AppKit, which skips text renderers: the visible text keeps
                // the selection and the links, and a twin laid out the same way on top (not selectable,
                // never hit) draws the underlines and records where the values are.
                Text(linked(found))
                    .overlay(alignment: .topLeading) {
                        marked(found)
                            .textSelection(.disabled)
                            .textRenderer(SimEnumUnderline(layout: layout))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { layout.frame = $0 }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): hover(layout.run(at: point), scope: scope, found: found)
                        case .ended: hover(nil, scope: scope, found: found)
                        }
                    }
                    .environment(\.openURL, OpenURLAction { url in
                        guard url.scheme == "strata-enum", let index = url.host.flatMap(Int.init), found.indices.contains(index) else {
                            return .systemAction
                        }
                        let hit = found[index]
                        scope.open(hit.enumID, value: hit.value ?? hit.literal)
                        return .handled
                    })
                    .onAppear {
                        let state = scope.state, index = scope.index
                        for (offset, hit) in found.enumerated() {
                            state.offerPreview(hit.literal) { [layout] in
                                state.show(index: index, enumID: hit.enumID, literal: hit.literal,
                                           anchor: layout.anchor(for: offset) ?? layout.frame)
                            }
                        }
                    }
                    .onDisappear { if let key = layout.key { scope.state.unhover(key) } }
            }
        } else {
            Text(text)
        }
    }

    /// The text with each value a link (a click opens its enum). Its colours stay the highlighter's.
    private func linked(_ found: [EnumOccurrence]) -> AttributedString {
        var result = text
        for (offset, hit) in found.enumerated() {
            guard let start = AttributedString.Index(hit.range.lowerBound, within: result),
                  let end = AttributedString.Index(hit.range.upperBound, within: result) else { continue }
            result[start..<end].link = URL(string: "strata-enum://\(offset)")
        }
        return result
    }

    /// The same text as one Text whose values carry `SimEnumRun`, for the renderer to find.
    private func marked(_ found: [EnumOccurrence]) -> Text {
        var result = Text(verbatim: "")
        var position = text.startIndex
        for (offset, hit) in found.enumerated() {
            guard let start = AttributedString.Index(hit.range.lowerBound, within: text),
                  let end = AttributedString.Index(hit.range.upperBound, within: text), start >= position else { continue }
            let piece = Text(AttributedString(text[start..<end])).customAttribute(SimEnumRun(index: offset))
            result = Text("\(result)\(Text(AttributedString(text[position..<start])))\(piece)")
            position = end
        }
        return Text("\(result)\(Text(AttributedString(text[position..<text.endIndex])))")
    }

    private func hover(_ run: Int?, scope: SimEnumScope, found: [EnumOccurrence]) {
        let key = run.map { "code.\(ObjectIdentifier(layout).hashValue).\($0)" }
        guard key != layout.key else { return }
        if let previous = layout.key { scope.state.unhover(previous) }
        layout.key = key
        guard let run, let key, found.indices.contains(run) else { return }
        let hit = found[run]
        scope.state.hover(key, index: scope.index, enumID: hit.enumID, literal: hit.literal) { [layout] in
            layout.anchor(for: run) ?? layout.frame
        }
    }
}

/// Marks an enum value inside a code block's Text.
struct SimEnumRun: TextAttribute {
    let index: Int
}

/// Where the values of one code block were drawn, in the block's own coordinates. Written by the text
/// renderer, read by hover; not observed, so neither re-renders anything.
final class SimEnumRunLayout: @unchecked Sendable {
    private let lock = NSLock()
    private var runs: [(rect: CGRect, index: Int)] = []
    var frame = CGRect.zero
    var key: String?

    func set(_ runs: [(rect: CGRect, index: Int)]) {
        lock.lock(); self.runs = runs; lock.unlock()
    }

    func run(at point: CGPoint) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return runs.first { $0.rect.insetBy(dx: -1, dy: -2).contains(point) }?.index
    }

    /// The value's first line, in window coordinates.
    func anchor(for index: Int) -> CGRect? {
        lock.lock(); defer { lock.unlock() }
        return runs.first { $0.index == index }.map { $0.rect.offsetBy(dx: frame.minX, dy: frame.minY) }
    }
}

/// Draws each value's faint dotted underline, as glossary terms have, and records where the values are.
/// The glyphs themselves are the selectable text's underneath.
private struct SimEnumUnderline: TextRenderer {
    let layout: SimEnumRunLayout

    func draw(layout text: Text.Layout, in context: inout GraphicsContext) {
        var runs: [(rect: CGRect, index: Int)] = []
        for line in text {
            for run in line {
                if let mark = run[SimEnumRun.self] {
                    let rect = run.typographicBounds.rect
                    runs.append((rect, mark.index))
                    var underline = Path()
                    underline.move(to: CGPoint(x: rect.minX, y: rect.maxY - 0.5))
                    underline.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 0.5))
                    context.stroke(underline, with: .color(Theme.accent.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [1, 2]))
                }
            }
        }
        layout.set(runs)
    }
}
