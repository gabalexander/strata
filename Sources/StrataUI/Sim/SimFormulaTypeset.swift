import SwiftUI
import StrataCore

// Typesetting for `formula.expr` (docs/manifest.md, Formulas) without a TeX engine: a small tokenizer,
// a parser for scripts, groups and simple fractions, and a renderer that composes SwiftUI `Text`.
// Variables are italic serif, function names and numbers upright, `w_r` gets a subscript, `e^(…)` a
// superscript, `(a / b)` stacks when simple, and ASCII spellings become math symbols (`<=` → ≤,
// `*` → ·, `tau` → τ). Anything it can't read falls back to mono, so a formula always shows.

enum FormulaToken: Equatable {
    case name(String)
    case number(String)
    case op(String)
    case open(Character)
    case close(Character)
    case sub, sup
    case space
    case other(String)
}

enum FormulaLexer {
    static let greek: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ",
        "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "rho": "ρ", "sigma": "σ",
        "tau": "τ", "upsilon": "υ", "phi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Phi": "Φ",
        "Psi": "Ψ", "Omega": "Ω",
    ]

    /// Two-character ASCII operators and what they stand for.
    private static let pairs: [String: String] = [
        "<=": "≤", ">=": "≥", "!=": "≠", "->": "→", "<-": "←", "=>": "⇒", "==": "=", "~=": "≈", "||": "‖", "+-": "±",
    ]
    private static let singles: [Character: String] = [
        "*": "·", "-": "−", "+": "+", "/": "/", "=": "=", "<": "<", ">": ">", ",": ",", ";": ";", ":": ":", "|": "|",
        "!": "!", "%": "%",
    ]
    /// Math symbols written directly.
    static let symbols: Set<Character> = [
        "·", "×", "÷", "−", "±", "∓", "≤", "≥", "≠", "≈", "≡", "∼", "∝", "∈", "∉", "⊂", "⊆", "⊃", "∪", "∩", "∧", "∨",
        "¬", "→", "←", "↔", "⇒", "⇔", "∑", "∏", "√", "∞", "∂", "∇", "∀", "∃", "‖", "⌊", "⌋", "⌈", "⌉", "′", "°", "…", "∘",
    ]

    static func tokens(_ text: String) -> [FormulaToken] {
        var result: [FormulaToken] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace {
                if result.last != .space { result.append(.space) }
                i += 1
            } else if c == "_" {
                result.append(.sub); i += 1
            } else if c == "^" {
                result.append(.sup); i += 1
            } else if "([{".contains(c) {
                result.append(.open(c)); i += 1
            } else if ")]}".contains(c) {
                result.append(.close(c)); i += 1
            } else if c.isLetter, !symbols.contains(c) {
                var j = i + 1
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "'" || chars[j] == "′", !symbols.contains(chars[j]) { j += 1 }
                let word = String(chars[i..<j])
                result.append(.name(greek[word] ?? word))
                i = j
            } else if c.isNumber {
                var j = i + 1
                while j < chars.count, chars[j].isNumber || (chars[j] == "." && j + 1 < chars.count && chars[j + 1].isNumber) { j += 1 }
                result.append(.number(String(chars[i..<j])))
                i = j
            } else if i + 1 < chars.count, let pair = pairs[String(chars[i...i + 1])] {
                result.append(.op(pair)); i += 2
            } else if let single = singles[c] {
                result.append(.op(single)); i += 1
            } else if symbols.contains(c) {
                result.append(.op(String(c))); i += 1
            } else {
                result.append(.other(String(c))); i += 1
            }
        }
        return result
    }
}

/// The parsed expression.
indirect enum FormulaNode {
    enum Style { case variable, function, number, op, bigOp, punct, mono }

    case symbol(String, Style)
    /// Brackets shown as written: `(m, s)`, `[0, 1)`.
    case group(open: String, [FormulaNode], close: String)
    case script(base: FormulaNode, sub: [FormulaNode]?, sup: [FormulaNode]?)
    case fraction([FormulaNode], [FormulaNode])
    case space

    var isSpace: Bool { if case .space = self { return true }; return false }

    /// `and`, `or`, `if`: words set upright that read as part of a sentence.
    var isWord: Bool {
        if case .symbol(let text, .function) = self { return ["and", "or", "if", "else", "otherwise", "not", "for", "where"].contains(text) }
        return false
    }

    /// Ends in an italic letter, which leans into whatever follows.
    var endsItalic: Bool {
        switch self {
        case .symbol(_, let style): return style == .variable
        case .script(_, let sub, let sup): return sup == nil && sub == nil
        default: return false
        }
    }

    var isOperator: Bool {
        if case .symbol(_, let style) = self { return style == .op || style == .punct }
        return false
    }
}

enum FormulaParser {
    struct Failure: Error {}

    /// Function names set upright, like `log` and `max` in TeX.
    static let functions: Set<String> = [
        "e", "exp", "log", "ln", "lg", "min", "max", "argmin", "argmax", "sin", "cos", "tan", "sqrt", "lim", "mod",
        "floor", "ceil", "abs", "sgn", "sign", "round", "clamp", "avg", "mean", "median", "var", "std", "hash", "len",
        "count", "sum", "det", "dim", "deg", "gcd", "lcm", "if", "else", "otherwise", "and", "or", "not", "for", "where",
    ]
    private static let bigOperators: Set<String> = ["Σ", "Π", "∑", "∏", "∫", "√"]
    private static let binary: Set<String> = [
        "=", "+", "−", "·", "×", "÷", "±", "∓", "≤", "≥", "<", ">", "≠", "≈", "≡", "∼", "∝", "∈", "∉", "⊂", "⊆", "⊃",
        "∪", "∩", "∧", "∨", "→", "←", "↔", "⇒", "⇔", "‖", "∘",
    ]
    private static let closing: [Character: Character] = ["(": ")", "[": "]", "{": "}"]

    static func parse(_ text: String) throws -> [FormulaNode] {
        var parser = Cursor(tokens: FormulaLexer.tokens(text))
        let nodes = try parser.sequence(until: nil, depth: 0)
        guard parser.atEnd else { throw Failure() }
        return stack(nodes)
    }

    /// Whether a symbol is a binary operator that wants space around it.
    static func isBinary(_ text: String) -> Bool { binary.contains(text) }

    static func style(of name: String) -> FormulaNode.Style {
        if bigOperators.contains(name) { return .bigOp }
        if functions.contains(name) { return .function }
        if let first = name.unicodeScalars.first, ("Α"..."Ω").contains(first) { return .function }   // upright capital Greek
        return .variable
    }

    private struct Cursor {
        let tokens: [FormulaToken]
        var index = 0
        var atEnd: Bool { index >= tokens.count }
        var peek: FormulaToken? { atEnd ? nil : tokens[index] }

        mutating func next() -> FormulaToken? {
            defer { index += 1 }
            return peek
        }

        mutating func sequence(until close: Character?, depth: Int) throws -> [FormulaNode] {
            guard depth < 8 else { throw Failure() }
            var nodes: [FormulaNode] = []
            while let token = peek {
                if case .close(let c) = token {
                    guard c == close else { throw Failure() }
                    return nodes
                }
                index += 1
                var node: FormulaNode
                switch token {
                case .space:
                    if let last = nodes.last, !last.isSpace { nodes.append(.space) }
                    continue
                case .open(let c):
                    let inner = try sequence(until: closing[c], depth: depth + 1)
                    guard case .close? = next() else { throw Failure() }
                    node = .group(open: String(c), inner, close: String(closing[c] ?? ")"))
                case .close: throw Failure()
                case .name(let name): node = .symbol(name, FormulaParser.style(of: name))
                case .number(let digits): node = .symbol(digits, .number)
                case .op(let op): node = .symbol(op, op == "," || op == ";" || op == ":" ? .punct : .op)
                case .other(let text): node = .symbol(text, .mono)
                case .sub, .sup: throw Failure()   // a script with nothing right before it
                }
                node = try scripts(on: node, depth: depth)
                nodes.append(node)
            }
            if close != nil { throw Failure() }
            if case .space? = nodes.last { nodes.removeLast() }
            return nodes
        }

        /// `_x`, `^x`, `_(…)`, `^(…)` after an atom, in either order.
        mutating func scripts(on base: FormulaNode, depth: Int) throws -> FormulaNode {
            var sub: [FormulaNode]?
            var sup: [FormulaNode]?
            while let token = peek, token == .sub || token == .sup {
                index += 1
                let argument = try scriptArgument(depth: depth)
                if token == .sub { guard sub == nil else { throw Failure() }; sub = argument }
                else { guard sup == nil else { throw Failure() }; sup = argument }
            }
            guard sub != nil || sup != nil else { return base }
            return .script(base: base, sub: sub, sup: sup)
        }

        private mutating func scriptArgument(depth: Int) throws -> [FormulaNode] {
            switch next() {
            case .open(let c)?:
                let inner = try sequence(until: closing[c], depth: depth + 1)
                guard case .close? = next() else { throw Failure() }
                return c == "(" ? inner : [.group(open: String(c), inner, close: String(closing[c] ?? ")"))]
            case .name(let name)?: return [.symbol(name, FormulaParser.style(of: name))]
            case .number(let digits)?: return [.symbol(digits, .number)]
            case .op(let op)? where op == "−" || op == "+":
                guard let operand = next() else { throw Failure() }
                switch operand {
                case .number(let digits): return [.symbol(op, .op), .symbol(digits, .number)]
                case .name(let name): return [.symbol(op, .op), .symbol(name, FormulaParser.style(of: name))]
                default: throw Failure()
                }
            case .op(let op)?: return [.symbol(op, .op)]
            default: throw Failure()
            }
        }
    }

    /// `(a / b)` at the top level becomes a stacked fraction when both sides are simple.
    private static func stack(_ nodes: [FormulaNode]) -> [FormulaNode] {
        nodes.map { node in
            guard case .group("(", let inner, ")") = node, let fraction = fraction(inner) else { return node }
            return fraction
        }
    }

    private static func fraction(_ inner: [FormulaNode]) -> FormulaNode? {
        let slashes = inner.indices.filter { if case .symbol("/", _) = inner[$0] { return true }; return false }
        guard slashes.count == 1, let slash = slashes.first else { return nil }
        func side(_ part: ArraySlice<FormulaNode>) -> [FormulaNode]? {
            var items = Array(part)
            while case .space? = items.first { items.removeFirst() }
            while case .space? = items.last { items.removeLast() }
            if items.count == 1, case .group("(", let content, ")") = items[0] { items = content }
            let simple = !items.isEmpty && items.count <= 9 && !items.contains {
                if case .symbol(let text, _) = $0 { return text == "=" || text == "," || text == ";" }
                if case .fraction = $0 { return true }
                return false
            }
            return simple ? items : nil
        }
        guard let top = side(inner[..<slash]), let bottom = side(inner[(slash + 1)...]) else { return nil }
        return .fraction(top, bottom)
    }
}

/// A typeset formula. Without stacked fractions it is one wrapping `Text`; with them, a baseline-aligned row.
@MainActor
struct SimFormulaText: View {
    let expr: String
    var size: CGFloat = 17
    var color: Color = Theme.text

    var body: some View {
        if let nodes = try? FormulaParser.parse(expr) {
            let pieces = FormulaRender(size: size, color: color).pieces(nodes)
            if pieces.allSatisfy(\.isText) {
                FormulaRender.join(pieces).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in piece.view(size: size, color: color) }
                }
                .fixedSize()
            }
        } else {
            Text(verbatim: expr).font(Theme.mono(size * 0.78)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Text pieces and stacked fractions, laid out left to right.
enum FormulaPiece {
    case text(Text)
    case fraction([FormulaPiece], [FormulaPiece], size: CGFloat)

    var isText: Bool { if case .text = self { return true }; return false }

    @MainActor @ViewBuilder
    func view(size: CGFloat, color: Color) -> some View {
        switch self {
        case .text(let text): text.fixedSize()
        case .fraction(let top, let bottom, let inner): FormulaFraction(top: top, bottom: bottom, size: inner, outer: size, color: color)
        }
    }
}

@MainActor
private struct FormulaFraction: View {
    let top: [FormulaPiece]
    let bottom: [FormulaPiece]
    let size: CGFloat
    let outer: CGFloat
    let color: Color

    var body: some View {
        VStack(spacing: size * 0.14) {
            FormulaRender.join(top).fixedSize()
            Rectangle().fill(color.opacity(0.8)).frame(height: max(1, outer * 0.06))
            FormulaRender.join(bottom).fixedSize()
        }
        .fixedSize()
        .padding(.horizontal, outer * 0.14)
        // The bar sits on the math axis, about a quarter of the font size above the baseline.
        .alignmentGuide(.firstTextBaseline) { d in d.height / 2 + outer * 0.27 }
    }
}

struct FormulaRender {
    let size: CGFloat
    let color: Color

    static func join(_ pieces: [FormulaPiece]) -> Text {
        pieces.reduce(Text(verbatim: "")) { result, piece in
            if case .text(let text) = piece { return Text("\(result)\(text)") }
            return result
        }
    }

    func pieces(_ nodes: [FormulaNode]) -> [FormulaPiece] {
        var pieces: [FormulaPiece] = []
        var run = Text(verbatim: "")
        var hasRun = false
        for (index, node) in nodes.enumerated() {
            if case .fraction(let top, let bottom) = node {
                if hasRun { pieces.append(.text(run)) }
                run = Text(verbatim: ""); hasRun = false
                let inner = FormulaRender(size: size * 0.82, color: color)
                pieces.append(.fraction([.text(inner.text(top, offset: 0))], [.text(inner.text(bottom, offset: 0))], size: size * 0.82))
                continue
            }
            run = Text("\(run)\(text(node, previous: index > 0 ? nodes[index - 1] : nil, next: index + 1 < nodes.count ? nodes[index + 1] : nil, offset: 0))")
            hasRun = true
        }
        if hasRun { pieces.append(.text(run)) }
        return pieces
    }

    /// A whole sequence as one Text (scripts, inline fractions).
    func text(_ nodes: [FormulaNode], offset: CGFloat) -> Text {
        nodes.enumerated().reduce(Text(verbatim: "")) { result, item in
            let (index, node) = item
            let previous = index > 0 ? nodes[index - 1] : nil
            let next = index + 1 < nodes.count ? nodes[index + 1] : nil
            return Text("\(result)\(text(node, previous: previous, next: next, offset: offset))")
        }
    }

    private func text(_ node: FormulaNode, previous: FormulaNode?, next: FormulaNode?, offset: CGFloat) -> Text {
        switch node {
        case .space:
            // Space between two operands (function application, `h (m)`); operators bring their own.
            // Words such as `and` and `if` get a full space.
            guard let previous, let next, !previous.isOperator, !next.isOperator else { return Text(verbatim: "") }
            return styled(previous.isWord || next.isWord ? " " : "\u{2009}", .op, offset: offset)
        case .symbol(let value, let style):
            if style == .op || style == .punct { return op(value, previous: previous, offset: offset) }
            return styled(value, style, offset: offset)
        case .group(let open, let inner, let close):
            // Italic correction: a hair space keeps a leaning letter off the brackets around it.
            let before = previous?.endsItalic == true ? "\u{200A}" : ""
            let after = inner.last?.endsItalic == true ? "\u{200A}" : ""
            return Text("\(styled(before + open, .punct, offset: offset))\(text(inner, offset: offset))\(styled(after + close, .punct, offset: offset))")
        case .fraction(let top, let bottom):
            return text([.group(open: "(", top + [.symbol("/", .op)] + bottom, close: ")")], offset: offset)
        case .script(let base, let sub, let sup):
            var result = text(base, previous: previous, next: nil, offset: offset)
            let small = FormulaRender(size: size * 0.7, color: color)
            if let sub { result = Text("\(result)\(small.text(sub, offset: offset - size * 0.2))") }
            if let sup { result = Text("\(result)\(small.text(sup, offset: offset + size * 0.38))") }
            return result
        }
    }

    private func op(_ value: String, previous: FormulaNode?, offset: CGFloat) -> Text {
        let operand = previous.map { node -> Bool in
            if case .space = node { return true }
            return !node.isOperator
        } ?? false
        if value == "," || value == ";" { return styled(value + " ", .punct, offset: offset) }
        // Binary operators get medium math space on both sides; a leading minus hugs its operand.
        if FormulaParser.isBinary(value), operand { return styled("\u{2005}\(value)\u{2005}", .op, offset: offset) }
        return styled(value, .op, offset: offset)
    }

    private func styled(_ value: String, _ style: FormulaNode.Style, offset: CGFloat) -> Text {
        let font: Font
        var tint = color
        switch style {
        case .variable: font = .system(size: size, design: .serif).italic()
        case .function, .number: font = .system(size: size, design: .serif)
        case .op, .punct:
            font = .system(size: size, design: .serif)
            tint = color.opacity(0.72)
        case .bigOp: font = .system(size: size * 1.18, design: .serif)
        case .mono: font = .system(size: size * 0.8, design: .monospaced)
        }
        return Text(verbatim: value).font(font).foregroundStyle(tint).baselineOffset(offset)
    }
}
