import Foundation

/// Markdown source positions are UTF-16, shared by disk edits and TextKit.
public enum NoteSyntax {
    public struct WikiLink: Sendable {
        public let range: NSRange
        public let targetRange: NSRange
        public let target: String
        public let heading: String?
        public let alias: String?

        public var label: String {
            alias ?? (target.isEmpty ? heading ?? "" : target)
        }
    }

    public struct Fence: Equatable, Sendable {
        public let marker: Character
        public let length: Int
        public let language: String

        public func closes(_ opening: Fence) -> Bool {
            marker == opening.marker && length >= opening.length && language.isEmpty
        }
    }

    private static let fencePattern = try! NSRegularExpression(pattern: #"^ {0,3}(`{3,}|~{3,})([^\r\n]*)"#)
    private static let wikiPattern = try! NSRegularExpression(pattern: #"(?<!\[)\[\[([^\[\]\r\n]+)\]\]"#)
    private static let ticks = try! NSRegularExpression(pattern: #"`+"#)
    private static let simPattern = try! NSRegularExpression(
        pattern: #"^sim:[ \t]*(?:["']([a-z0-9_-]+)["']|([a-z0-9_-]+))[ \t]*(?:#.*)?$"#
    )

    public static func fence(in line: String) -> Fence? {
        let source = line as NSString
        guard let match = fencePattern.firstMatch(in: line, range: NSRange(location: 0, length: source.length)) else { return nil }
        let marker = source.substring(with: match.range(at: 1))
        let language = source.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
        return Fence(marker: marker.first!, length: marker.count, language: language)
    }

    public static func frontmatterEnd(in lines: [String]) -> Int? {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        return lines.indices.dropFirst().first { lines[$0].trimmingCharacters(in: .whitespaces) == "---" }
    }

    static func simID(in line: String) -> String? {
        let source = line as NSString
        guard let match = simPattern.firstMatch(in: line, range: NSRange(location: 0, length: source.length)) else { return nil }
        let quoted = match.range(at: 1)
        return source.substring(with: quoted.location == NSNotFound ? match.range(at: 2) : quoted)
    }

    public static func wikiLinks(in line: String) -> [WikiLink] {
        let source = line as NSString
        let range = NSRange(location: 0, length: source.length)
        let matches = wikiPattern.matches(in: line, range: range)
        guard !matches.isEmpty else { return [] }
        let code = inlineCode(in: line)
        return matches.compactMap { match in
            guard !escaped(at: match.range.location, in: source),
                  !code.contains(where: { NSLocationInRange(match.range.location, $0) }) else { return nil }
            let payload = source.substring(with: match.range(at: 1))
            let aliased = payload.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let parts = aliased[0].split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let rawTarget = String(parts[0])
            let target = rawTarget.trimmingCharacters(in: .whitespaces)
            let heading = parts.count == 2 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : nil
            guard !target.isEmpty || heading?.isEmpty == false else { return nil }
            let leading = rawTarget.utf16.count - rawTarget.drop(while: \.isWhitespace).utf16.count
            return WikiLink(range: match.range,
                            targetRange: NSRange(location: match.range(at: 1).location + leading, length: target.utf16.count),
                            target: target, heading: heading,
                            alias: aliased.count == 2 && !aliased[1].isEmpty ? String(aliased[1]) : nil)
        }
    }

    public static func inlineCode(in line: String) -> [NSRange] {
        let source = line as NSString
        let runs = ticks.matches(in: line, range: NSRange(location: 0, length: source.length)).map(\.range)
        var nextRun: [Int: Int] = [:]
        var closing = Array<Int?>(repeating: nil, count: runs.count)
        for index in runs.indices.reversed() {
            closing[index] = nextRun[runs[index].length]
            nextRun[runs[index].length] = index
        }
        var result: [NSRange] = []
        var index = 0
        while index < runs.count {
            let start = runs[index]
            if !escaped(at: start.location, in: source), let endIndex = closing[index] {
                result.append(NSRange(location: start.location, length: NSMaxRange(runs[endIndex]) - start.location))
                index = endIndex + 1
            } else {
                index += 1
            }
        }
        return result
    }

    private static func escaped(at location: Int, in source: NSString) -> Bool {
        var start = location
        while start > 0, source.character(at: start - 1) == 92 { start -= 1 }
        return (location - start).isMultiple(of: 2) == false
    }
}

struct IndexedNote {
    let text: String
    let lines: [String]
    let links: [NoteSyntax.WikiLink]
    let embeds: [String]

    init(_ text: String, path: String) {
        self.text = text
        var lines: [String] = []
        var offsets: [Int] = []
        let source = text as NSString
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: .byLines) { line, range, _, _ in
            lines.append(line ?? "")
            offsets.append(range.location)
        }
        self.lines = lines

        let bodyStart = NoteSyntax.frontmatterEnd(in: lines).map { $0 + 1 } ?? 0
        var links: [NoteSyntax.WikiLink] = []
        var embeds: [String] = []
        var open: NoteSyntax.Fence?
        var embedLines: [String] = []
        var embedIndex = 0
        func indexEmbed() {
            let parsed = ManifestParser.parseEmbed(embedLines.joined(separator: "\n"), note: path, index: embedIndex).0
            embedIndex += 1
            if let parsed {
                if case .library(let id) = parsed.target { embeds.append(id) }
            } else if let id = embedLines.lazy.compactMap(NoteSyntax.simID(in:)).first {
                embeds.append(id)
            }
            embedLines.removeAll(keepingCapacity: true)
        }

        for index in lines.indices.dropFirst(bodyStart) {
            let line = lines[index]
            let fence = NoteSyntax.fence(in: line)
            if let opening = open {
                if fence?.closes(opening) == true {
                    if opening.language == "strata" { indexEmbed() }
                    open = nil
                } else if opening.language == "strata" {
                    embedLines.append(line)
                }
            } else if let fence {
                open = fence
            } else {
                let offset = offsets[index]
                links += NoteSyntax.wikiLinks(in: line).map {
                    NoteSyntax.WikiLink(range: NSRange(location: $0.range.location + offset, length: $0.range.length),
                                        targetRange: NSRange(location: $0.targetRange.location + offset, length: $0.targetRange.length),
                                        target: $0.target, heading: $0.heading, alias: $0.alias)
                }
            }
        }
        if open?.language == "strata" { indexEmbed() }
        self.links = links
        self.embeds = embeds
    }

    func excerpt(at line: Int, matching query: String? = nil) -> String {
        guard lines.indices.contains(line) else { return "" }
        let text = lines[line].trimmingCharacters(in: .whitespaces)
        guard text.count > 150 else { return text }
        let match = query.flatMap { text.range(of: $0, options: .caseInsensitive) }
        let focus = match?.lowerBound ?? text.startIndex
        let start = text.index(focus, offsetBy: -45, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(start, offsetBy: 150, limitedBy: text.endIndex) ?? text.endIndex
        return (start == text.startIndex ? "" : "…") + text[start..<end] + (end == text.endIndex ? "" : "…")
    }
}
