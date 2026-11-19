import SwiftUI
import StrataCore

/// An Ask answer as it streams: paragraphs, bullets, numbered lists, headings and code blocks, with
/// inline code, bold and links. A `strata:` link that resolves in the map is an accent link that opens
/// what it names; one that doesn't is plain text.
@MainActor
struct SimAskMarkdown: View {
    let text: String
    let manifest: Manifest
    var size: CGFloat = 13
    var color = Theme.text
    let open: (AskTarget) -> Void

    var body: some View {
        let blocks = SimAskBlocks.parse(AskLinks.rewrite(text, in: manifest))
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(block)
            }
        }
        .font(Theme.ui(size))
        .foregroundStyle(color)
        .tint(Theme.accent)
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == AskLink.scheme {
                guard let target = manifest.askTarget(url.absoluteString) else { return .discarded }
                open(target)
                return .handled
            }
            return url.scheme == "https" || url.scheme == "http" ? .systemAction : .discarded
        })
    }

    @ViewBuilder
    private func view(_ block: SimAskBlocks.Block) -> some View {
        switch block {
        case .paragraph(let text):
            inline(text).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        case .heading(let text):
            inline(text).font(Theme.ui(size, .semibold)).foregroundStyle(Theme.text).padding(.top, 2)
        case .item(let marker, let text, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(marker)
                    .font(marker == "•" ? Theme.ui(size) : Theme.mono(size - 1))
                    .foregroundStyle(Theme.muted)
                    .frame(minWidth: marker == "•" ? 8 : 16, alignment: .trailing)
                inline(text).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 16)
        case .code(let text):
            Text(verbatim: text)
                .font(Theme.mono(size - 1))
                .foregroundStyle(Theme.text)
                .strataSelectable("Copy code") { text }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(Theme.border))
        }
    }

    private func inline(_ text: String) -> Text {
        var parsed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        for run in parsed.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                parsed[run.range].font = Theme.mono(size - 1)
                parsed[run.range].backgroundColor = Theme.raised
            }
            if run.link != nil {
                parsed[run.range].foregroundColor = Theme.accent
                parsed[run.range].underlineStyle = Text.LineStyle(pattern: .solid, color: Theme.accent.opacity(0.35))
            }
        }
        return Text(parsed)
    }
}

/// Splits answer markdown into blocks. Tolerant of half-written input, since it runs on every streamed chunk.
enum SimAskBlocks {
    enum Block: Equatable {
        case paragraph(String)
        case heading(String)
        case item(marker: String, text: String, depth: Int)
        case code(String)
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let open = code {
                    blocks.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { flush(); continue }
            if let heading = line.firstMatch(of: #/^#{1,4}\s+(.+)$/#) {
                flush()
                blocks.append(.heading(String(heading.1)))
                continue
            }
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
            if let bullet = line.firstMatch(of: #/^[-*•+]\s+(.*)$/#) {
                flush()
                blocks.append(.item(marker: "•", text: String(bullet.1), depth: min(indent / 2, 3)))
                continue
            }
            if let number = line.firstMatch(of: #/^(\d{1,3})[.)]\s+(.*)$/#) {
                flush()
                blocks.append(.item(marker: "\(number.1).", text: String(number.2), depth: min(indent / 2, 3)))
                continue
            }
            // A continuation line of a list item stays with it.
            if paragraph.isEmpty, indent > 0, case .item(let marker, let text, let depth)? = blocks.last {
                blocks[blocks.count - 1] = .item(marker: marker, text: text + " " + line, depth: depth)
                continue
            }
            paragraph.append(line)
        }
        if let open = code, !open.isEmpty { blocks.append(.code(open.joined(separator: "\n"))) }
        flush()
        return blocks
    }
}
