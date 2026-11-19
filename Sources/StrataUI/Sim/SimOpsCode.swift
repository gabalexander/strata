import AppKit
import SwiftUI
import StrataCore

/// Light highlighting for the code an op carries: SQL keywords, strings and parameters, and JSON
/// payloads re-indented in their own key order.
enum SimOpsCode {
    private static let keywordColor = Theme.token(2)
    private static let stringColor = Theme.token(3)
    private static let paramColor = Theme.info
    private static let numberColor = Theme.token(4)

    private static let keywords: Set<String> = [
        "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "IS", "NULL", "AS", "ON", "JOIN", "LEFT", "RIGHT",
        "INNER", "OUTER", "FULL", "CROSS", "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "OFFSET", "INSERT", "INTO",
        "VALUES", "UPDATE", "SET", "DELETE", "RETURNING", "BEGIN", "COMMIT", "ROLLBACK", "WITH", "DISTINCT",
        "UNION", "ALL", "EXISTS", "CASE", "WHEN", "THEN", "ELSE", "END", "FOR", "SKIP", "LOCKED", "NOWAIT",
        "SHARE", "CONFLICT", "DO", "NOTHING", "CREATE", "TABLE", "INDEX", "ALTER", "DROP", "ASC", "DESC",
        "LIKE", "ILIKE", "BETWEEN", "INTERVAL", "TRUE", "FALSE", "DEFAULT", "PRIMARY", "UPSERT",
        "MERGE", "USING", "MATCHED", "LATERAL", "WINDOW", "OVER", "PARTITION", "COUNT", "SUM", "MIN", "MAX",
    ]

    /// Without the trailing newlines a YAML block scalar keeps.
    static func trimmed(_ source: String) -> String {
        var text = source
        while let last = text.last, last.isWhitespace { text.removeLast() }
        return text
    }

    static func sql(_ source: String) -> AttributedString {
        var out = AttributedString()
        let chars = Array(source)
        var i = 0
        func emit(_ text: String, _ color: Color?) {
            var piece = AttributedString(text)
            if let color { piece.foregroundColor = color }
            out += piece
        }
        while i < chars.count {
            let c = chars[i]
            if c == "-", i + 1 < chars.count, chars[i + 1] == "-" {
                var j = i
                while j < chars.count, chars[j] != "\n" { j += 1 }
                emit(String(chars[i..<j]), Theme.faint)
                i = j
            } else if c == "'" {
                var j = i + 1
                while j < chars.count {
                    if chars[j] == "'" {
                        if j + 1 < chars.count, chars[j + 1] == "'" { j += 2; continue }
                        j += 1
                        break
                    }
                    j += 1
                }
                emit(String(chars[i..<min(j, chars.count)]), stringColor)
                i = j
            } else if c == "$" || c == ":" && i + 1 < chars.count && chars[i + 1].isLetter && (i == 0 || chars[i - 1] != ":") {
                var j = i + 1
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                emit(String(chars[i..<j]), j > i + 1 ? paramColor : nil)
                i = j
            } else if c == "?" {
                emit("?", paramColor)
                i += 1
            } else if c.isLetter || c == "_" {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                let word = String(chars[i..<j])
                emit(word, keywords.contains(word.uppercased()) ? keywordColor : nil)
                i = j
            } else if c.isNumber {
                var j = i
                while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
                emit(String(chars[i..<j]), numberColor)
                i = j
            } else {
                var j = i + 1
                while j < chars.count, !"-'$:?_".contains(chars[j]), !chars[j].isLetter, !chars[j].isNumber { j += 1 }
                emit(String(chars[i..<j]), nil)
                i = j
            }
        }
        return out
    }

    private enum JSONToken {
        case open(Character), close(Character), comma, colon
        case string(String), scalar(String)
    }

    /// Re-indents valid JSON, keeping its key order. Nil when the text isn't JSON.
    static func json(_ source: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[",
              let data = trimmed.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil,
              let tokens = jsonTokens(trimmed) else { return nil }
        var out = ""
        var depth = 0
        func newline() { out += "\n" + String(repeating: "  ", count: depth) }
        for (index, token) in tokens.enumerated() {
            switch token {
            case .open(let c):
                out.append(c)
                if index + 1 < tokens.count, case .close = tokens[index + 1] { continue }
                depth += 1
                newline()
            case .close(let c):
                if index > 0, case .open = tokens[index - 1] { out.append(c); continue }
                depth -= 1
                newline()
                out.append(c)
            case .comma:
                out += ","
                newline()
            case .colon: out += ": "
            case .string(let s), .scalar(let s): out += s
            }
        }
        return out
    }

    private static func jsonTokens(_ text: String) -> [JSONToken]? {
        let chars = Array(text)
        var tokens: [JSONToken] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "{", "[": tokens.append(.open(c)); i += 1
            case "}", "]": tokens.append(.close(c)); i += 1
            case ",": tokens.append(.comma); i += 1
            case ":": tokens.append(.colon); i += 1
            case "\"":
                var j = i + 1
                while j < chars.count, chars[j] != "\"" { j += chars[j] == "\\" ? 2 : 1 }
                guard j < chars.count else { return nil }
                tokens.append(.string(String(chars[i...j])))
                i = j + 1
            default:
                if c.isWhitespace { i += 1; continue }
                var j = i
                while j < chars.count, !",:{}[]\"".contains(chars[j]), !chars[j].isWhitespace { j += 1 }
                tokens.append(.scalar(String(chars[i..<j])))
                i = j
            }
        }
        return tokens
    }

    /// Colours JSON (formatted or not): keys, string values, numbers and literals.
    static func jsonHighlight(_ source: String) -> AttributedString {
        var out = AttributedString()
        let chars = Array(source)
        var i = 0
        func emit(_ text: String, _ color: Color?) {
            var piece = AttributedString(text)
            if let color { piece.foregroundColor = color }
            out += piece
        }
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                var j = i + 1
                while j < chars.count, chars[j] != "\"" { j += chars[j] == "\\" ? 2 : 1 }
                j = min(j + 1, chars.count)
                var k = j
                while k < chars.count, chars[k] == " " { k += 1 }
                let isKey = k < chars.count && chars[k] == ":"
                emit(String(chars[i..<j]), isKey ? Theme.text : stringColor)
                i = j
            } else if c.isNumber || c == "-" || c.isLetter {
                var j = i
                while j < chars.count, !",:{}[]\" \n".contains(chars[j]) { j += 1 }
                emit(String(chars[i..<max(j, i + 1)]), numberColor)
                i = max(j, i + 1)
            } else {
                var j = i + 1
                while j < chars.count, "{}[],: \n".contains(chars[j]) { j += 1 }
                emit(String(chars[i..<j]), Theme.muted)
                i = j
            }
        }
        return out
    }

    /// A payload, request or response: formatted JSON when it parses, else the text as written.
    static func message(_ source: String) -> (text: AttributedString, isJSON: Bool) {
        if let formatted = json(source) { return (jsonHighlight(formatted), true) }
        return (AttributedString(source), false)
    }
}

/// A titled block of code: mono on the stage colour, selectable, with a copy button in its header and
/// an in-window Copy on right-click (selectable text would otherwise open the system menu).
@MainActor
struct SimOpsCodeBlock: View {
    let title: String
    let text: AttributedString
    let raw: String
    let copyTitle: String
    let overlays: Overlays
    var caption: String?
    var still = false
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(title).font(Theme.ui(11, .semibold)).foregroundStyle(Theme.muted)
                if let caption { Text(caption).font(Theme.mono(10)).foregroundStyle(Theme.faint) }
                Spacer(minLength: 0)
                Button(action: copy) {
                    Image(systemName: "doc.on.doc")
                        .font(Theme.ui(10, .medium))
                        .foregroundStyle(hovered ? Theme.text : Theme.muted)
                        .frame(width: 22, height: 20)
                        .background(hovered ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
                .accessibilityLabel(copyTitle)
            }
            .frame(height: 16)
            SimEnumCodeText(text)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.text)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .simOpsMenu(still: still) { point in
                    overlays.showMenu([MenuItem(copyTitle, icon: "doc.on.doc", action: copy)], at: point)
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
                .card(Theme.bg, radius: Theme.radiusSmall)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(raw, forType: .string)
        overlays.toast(copyTitle.replacingOccurrences(of: "Copy", with: "Copied"))
    }
}
