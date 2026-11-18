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
                    // One Text per paragraph: a view per word made every inspector and dock rebuild
                    // lay out dozens of views for a few lines of prose. Words flow as before: any run
                    // of whitespace, line breaks included, is one space.
                    let flowing = attributed(paragraph.replacing(#/\s+/#, with: " "))
                    let text = String(flowing.characters)
                    SimTermParagraph(text: linked(flowing, plain: text, matches: terms.matches(in: text)),
                                     model: model, index: terms, lineLimit: lineLimit)
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

    /// The paragraph as one Text: each glossary term (outside links) is accent coloured, links to its
    /// card and carries `SimTermRun` so the renderer can underline it and hovering can find it.
    private func linked(_ attributed: AttributedString, plain: String,
                        matches: [(range: Range<String.Index>, term: Term)]) -> Text {
        var segments: [Text] = []
        var start = plain.startIndex
        func append(_ range: Range<String.Index>, term: Term?) {
            guard !range.isEmpty, let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else { return }
            var part = AttributedString(attributed[lower..<upper])
            guard let term, !part.runs.contains(where: { $0.link != nil }) else {
                segments.append(Text(part))
                return
            }
            part.link = SimTermParagraph.url(for: term)
            part.foregroundColor = Theme.accent
            segments.append(Text(part).customAttribute(SimTermRun(id: term.id)))
        }
        for match in matches.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) where match.range.lowerBound >= start {
            append(start..<match.range.lowerBound, term: nil)
            append(match.range, term: match.term)
            start = match.range.upperBound
        }
        append(start..<plain.endIndex, term: nil)
        return segments.reduce(Text(verbatim: "")) { Text("\($0)\($1)") }
    }
}

/// Marks a glossary term inside a paragraph's Text.
struct SimTermRun: TextAttribute {
    let id: String
}

/// Where the terms of one paragraph were drawn, in the paragraph's own coordinates. Written by the
/// text renderer, read by hover and clicks; not observed, so neither re-renders anything.
private final class SimTermLayout: @unchecked Sendable {
    private let lock = NSLock()
    private var runs: [(rect: CGRect, id: String)] = []
    var frame = CGRect.zero
    var hovered: String?
    var pending: Task<Void, Never>?

    func set(_ runs: [(rect: CGRect, id: String)]) {
        lock.lock(); self.runs = runs; lock.unlock()
    }

    func term(at point: CGPoint) -> String? {
        lock.lock(); defer { lock.unlock() }
        return runs.first { $0.rect.insetBy(dx: -1, dy: -1).contains(point) }?.id
    }

    /// The first line of the term, in window coordinates.
    func anchor(for id: String) -> CGRect? {
        lock.lock(); defer { lock.unlock() }
        return runs.first { $0.id == id }.map { $0.rect.offsetBy(dx: frame.minX, dy: frame.minY) }
    }
}

/// Draws each term's faint dotted underline and records where the terms are.
private struct SimTermUnderline: TextRenderer {
    let layout: SimTermLayout

    func draw(layout text: Text.Layout, in context: inout GraphicsContext) {
        var runs: [(rect: CGRect, id: String)] = []
        for line in text {
            for run in line {
                if let term = run[SimTermRun.self] {
                    let rect = run.typographicBounds.rect
                    runs.append((rect, term.id))
                    var underline = Path()
                    underline.move(to: CGPoint(x: rect.minX, y: rect.maxY - 0.5))
                    underline.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 0.5))
                    context.stroke(underline, with: .color(Theme.accent.opacity(0.55)),
                                   style: StrokeStyle(lineWidth: 1, dash: [1, 2]))
                }
                context.draw(run)
            }
        }
        layout.set(runs)
    }
}

/// A paragraph with glossary terms: hovering a term shows its card after 300 ms, clicking pins it.
@MainActor
private struct SimTermParagraph: View {
    let text: Text
    let model: AppModel
    let index: TermIndex
    let lineLimit: Int?
    @State private var layout = SimTermLayout()
    @Environment(\.openURL) private var openURL

    static func url(for term: Term) -> URL? {
        var components = URLComponents()
        components.scheme = "strata-term"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "id", value: term.id)]
        return components.url
    }

    var body: some View {
        text
            .lineSpacing(3)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .textRenderer(SimTermUnderline(layout: layout))
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { layout.frame = $0 }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hover(layout.term(at: point))
                case .ended: hover(nil)
                }
            }
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "strata-term" else { openURL(url); return .handled }
                let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
                guard let id, let term = index.term(id) else { return .discarded }
                layout.pending?.cancel()
                model.overlays.showTerm(term, anchor: layout.anchor(for: id) ?? layout.frame, pinned: true, index: index)
                return .handled
            })
            .onDisappear { layout.pending?.cancel() }
    }

    private func hover(_ id: String?) {
        guard id != layout.hovered else { return }
        layout.pending?.cancel()
        if layout.hovered != nil { model.overlays.hideTerm() }
        layout.hovered = id
        guard let id, let term = index.term(id) else { return }
        layout.pending = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, layout.hovered == id else { return }
            model.overlays.showTerm(term, anchor: layout.anchor(for: id) ?? layout.frame, index: index)
        }
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
