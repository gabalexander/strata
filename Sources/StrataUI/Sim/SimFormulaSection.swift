import SwiftUI
import StrataCore

// Formulas in the inspector, on the stage's ƒ badge, and in the hover card (docs/manifest.md, Formulas).

/// The inspector's full formula: the typeset expression, what each variable means, a worked example,
/// the doc and the code.
@MainActor
struct SimFormulaSection: View {
    let formula: Formula
    let model: AppModel
    let terms: TermIndex
    let actions: SimActions

    var body: some View {
        SimSection(title: "Formula") {
            VStack(alignment: .leading, spacing: 0) {
                SimFormulaFit(expr: formula.expr, sizes: [19, 16, 14])
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 16)
                    .background(SimFormulaPlate())
                if !formula.vars.isEmpty {
                    Rectangle().fill(Theme.border).frame(height: 1)
                    SimFormulaWhere(vars: formula.vars, size: 14)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
            }
            .card()
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Formula \(formula.expr)")
            if let example = formula.example { SimFormulaExample(text: example) }
            if let doc = formula.doc { SimMarkdown(source: doc, model: model, terms: terms, size: 12) }
            if !formula.code.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(formula.code, id: \.self) { path in
                        SimButton(title: path, icon: "chevron.left.forwardslash.chevron.right") { actions.openCode(path) }
                    }
                }
            }
        }
        .id("formula")
    }
}

/// The largest size at which the expression fits on one line, else it wraps at the smallest.
@MainActor
struct SimFormulaFit: View {
    let expr: String
    let sizes: [CGFloat]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(sizes, id: \.self) { size in
                SimFormulaText(expr: expr, size: size).fixedSize()
            }
            SimFormulaText(expr: expr, size: sizes.last ?? 14)
        }
    }
}

/// A faint grid behind the expression, like squared paper on the bench.
private struct SimFormulaPlate: View {
    var body: some View {
        Canvas { context, size in
            let pitch: CGFloat = 12
            var dots = Path()
            for x in stride(from: pitch / 2, through: size.width, by: pitch) {
                for y in stride(from: pitch / 2, through: size.height, by: pitch) {
                    dots.addEllipse(in: CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
            context.fill(dots, with: .color(Theme.grid))
        }
        .accessibilityHidden(true)
    }
}

/// `where`: each variable typeset in a column, then what it means.
@MainActor
struct SimFormulaWhere: View {
    let vars: [(name: String, meaning: String)]
    var size: CGFloat = 14
    var limit: Int?

    var body: some View {
        let shown = limit.map { Array(vars.prefix($0)) } ?? vars
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 7) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, item in
                GridRow {
                    SimFormulaText(expr: item.name, size: size)
                        .fixedSize()
                        .gridColumnAlignment(.trailing)
                    Text(item.meaning)
                        .font(Theme.ui(12))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// The worked example in a raised box; the result after the last arrow stands out.
@MainActor
struct SimFormulaExample: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Example", systemImage: "function")
                .font(Theme.label)
                .foregroundStyle(Theme.accent)
            styled
                .font(Theme.mono(11.5))
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.overlay, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(Theme.borderStrong))
    }

    private var styled: Text {
        guard let arrow = text.range(of: "→", options: .backwards) else {
            return Text(verbatim: text).foregroundStyle(Theme.text.opacity(0.86))
        }
        let before = Text(verbatim: String(text[..<arrow.lowerBound])).foregroundStyle(Theme.text.opacity(0.78))
        let symbol = Text(verbatim: "→").foregroundStyle(Theme.accent)
        // The result is the first sentence after the arrow; anything after it is commentary.
        let rest = String(text[arrow.upperBound...])
        let end = rest.range(of: ". ").map { $0.lowerBound } ?? rest.endIndex
        let result = Text(verbatim: String(rest[..<end])).foregroundStyle(Theme.text).fontWeight(.semibold)
        let tail = Text(verbatim: String(rest[end...])).foregroundStyle(Theme.text.opacity(0.78))
        return Text("\(before)\(symbol)\(result)\(tail)")
    }
}

/// The compact card the ƒ badge shows on hover: the expression and the first variables.
@MainActor
struct SimFormulaCard: View {
    let title: String
    let formula: Formula
    var pinned = false
    var close: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                SimFormulaGlyph(size: 18)
                Text(title).font(Theme.ui(12, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text("formula").font(Theme.ui(11)).foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
                if pinned {
                    Button(action: close) {
                        Image(systemName: "xmark").font(Theme.ui(11, .semibold)).foregroundStyle(Theme.muted)
                            .frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close formula")
                }
            }
            SimFormulaFit(expr: formula.expr, sizes: [17, 15, 13])
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 10)
                .padding(.horizontal, 8)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(Theme.border))
            if !formula.vars.isEmpty {
                SimFormulaWhere(vars: formula.vars, size: 13, limit: 3)
            }
            Text(footer).font(Theme.ui(10.5)).foregroundStyle(Theme.faint)
        }
    }

    private var footer: String {
        let more = formula.vars.count - 3
        return (more > 0 ? "\(more) more · " : "") + "click the node for the full formula"
    }
}

/// The ƒ mark used on the stage badge and in the card header.
struct SimFormulaGlyph: View {
    var size: CGFloat = 16

    var body: some View {
        Text(verbatim: "ƒ")
            .font(.system(size: size * 0.72, weight: .semibold, design: .serif).italic())
            .foregroundStyle(Theme.text)
            .frame(width: size, height: size)
            .background(Theme.info.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.info.opacity(0.35)))
            .accessibilityHidden(true)
    }
}

// MARK: - Stage

enum SimFormulaStage {
    /// The ƒ badge in a node card's top-right corner, in world coordinates.
    static func badge(in card: CGRect) -> CGRect {
        CGRect(x: card.maxX - 27, y: card.minY + 8.5, width: 17, height: 15)
    }

    /// Room the badge takes from the title row.
    static func reserved(_ node: Node) -> CGFloat { node.formula == nil ? 0 : 22 }

    /// Whether a point on screen is over the ƒ badge of the hovered node.
    static func onBadge(_ target: StageSelection?, point: CGPoint, camera: StageCamera, layout: StageLayout) -> Bool {
        guard case .node(let id)? = target, let card = layout.cardsByID[id], card.node.formula != nil else { return false }
        return badge(in: card.rect).insetBy(dx: -4, dy: -4).contains(camera.world(point))
    }
}

@MainActor private var badgeLetterLit: GraphicsContext.ResolvedText?
@MainActor private var badgeLetterQuiet: GraphicsContext.ResolvedText?

extension StageRenderer {
    /// Draws the ƒ badge of a node that computes a formula.
    func drawFormulaBadge(on card: CGRect, lit: Bool, in context: GraphicsContext) {
        let box = SimFormulaStage.badge(in: card)
        let shape = Path(roundedRect: box, cornerRadius: 4)
        context.fill(shape, with: .color(Theme.info.opacity(lit ? 0.24 : 0.13)))
        context.stroke(shape, with: .color(Theme.info.opacity(lit ? 0.6 : 0.34)), lineWidth: 0.75)
        let cached = lit ? badgeLetterLit : badgeLetterQuiet
        let letter = cached ?? context.resolve(Text(verbatim: "ƒ")
            .font(.system(size: 11.5, weight: .semibold, design: .serif).italic())
            .foregroundStyle(Theme.text.opacity(lit ? 1 : 0.86)))
        if lit { badgeLetterLit = letter } else { badgeLetterQuiet = letter }
        context.draw(letter, at: CGPoint(x: box.midX - 0.3, y: box.midY + 0.2))
    }
}

extension SimFormulaStage {
    /// What hovering a node shows after the delay: its formula over the ƒ badge (or when it has no
    /// term), else its glossary term. nil when it has neither.
    @MainActor
    static func hoverCard(_ node: Node, badge: Bool, terms: TermIndex) -> ((Overlays, CGRect) -> Void)? {
        if let formula = node.formula, badge || node.term.flatMap(terms.term) == nil {
            return { overlays, anchor in overlays.showFormula(formula, title: node.label, anchor: anchor) }
        }
        guard let term = node.term.flatMap(terms.term) else { return nil }
        return { overlays, anchor in overlays.showTerm(term, anchor: anchor, index: terms) }
    }

    /// Snapshots: the node whose formula card to show as if hovered, per simulation.
    @MainActor static var requested: [ObjectIdentifier: String] = [:]

    /// Shows a requested formula card once the stage is laid out (offscreen snapshots only).
    @MainActor
    static func showRequested(_ sim: Simulation, layout: StageLayout, camera: @escaping () -> StageCamera,
                              frame: @escaping () -> CGRect, overlays: Overlays) {
        guard let id = requested.removeValue(forKey: ObjectIdentifier(sim)), let card = layout.cardsByID[id],
              let formula = card.node.formula else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            let origin = frame().origin
            overlays.showFormula(formula, title: card.node.label, anchor: camera().screen(card.rect).offsetBy(dx: origin.x, dy: origin.y))
        }
    }
}
