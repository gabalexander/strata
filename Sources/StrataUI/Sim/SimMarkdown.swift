import SwiftUI
import StrataCore

@MainActor
struct SimMarkdown: View {
    let source: String
    let model: AppModel
    let terms: TermIndex
    var color = Theme.muted
    var size: CGFloat = 13
    var lineLimit: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(source.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                let parsed = attributed(paragraph)
                let plain = String(parsed.characters)
                let matches = terms.matches(in: plain).sorted { $0.range.lowerBound < $1.range.lowerBound }
                if matches.isEmpty {
                    Text(parsed).lineLimit(lineLimit).fixedSize(horizontal: false, vertical: true)
                } else {
                    InlineWords(spacing: 3, lineSpacing: 3, lineLimit: lineLimit) {
                        let pieces = pieces(parsed, plain: plain, matches: matches)
                        ForEach(pieces.indices, id: \.self) { i in
                            let piece = pieces[i]
                            Group {
                                if let term = piece.term {
                                    SimTermAnchor(term: term, model: model, index: terms) {
                                        Text(piece.text).foregroundStyle(Theme.accent)
                                            .overlay(alignment: .bottom) {
                                                Canvas { context, size in
                                                    let line = Path { p in
                                                        p.move(to: CGPoint(x: 0, y: 0.5))
                                                        p.addLine(to: CGPoint(x: size.width, y: 0.5))
                                                    }
                                                    context.stroke(line, with: .color(Theme.accent.opacity(0.55)),
                                                                   style: StrokeStyle(lineWidth: 1, dash: [1, 2]))
                                                }
                                                .frame(height: 1)
                                            }
                                    }
                                } else {
                                    Text(piece.text)
                                }
                            }
                            .layoutValue(key: InlineGap.self, value: piece.spaceBefore)
                        }
                    }
                }
            }
        }
        .font(Theme.ui(size))
        .foregroundStyle(color)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "strata-wiki",
                  let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value else {
                return .systemAction
            }
            if SimSessions.cachedManifest(model, id: target) != nil { model.open(.sim(target, path: [])) }
            else if let path = model.vault.resolve(link: target) { model.open(.note(path)) }
            else { model.overlays.toast("Link not found") }
            return .handled
        })
    }

    private func attributed(_ text: String) -> AttributedString {
        var text = text
        let wiki = #/\[\[([^\]\n]+)\]\]/#
        for match in text.matches(of: wiki).reversed() {
            let parts = match.1.split(separator: "|", maxSplits: 1)
            guard let target = parts.first else { continue }
            var url = URLComponents()
            url.scheme = "strata-wiki"
            url.host = "open"
            url.queryItems = [URLQueryItem(name: "target", value: String(target))]
            guard let destination = url.string else { continue }
            text.replaceSubrange(match.range, with: "[\(parts.last ?? target)](\(destination))")
        }
        var parsed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ??
            AttributedString(text)
        for run in parsed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            parsed[run.range].font = Theme.mono(size - 1)
            parsed[run.range].foregroundColor = Theme.text
        }
        return parsed
    }

    private func pieces(_ attributed: AttributedString, plain: String,
                        matches: [(range: Range<String.Index>, term: Term)]) -> [(text: AttributedString, term: Term?, spaceBefore: Bool)] {
        var pieces: [(AttributedString, Term?, Bool)] = []
        var start = plain.startIndex
        var previousEnd = start
        func append(_ range: Range<String.Index>, term: Term?) {
            guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else { return }
            let part = AttributedString(attributed[lower..<upper])
            let linked = part.runs.contains { $0.link != nil }
            let separated = plain[previousEnd..<range.lowerBound].contains(where: \.isWhitespace)
            pieces.append((part, linked ? nil : term, separated))
            previousEnd = range.upperBound
        }
        func words(_ range: Range<String.Index>) {
            for match in plain[range].matches(of: #/\S+/#) { append(match.range, term: nil) }
        }
        for match in matches {
            words(start..<match.range.lowerBound)
            append(match.range, term: match.term)
            start = match.range.upperBound
        }
        words(start..<plain.endIndex)
        return pieces
    }
}

@MainActor
struct SimTermAnchor<Content: View>: View {
    let term: Term
    let model: AppModel
    let index: TermIndex
    @ViewBuilder var content: Content
    @State private var pending: Task<Void, Never>?

    var body: some View {
        content.overlay {
            GeometryReader { proxy in
                Color.clear.contentShape(Rectangle())
                    .onHover { inside in
                        pending?.cancel()
                        if inside {
                            pending = Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(300))
                                guard !Task.isCancelled else { return }
                                model.overlays.showTerm(term, anchor: proxy.frame(in: .global), index: index)
                            }
                        } else {
                            model.overlays.hideTerm()
                        }
                    }
                    .onTapGesture {
                        pending?.cancel()
                        model.overlays.showTerm(term, anchor: proxy.frame(in: .global), pinned: true, index: index)
                    }
            }
        }
        .accessibilityAddTraits(.isLink)
        .onDisappear { pending?.cancel() }
    }
}

private struct InlineGap: LayoutValueKey {
    static let defaultValue = false
}

private struct InlineWords: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat
    let lineLimit: Int?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        lines(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = lines(bounds.width, subviews)
        for (view, frame) in zip(subviews, layout.frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func lines(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var height: CGFloat = 0
        var usedWidth: CGFloat = 0
        var line = 1
        var frames: [CGRect] = []
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            let gap = x > 0 && subview[InlineGap.self] ? spacing : 0
            if x > 0 && x + gap + size.width > width {
                if let lineLimit, line >= lineLimit { break }
                line += 1
                x = 0
                y += height + lineSpacing
                height = 0
            } else {
                x += gap
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width
            height = max(height, size.height)
        }
        return (CGSize(width: usedWidth, height: y + height), frames)
    }
}
