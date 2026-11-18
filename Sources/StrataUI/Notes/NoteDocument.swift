import Foundation
import StrataCore

struct NoteDocument {
    struct Heading: Identifiable {
        let line: Int
        let level: Int
        let title: String
        var id: Int { line }
    }

    struct ListItem: Identifiable {
        let line: Int
        let indent: Int
        let number: String?
        let text: String
        let task: TaskMarker?
        var id: Int { line }
    }

    struct TaskMarker {
        let offset: Int
        let character: String
        var checked: Bool { character != " " }
    }

    struct Block: Identifiable {
        enum Content {
            case heading(Heading), paragraph(String), list([ListItem])
            case quote(kind: String?, title: String?, body: String)
            case code(language: String, text: String, embedIndex: Int?)
            case table(header: [String], rows: [[String]], alignment: [TableAlignment])
            case rule, image(path: String, label: String)
        }

        let lines: ClosedRange<Int>
        let content: Content
        var id: Int { lines.lowerBound }
    }

    enum TableAlignment { case leading, center, trailing }

    let glossaries: [String]
    let blocks: [Block]
    let headings: [Heading]

    private static let headingPattern = try! NSRegularExpression(pattern: #"^ {0,3}(#{1,6})[ \t]+(.+?)(?:[ \t]+#+)?[ \t]*$"#)
    private static let listPattern = try! NSRegularExpression(pattern: #"^([ \t]*)([-+*]|[0-9]+[.)])[ \t]+(?:\[([ xX])\](?:[ \t]+|$))?(.*)$"#)
    private static let rulePattern = try! NSRegularExpression(pattern: #"^ {0,3}(?:(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,})$"#)
    private static let calloutPattern = try! NSRegularExpression(pattern: #"^\[!(note|warning|tip)\]([+-])?[ \t]*(.*)$"#, options: .caseInsensitive)
    private static let imagePattern = try! NSRegularExpression(pattern: #"^!\[([^\]]*)\]\(\s*(?:<([^>]+)>|([^"\)]+?))(?:\s+"[^"]*")?\s*\)$"#)
    private static let delimiterPattern = try! NSRegularExpression(pattern: #"^:?-{3,}:?$"#)

    init(_ text: String) {
        var lines: [String] = []
        var offsets: [Int] = []
        let source = text as NSString
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: .byLines) { line, range, _, _ in
            lines.append(line ?? "")
            offsets.append(range.location)
        }
        let frontmatter = NoteSyntax.frontmatterEnd(in: lines)
        glossaries = frontmatter.map { Self.glossaryPacks(lines[1..<$0]) } ?? []

        var blocks: [Block] = []
        var headings: [Heading] = []
        var index = frontmatter.map { $0 + 1 } ?? 0
        var embedIndex = 0
        while index < lines.count {
            let start = index
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            index += 1
            guard !trimmed.isEmpty else { continue }

            let content: Block.Content
            if let fence = NoteSyntax.fence(in: line) {
                var body: [String] = []
                while index < lines.count, NoteSyntax.fence(in: lines[index])?.closes(fence) != true {
                    body.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                let embedded = fence.language == "strata"
                content = .code(language: fence.language, text: body.joined(separator: "\n"), embedIndex: embedded ? embedIndex : nil)
                if embedded { embedIndex += 1 }
            } else if let heading = Self.heading(in: line, number: start + 1) {
                headings.append(heading)
                content = .heading(heading)
            } else if Self.isRule(line) {
                content = .rule
            } else if let match = Self.match(Self.imagePattern, in: trimmed) {
                let source = trimmed as NSString
                let pathRange = match.range(at: 2).location == NSNotFound ? match.range(at: 3) : match.range(at: 2)
                content = .image(path: source.substring(with: pathRange), label: source.substring(with: match.range(at: 1)))
            } else if let quoted = Self.quoteLine(line) {
                var body = [quoted]
                while index < lines.count, let quote = Self.quoteLine(lines[index]) {
                    body.append(quote)
                    index += 1
                }
                if let match = Self.match(Self.calloutPattern, in: quoted) {
                    let source = quoted as NSString
                    let kind = source.substring(with: match.range(at: 1)).lowercased()
                    let title = source.substring(with: match.range(at: 3))
                    content = .quote(kind: kind, title: title.isEmpty ? kind.capitalized : title, body: body.dropFirst().joined(separator: "\n"))
                } else {
                    content = .quote(kind: nil, title: nil, body: body.joined(separator: "\n"))
                }
            } else if let item = Self.listItem(line, number: start + 1, offset: offsets[start]) {
                var items = [item]
                while index < lines.count, !Self.isRule(lines[index]),
                      let next = Self.listItem(lines[index], number: index + 1, offset: offsets[index]) {
                    items.append(next)
                    index += 1
                }
                content = .list(items)
            } else if let table = Self.tableHeader(at: start, in: lines) {
                index += 1
                var rows: [[String]] = []
                while index < lines.count, lines[index].contains("|"), !Self.startsBlock(lines[index]) {
                    let row = Self.cells(in: lines[index])
                    rows.append(table.header.indices.map { row.indices.contains($0) ? row[$0] : "" })
                    index += 1
                }
                content = .table(header: table.header, rows: rows, alignment: table.alignment)
            } else if index < lines.count, lines[index].range(of: #"^ {0,3}(=+|-+)[ \t]*$"#, options: .regularExpression) != nil {
                let heading = Heading(line: start + 1, level: lines[index].contains("=") ? 1 : 2, title: trimmed)
                headings.append(heading)
                index += 1
                content = .heading(heading)
            } else {
                var paragraph = [line]
                while index < lines.count, !Self.startsBlock(lines[index]), Self.tableHeader(at: index, in: lines) == nil {
                    paragraph.append(lines[index])
                    index += 1
                }
                content = .paragraph(paragraph.joined(separator: "\n"))
            }
            blocks.append(Block(lines: start + 1...index, content: content))
        }
        self.blocks = blocks
        self.headings = headings
    }

    func line(for location: NoteWorkspace.Location) -> Int? {
        switch location {
        case .line(let line): return line
        case .heading(let title):
            return headings.first { Self.headingKey($0.title) == Self.headingKey(title) }?.line
        }
    }

    func block(at line: Int) -> Block? {
        blocks.first { $0.lines.upperBound >= line } ?? blocks.last
    }

    private static func headingKey(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func heading(in line: String, number: Int) -> Heading? {
        guard let match = match(headingPattern, in: line) else { return nil }
        return Heading(line: number, level: match.range(at: 1).length, title: (line as NSString).substring(with: match.range(at: 2)))
    }

    static func listMatch(in line: String) -> NSTextCheckingResult? { match(listPattern, in: line) }
    static func isRule(_ line: String) -> Bool { match(rulePattern, in: line) != nil }

    private static func listItem(_ line: String, number: Int, offset: Int) -> ListItem? {
        guard let match = listMatch(in: line) else { return nil }
        let source = line as NSString
        let indent = source.substring(with: match.range(at: 1)).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let marker = source.substring(with: match.range(at: 2))
        let check = match.range(at: 3)
        return ListItem(line: number, indent: indent, number: marker.first?.isNumber == true ? marker : nil,
                        text: source.substring(with: match.range(at: 4)),
                        task: check.location == NSNotFound ? nil : TaskMarker(offset: offset + check.location, character: source.substring(with: check)))
    }

    private static func quoteLine(_ line: String) -> String? {
        let trimmed = line.drop(while: { $0 == " " })
        guard trimmed.first == ">" else { return nil }
        let value = trimmed.dropFirst()
        return String(value.first == " " ? value.dropFirst() : value)
    }

    private static func startsBlock(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || NoteSyntax.fence(in: line) != nil || isRule(line)
            || heading(in: line, number: 0) != nil || quoteLine(line) != nil
            || listMatch(in: line) != nil || match(imagePattern, in: trimmed) != nil
    }

    private static func tableHeader(at index: Int, in lines: [String]) -> (header: [String], alignment: [TableAlignment])? {
        guard index + 1 < lines.count, lines[index].contains("|") else { return nil }
        let header = cells(in: lines[index])
        let delimiter = cells(in: lines[index + 1])
        guard !header.isEmpty, header.count == delimiter.count, delimiter.allSatisfy({ match(delimiterPattern, in: $0) != nil }) else { return nil }
        return (header, delimiter.map { field in
            guard field.hasSuffix(":") else { return .leading }
            return field.hasPrefix(":") ? .center : .trailing
        })
    }

    private static func cells(in line: String) -> [String] {
        let text = line.trimmingCharacters(in: .whitespaces) as NSString
        let raw = text as String
        let protected = NoteSyntax.inlineCode(in: raw) + NoteSyntax.wikiLinks(in: raw).map(\.range)
        var cells: [String] = []
        var start = 0
        var escaped = false
        for index in 0..<text.length {
            let char = text.character(at: index)
            if !escaped, char == 124, !protected.contains(where: { NSLocationInRange(index, $0) }) {
                if index > 0 { cells.append(text.substring(with: NSRange(location: start, length: index - start))) }
                start = index + 1
            }
            escaped = !escaped && char == 92
        }
        if start < text.length { cells.append(text.substring(from: start)) }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func glossaryPacks(_ lines: ArraySlice<String>) -> [String] {
        guard let index = lines.firstIndex(where: { $0.hasPrefix("glossaries:") }) else { return [] }
        let value = lines[index].dropFirst("glossaries:".count).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("["), let end = value.firstIndex(of: "]") {
            return value[value.index(after: value.startIndex)..<end].split(separator: ",").map { cleanPack(String($0)) }
                .filter { !$0.isEmpty }
        }
        return lines.dropFirst(index - lines.startIndex + 1).prefix { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }
            .map { cleanPack(String($0.trimmingCharacters(in: .whitespaces).dropFirst(2))) }
    }

    private static func cleanPack(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private static func match(_ pattern: NSRegularExpression, in line: String) -> NSTextCheckingResult? {
        pattern.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count))
    }
}
