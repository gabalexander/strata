import Foundation

struct YAMLNode {
    enum Content {
        case map([YAMLPair])
        case list([YAMLNode])
        case scalar(String, quoted: Bool)
        case null
    }

    let content: Content
    let line: Int

    var fields: [YAMLPair]? {
        guard case .map(let fields) = content else { return nil }
        return fields
    }

    var elements: [YAMLNode]? {
        guard case .list(let elements) = content else { return nil }
        return elements
    }

    var scalar: String? {
        guard case .scalar(let text, _) = content else { return nil }
        return text
    }

    subscript(_ key: String) -> YAMLNode? { fields?.first { $0.key == key }?.value }

    static func plain(_ text: String, line: Int) -> Self {
        switch text.lowercased() {
        case "", "~", "null": YAMLNode(content: .null, line: line)
        default: YAMLNode(content: .scalar(text, quoted: false), line: line)
        }
    }
}

struct YAMLPair {
    let key: String
    let line: Int
    let value: YAMLNode
}

enum YAML {
    static func parse(_ text: String) throws -> YAMLNode {
        var parser = BlockYAML(text)
        return try parser.document()
    }

    static func error(_ message: String, line: Int) -> Diagnostic {
        Diagnostic(.error, message, line: line)
    }
}

private struct YAMLLine {
    let characters: [Character]
    let terminated: Bool

    var indent: Int { characters.prefix { $0 == " " }.count }
    var blank: Bool { characters.allSatisfy { $0 == " " || $0 == "\t" } }

    func at(_ index: Int) -> Character? {
        index < characters.count ? characters[index] : nil
    }

    func skipSpaces(from offset: Int) -> Int {
        var index = offset
        while let c = at(index), c == " " || c == "\t" { index += 1 }
        return index
    }
}

private struct BlockYAML {
    let lines: [YAMLLine]
    var row = 0

    init(_ text: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let parts = normalized.components(separatedBy: "\n")
        lines = parts.enumerated().compactMap { index, part in
            let terminated = index < parts.count - 1
            guard terminated || !part.isEmpty else { return nil }
            let characters = index == 0 && part.first == "\u{FEFF}" ? Array(part.dropFirst()) : Array(part)
            return YAMLLine(characters: characters, terminated: terminated)
        }
    }

    mutating func document() throws -> YAMLNode {
        try skipTrivia()
        guard row < lines.count else { return YAMLNode(content: .map([]), line: 1) }
        let value = try block(at: lines[row].indent, depth: 0)
        try skipTrivia()
        if row < lines.count {
            throw YAML.error("unexpected indentation or content after the document", line: row + 1)
        }
        return value
    }

    mutating func skipTrivia() throws {
        while row < lines.count {
            let line = lines[row]
            if line.at(line.indent) == "\t", !line.blank {
                throw YAML.error("tabs cannot indent YAML; use spaces", line: row + 1)
            }
            if !line.blank, line.at(line.indent) != "#" { break }
            row += 1
        }
    }

    func isItem(at column: Int) -> Bool {
        lines[row].at(column) == "-" && isSpaceOrEnd(lines[row].at(column + 1))
    }

    mutating func block(at column: Int, depth: Int) throws -> YAMLNode {
        try checkDepth(depth, line: row + 1)
        if isItem(at: column) { return try sequence(at: column, depth: depth) }
        if try key(at: column) != nil { return try mapping(at: column, depth: depth) }
        return try value(at: column, parent: column, depth: depth)
    }

    mutating func sequence(at column: Int, depth: Int) throws -> YAMLNode {
        let line = row + 1
        var items: [YAMLNode] = []
        while row < lines.count, (items.isEmpty || lines[row].indent == column), isItem(at: column) {
            let start = lines[row].skipSpaces(from: column + 1)
            if start < lines[row].characters.count, try isItem(at: start) || key(at: start) != nil {
                items.append(try block(at: start, depth: depth + 1))
            } else {
                items.append(try value(at: start, parent: column, depth: depth + 1))
            }
            try skipTrivia()
            if row < lines.count, lines[row].indent > column {
                throw YAML.error("bad indentation; expected a sequence item at column \(column + 1)", line: row + 1)
            }
        }
        return YAMLNode(content: .list(items), line: line)
    }

    mutating func mapping(at column: Int, depth: Int) throws -> YAMLNode {
        let firstLine = row + 1
        var fields: [YAMLPair] = []
        var seen: [String: Int] = [:]
        while row < lines.count {
            guard let (name, end) = try key(at: column) else {
                throw YAML.error("expected a mapping entry (`key: value`)", line: row + 1)
            }
            let line = row + 1
            try recordKey(name, line: line, seen: &seen)
            let start = lines[row].skipSpaces(from: end + 1)
            let child = try value(at: start, parent: column, depth: depth + 1, allowIndentlessSequence: true)
            fields.append(YAMLPair(key: name, line: line, value: child))
            try skipTrivia()
            guard row < lines.count, lines[row].indent >= column else { break }
            if lines[row].indent > column {
                throw YAML.error("bad indentation; expected a mapping key at column \(column + 1)", line: row + 1)
            }
        }
        return YAMLNode(content: .map(fields), line: firstLine)
    }

    func key(at column: Int) throws -> (String, Int)? {
        let line = lines[row]
        guard let first = line.at(column), first != "#", first != "[", first != "{" else { return nil }
        if first == "\"" || first == "'" {
            var cursor = FlowYAML(lines: lines, row: row, column: column)
            let name = try cursor.quoted()
            guard cursor.row == row else { return nil }
            let end = line.skipSpaces(from: cursor.column)
            return line.at(end) == ":" && isSpaceOrEnd(line.at(end + 1)) ? (name, end) : nil
        }
        for index in column..<line.characters.count {
            let c = line.characters[index]
            if c == "#", index == column || isSpaceOrEnd(line.at(index - 1)) { break }
            if c == ":", isSpaceOrEnd(line.at(index + 1)) {
                let name = String(line.characters[column..<index]).trimmingCharacters(in: .whitespaces)
                if name.isEmpty { throw YAML.error("expected a key before ':'", line: row + 1) }
                try checkPlainStart(name, line: row + 1)
                return (name, index)
            }
        }
        return nil
    }

    mutating func value(at column: Int, parent: Int, depth: Int, allowIndentlessSequence: Bool = false) throws -> YAMLNode {
        let line = row + 1
        guard let first = lines[row].at(column), first != "#" else {
            row += 1
            try skipTrivia()
            if row < lines.count {
                let indent = lines[row].indent
                if indent > parent || (allowIndentlessSequence && indent == parent && isItem(at: indent)) {
                    return try block(at: indent, depth: depth)
                }
            }
            return YAMLNode(content: .null, line: line)
        }
        if first == "|" || first == ">" { return try blockScalar(at: column, parent: parent) }

        var cursor = FlowYAML(lines: lines, row: row, column: column)
        let node = try cursor.value(inFlow: false, depth: depth)
        if cursor.row > row {
            for continuation in (row + 1)...cursor.row {
                let line = lines[continuation]
                if line.at(line.indent) == "\t", !line.blank {
                    throw YAML.error("tabs cannot indent YAML; use spaces", line: continuation + 1)
                }
            }
        }
        let end = lines[cursor.row].skipSpaces(from: cursor.column)
        if let next = lines[cursor.row].at(end), next != "#" {
            throw YAML.error("unexpected content after the value", line: cursor.row + 1)
        }
        row = cursor.row + 1
        return node
    }

    mutating func blockScalar(at column: Int, parent: Int) throws -> YAMLNode {
        let line = row + 1
        let header = String(lines[row].characters[column...])
        let indicator = header.prefix { $0 != " " && $0 != "\t" }
        var suffix = lines[row].skipSpaces(from: column + indicator.count)
        if lines[row].at(suffix) == "#" { suffix = lines[row].characters.count }
        guard suffix == lines[row].characters.count,
              ["|", "|-", "|+", ">", ">-", ">+"].contains(String(indicator)) else {
            throw YAML.error("expected |, >, or a block scalar with + or - chomping", line: line)
        }

        row += 1
        let first = lines[row...].first { !$0.blank }
        let indent = first.map { max($0.indent, parent + 1) } ?? (parent + 1)
        var body: [(text: String, terminated: Bool)] = []
        while row < lines.count {
            let current = lines[row]
            if !current.blank, current.indent < indent {
                if current.indent > parent, current.at(current.indent) != "#" {
                    throw YAML.error("bad indentation in block scalar; expected at least \(indent) spaces", line: row + 1)
                }
                break
            }
            body.append((String(current.characters.dropFirst(indent)), current.terminated))
            row += 1
        }
        let lastContent = body.lastIndex { !$0.text.isEmpty }
        var text = ""
        for (index, part) in body.enumerated() {
            text += part.text
            guard part.terminated else { continue }
            guard indicator.first == ">", let lastContent, index < lastContent, index > 0 || !part.text.isEmpty else {
                text += "\n"
                continue
            }
            let next = body[index + 1].text
            let moreIndented = { (s: String) in s.first == " " || s.first == "\t" }
            if moreIndented(part.text) || moreIndented(next) {
                text += "\n"
            } else if !part.text.isEmpty {
                text += next.isEmpty ? "\n" : " "
            } else if next.isEmpty || !body[..<index].contains(where: { !$0.text.isEmpty }) {
                text += "\n"
            }
        }

        if indicator.last != "+" {
            let ended = text.last == "\n"
            while text.last == "\n" { text.removeLast() }
            if indicator.last != "-", ended, lastContent != nil { text += "\n" }
        }
        return YAMLNode(content: .scalar(text, quoted: true), line: line)
    }
}

private struct FlowYAML {
    let lines: [YAMLLine]
    var row: Int
    var column: Int

    var current: Character? { row < lines.count ? lines[row].at(column) : nil }
    var line: Int { min(row + 1, lines.count + 1) }

    mutating func whitespace() {
        while row < lines.count {
            column = lines[row].skipSpaces(from: column)
            if let c = current, c != "#" { return }
            row += 1
            column = 0
        }
    }

    mutating func value(inFlow: Bool, depth: Int) throws -> YAMLNode {
        try checkDepth(depth, line: line)
        let start = line
        switch current {
        case "[": return try list(depth: depth)
        case "{": return try map(depth: depth)
        case "\"", "'":
            return YAMLNode(content: .scalar(try quoted(), quoted: true), line: start)
        default:
            let text = try plain(inFlow: inFlow, key: false)
            guard !text.isEmpty else { throw YAML.error("expected a value", line: start) }
            return .plain(text, line: start)
        }
    }

    mutating func list(depth: Int) throws -> YAMLNode {
        let start = line
        column += 1
        whitespace()
        var items: [YAMLNode] = []
        while current != "]" {
            guard let next = current, next != "}" else { throw unclosed("]", start: start) }
            items.append(try value(inFlow: true, depth: depth + 1))
            if try !commaOrEnd("]", start: start) { break }
        }
        column += 1
        return YAMLNode(content: .list(items), line: start)
    }

    mutating func map(depth: Int) throws -> YAMLNode {
        let start = line
        column += 1
        whitespace()
        var fields: [YAMLPair] = []
        var seen: [String: Int] = [:]
        while current != "}" {
            guard let next = current, next != "]" else { throw unclosed("}", start: start) }
            let keyLine = line
            let quotedKey = next == "\"" || next == "'"
            let name = try quotedKey ? quoted() : plain(inFlow: true, key: true)
            whitespace()
            guard (quotedKey || !name.isEmpty), current == ":" else {
                throw YAML.error("expected a key followed by ':' in flow mapping", line: keyLine)
            }
            try recordKey(name, line: keyLine, seen: &seen)
            column += 1
            whitespace()
            guard let next = current, next != "]" else { throw unclosed("}", start: start) }
            let child = next == "}" || next == "," ? YAMLNode(content: .null, line: line) : try value(inFlow: true, depth: depth + 1)
            fields.append(YAMLPair(key: name, line: keyLine, value: child))
            if try !commaOrEnd("}", start: start) { break }
        }
        column += 1
        return YAMLNode(content: .map(fields), line: start)
    }

    mutating func commaOrEnd(_ end: Character, start: Int) throws -> Bool {
        whitespace()
        switch current {
        case end: return false
        case ",":
            column += 1
            whitespace()
            return true
        case nil, "]", "}": throw unclosed(end, start: start)
        default: throw YAML.error("expected ',' or '\(end)'", line: line)
        }
    }

    func unclosed(_ end: Character, start: Int) -> Diagnostic {
        YAML.error("unclosed flow collection opened on line \(start); expected '\(end)'", line: current == nil ? start : line)
    }

    mutating func plain(inFlow: Bool, key: Bool) throws -> String {
        let start = line
        var result = ""
        while let c = current {
            if c == "#", result.isEmpty || result.last?.isWhitespace == true { break }
            if inFlow, ",]}".contains(c) { break }
            if c == ":" {
                let next = lines[row].at(column + 1)
                if key, isSpaceOrEnd(next) || next.map({ "[]{},".contains($0) }) == true { break }
                if isSpaceOrEnd(next) {
                    throw YAML.error("unexpected ':' in a plain value; quote values that contain ': '", line: line)
                }
            }
            if inFlow, "[{".contains(c) {
                throw YAML.error("unexpected '\(c)' in a plain value; quote the value or add a comma", line: line)
            }
            result.append(c)
            column += 1
        }
        result = result.trimmingCharacters(in: .whitespaces)
        try checkPlainStart(result, line: start)
        return result
    }

    mutating func quoted() throws -> String {
        let quote = current!
        let start = line
        column += 1
        var result = ""
        while row < lines.count {
            guard let c = current else {
                while result.last == " " || result.last == "\t" { result.removeLast() }
                result += nextQuotedLine()
                continue
            }
            column += 1
            if c == quote {
                if quote == "'", current == "'" { column += 1; result += "'"; continue }
                return result
            }
            if c == "\\", quote == "\"" {
                if current == nil {
                    _ = nextQuotedLine()
                } else {
                    result += try escape()
                }
            } else {
                result.append(c)
            }
        }
        throw YAML.error("unclosed quoted scalar; expected \(quote)", line: start)
    }

    mutating func nextQuotedLine() -> String {
        row += 1
        var blankLines = 0
        while row < lines.count, lines[row].blank { row += 1; blankLines += 1 }
        column = row < lines.count ? lines[row].skipSpaces(from: 0) : 0
        return blankLines == 0 ? " " : String(repeating: "\n", count: blankLines)
    }

    mutating func escape() throws -> String {
        let c = current!
        column += 1
        switch c {
        case "0": return "\0"
        case "a": return "\u{07}"
        case "b": return "\u{08}"
        case "t", "\t": return "\t"
        case "n": return "\n"
        case "v": return "\u{0B}"
        case "f": return "\u{0C}"
        case "r": return "\r"
        case "e": return "\u{1B}"
        case "N": return "\u{85}"
        case "_": return "\u{A0}"
        case "L": return "\u{2028}"
        case "P": return "\u{2029}"
        case " ", "\"": return String(c)
        case "/", "\\": return String(c)
        case "x", "u", "U":
            let digits = c == "x" ? 2 : (c == "u" ? 4 : 8)
            var code = try hex(digits)
            if c == "u", (0xD800...0xDBFF).contains(code),
               current == "\\", lines[row].at(column + 1) == "u" {
                column += 2
                let low = try hex(4)
                if (0xDC00...0xDFFF).contains(low) { code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00) }
            }
            guard let scalar = Unicode.Scalar(code) else { throw YAML.error("invalid Unicode escape", line: line) }
            return String(scalar)
        default: throw YAML.error("unknown escape '\\\(c)' in double quotes", line: line)
        }
    }

    mutating func hex(_ count: Int) throws -> UInt32 {
        let end = column + count
        guard end <= lines[row].characters.count,
              let value = UInt32(String(lines[row].characters[column..<end]), radix: 16) else {
            throw YAML.error("expected \(count) hexadecimal digits in escape", line: line)
        }
        column = end
        return value
    }
}

private func isSpaceOrEnd(_ character: Character?) -> Bool {
    character == nil || character == " " || character == "\t"
}

private func checkPlainStart(_ text: String, line: Int) throws {
    if let first = text.first, "&*!".contains(first) {
        throw YAML.error("anchors, aliases, and tags are unsupported; quote this value if it is text", line: line)
    }
    if ["---", "..."].contains(text) {
        throw YAML.error("document markers are unsupported; use one YAML document per file", line: line)
    }
}

private func checkDepth(_ depth: Int, line: Int) throws {
    if depth > 128 { throw YAML.error("YAML nesting exceeds 128 levels", line: line) }
}

private func recordKey(_ key: String, line: Int, seen: inout [String: Int]) throws {
    if let original = seen.updateValue(line, forKey: key) {
        throw YAML.error("duplicate key '\(key)' (first defined on line \(original))", line: line)
    }
}
