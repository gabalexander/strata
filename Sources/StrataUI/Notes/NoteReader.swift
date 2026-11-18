import AppKit
import os
import SwiftUI
import StrataCore

@MainActor
struct NoteReader: View {
    let model: AppModel
    let path: String
    let document: NoteDocument
    let jump: NoteWorkspace.Destination?
    let toggleTask: (NoteDocument.TaskMarker) -> Void

    private enum Anchor: Hashable { case block(Int), listItem(Int) }

    private var embeds: [Int: (Embed?, [Diagnostic])] {
        Dictionary(uniqueKeysWithValues: document.blocks.compactMap { block in
            guard case .code(_, let text, let index?) = block.content else { return nil }
            return (index, ManifestParser.parseEmbed(text, note: path, index: index))
        })
    }

    var body: some View {
        let embeds = embeds
        let index = termIndex(embeds)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 15) {
                    ForEach(document.blocks) { block in
                        blockView(block.content, embeds: embeds, index: index)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(Anchor.block(block.id))
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 34)
                .padding(.top, 30)
                .padding(.bottom, 56)
                .frame(maxWidth: .infinity)
            }
            .task(id: jump?.id) {
                guard let jump, let line = document.line(for: jump.location),
                      let block = document.block(at: line) else { return }
                await Task.yield()
                proxy.scrollTo(Anchor.block(block.id), anchor: .top)
                if case .list(let items) = block.content, items.contains(where: { $0.line == line }) {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(Anchor.listItem(line), anchor: .top)
                }
            }
        }
    }

    @ViewBuilder private func blockView(_ block: NoteDocument.Block.Content,
                                        embeds: [Int: (Embed?, [Diagnostic])], index: TermIndex) -> some View {
        switch block {
        case .heading(let heading):
            inline(heading.title, index: index, font: Theme.ui(heading.level == 1 ? 30 : heading.level == 2 ? 22 : 17, .semibold))
                .accessibilityAddTraits(.isHeader)
                .padding(.top, heading.line > 1 ? 6 : 0)
        case .paragraph(let paragraph):
            inline(paragraph.replacingOccurrences(of: #"(?<!  )\n"#, with: " ", options: .regularExpression), index: index)
        case .list(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        if let task = item.task {
                            Button { toggleTask(task) } label: {
                                Image(systemName: task.checked ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(task.checked ? Theme.accent : Theme.muted)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(task.checked ? "Uncheck task" : "Check task")
                            .frame(width: 20)
                        } else {
                            Text(item.number ?? "•")
                                .font(Theme.mono(12))
                                .foregroundStyle(Theme.muted)
                                .frame(minWidth: 20, alignment: .trailing)
                        }
                        inline(item.text, index: index)
                            .foregroundStyle(item.task?.checked == true ? Theme.muted : Theme.text)
                    }
                    .padding(.leading, CGFloat(min(item.indent, 24)) * 7)
                    .id(Anchor.listItem(item.line))
                }
            }
        case .quote(let kind, let title, let content):
            let tint = kind == "warning" ? Theme.warn : kind == "tip" ? Theme.good : kind == "note" ? Theme.info : Theme.borderStrong
            HStack(spacing: 0) {
                Rectangle().fill(tint).frame(width: 2)
                VStack(alignment: .leading, spacing: 7) {
                    if let title {
                        Label(title, systemImage: kind == "warning" ? "exclamationmark.triangle" : kind == "tip" ? "lightbulb" : "info.circle")
                            .font(Theme.ui(13, .semibold))
                            .foregroundStyle(tint)
                    }
                    if !content.isEmpty { inline(content, index: index).foregroundStyle(Theme.muted) }
                }
                .padding(kind == nil ? 10 : 13)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(kind == nil ? .clear : tint.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))
        case .code(let language, let text, let embedIndex):
            if let embedIndex, let (embed, diagnostics) = embeds[embedIndex] {
                if let embed {
                    SimEmbedView(model: model, embed: embed, note: path)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                } else {
                    embedError(diagnostics)
                }
            } else {
                codeBlock(language: language, text: text)
            }
        case .table(let header, let rows, let alignment):
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(header.indices, id: \.self) { i in tableCell(header[i], alignment[i], index: index, header: true) }
                }
                ForEach(rows.indices, id: \.self) { row in
                    Rectangle().fill(Theme.border).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(header.indices, id: \.self) { col in tableCell(rows[row][col], alignment[col], index: index) }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .card(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        case .rule:
            Rectangle().fill(Theme.borderStrong).frame(height: 1).padding(.vertical, 6)
        case .image(let file, let label):
            if let url = model.vault.attachmentURL(file, relativeTo: path), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 420)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    .accessibilityLabel(label)
            } else {
                Label(label.isEmpty ? "Image unavailable" : label, systemImage: "photo")
                    .font(Theme.ui()).foregroundStyle(Theme.muted).padding(12).card(Theme.surface)
            }
        }
    }

    private func inline(_ content: String, index: TermIndex, font: Font = Theme.ui(15)) -> some View {
        NoteInline(content: content, index: index, model: model, path: path)
            .font(font)
        .lineSpacing(6)
    }

    private func tableCell(_ value: String, _ alignment: NoteDocument.TableAlignment, index: TermIndex, header: Bool = false) -> some View {
        inline(value, index: index, font: Theme.ui(13, header ? .semibold : .regular))
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
    }

    private func codeBlock(language: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "Code" : language).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                Spacer()
                NoteIconButton(title: "Copy code", symbol: "document.on.document") {
                    NoteLinks.copy(text)
                    model.overlays.toast("Code copied")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            Rectangle().fill(Theme.border).frame(height: 1)
            ScrollView(.horizontal) {
                Text(verbatim: text)
                    .font(Theme.mono(13))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .strataCopyMenu("Copy code", text: text, overlays: model.overlays)
                    .padding(13)
            }
        }
        .card(Theme.raised)
    }

    private func embedError(_ diagnostics: [Diagnostic]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Simulator couldn’t load", systemImage: "exclamationmark.triangle")
                .font(Theme.ui(13, .semibold))
                .foregroundStyle(Theme.warn)
            ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                Text(diagnostic.description)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.muted)
                    .textSelection(.enabled)
                    .strataCopyMenu("Copy error", text: diagnostic.description, overlays: model.overlays)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(Theme.surface)
    }

    private func termIndex(_ embeds: [Int: (Embed?, [Diagnostic])]) -> TermIndex {
        var terms: [Term] = []
        var libraryIDs: Set<String> = []
        for index in embeds.keys.sorted() {
            guard let embed = embeds[index]?.0 else { continue }
            switch embed.target {
            case .library(let id):
                if let manifest = model.library.manifest(id), libraryIDs.insert(id).inserted {
                    terms += TermIndex(manifest: manifest).terms
                }
            case .inline(let manifest):
                terms += TermIndex(manifest: manifest).terms
            }
        }
        for id in model.vault.embeddedSimIDs(in: path) where libraryIDs.insert(id).inserted {
            if let manifest = model.library.manifest(id) { terms += TermIndex(manifest: manifest).terms }
        }
        terms += document.glossaries.flatMap { GlossaryPacks.load($0) }
        var seen: Set<String> = []
        return TermIndex(terms: terms.filter { seen.insert($0.id).inserted })
    }
}

private struct TermRun: TextAttribute {
    var term: Term
}

private struct TermHit {
    let term: Term
    let rect: CGRect
}

private final class TermHitMap {
    let storage = OSAllocatedUnfairLock(initialState: [TermHit]())
}

private struct TermRenderer: TextRenderer {
    let map: TermHitMap

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var hits: [TermHit] = []
        for line in layout {
            context.draw(line)
            for run in line {
                guard let term = run[TermRun.self]?.term else { continue }
                let rect = run.typographicBounds.rect
                hits.append(TermHit(term: term, rect: rect))
                var rule = Path()
                rule.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                rule.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                context.stroke(rule, with: .color(Theme.accent.opacity(0.65)), style: StrokeStyle(lineWidth: 1, dash: [1, 2]))
            }
        }
        map.storage.withLock { [hits] in $0 = hits }
    }
}

@MainActor
struct NoteInline: View {
    let content: String
    let index: TermIndex
    let model: AppModel
    let path: String

    private var overlays: Overlays { model.overlays }

    @State private var hitMap = TermHitMap()
    @State private var frame: CGRect = .zero
    @State private var hover: TermHit?
    @State private var hoverTimer: Task<Void, Never>?

    var body: some View {
        let rich = parsed()
        let pieces = termPieces(rich)
        if pieces.terms.isEmpty {
            pieces.text.environment(\.openURL, OpenURLAction(handler: openURL))
        } else {
            pieces.text
                .textRenderer(TermRenderer(map: hitMap))
                .environment(\.openURL, OpenURLAction(handler: openURL))
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
                .onContinuousHover { updateHover($0) }
                .onDisappear { endHover() }
        }
    }

    func openURL(_ url: URL) -> OpenURLAction.Result {
        if let route = Route(strataURL: url.absoluteString) {
            model.open(route)
            return .handled
        }
        guard url.scheme == NoteLinks.internalScheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.scheme?.lowercased() == "strata" ? .discarded : .systemAction
        }
        let items = components.queryItems ?? []
        let target = items.first { $0.name == "target" }?.value ?? ""
        if url.host == "term", let term = index.term(target) {
            hoverTimer?.cancel()
            let rect = hover?.term.id == term.id ? hover?.rect : hitMap.storage.withLock { hits in hits.first { $0.term.id == term.id }?.rect }
            overlays.showTerm(term, anchor: anchor(rect), pinned: true, index: index)
        } else if url.host == "note" {
            NoteLinks.open(target, heading: items.first { $0.name == "heading" }?.value, from: path, model: model)
        }
        return .handled
    }

    private func updateHover(_ phase: HoverPhase) {
        guard case .active(let point) = phase,
              let hit = hitMap.storage.withLock({ $0.first { $0.rect.contains(point) } }) else {
            endHover()
            return
        }
        guard hover?.term.id != hit.term.id || hover?.rect != hit.rect else { return }
        endHover()
        hover = hit
        hoverTimer = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            overlays.showTerm(hit.term, anchor: anchor(hit.rect), index: index)
        }
    }

    private func endHover() {
        hoverTimer?.cancel()
        if let hover, overlays.card?.term == hover.term { overlays.hideTerm() }
        hover = nil
    }

    private func anchor(_ rect: CGRect?) -> CGRect {
        rect?.offsetBy(dx: frame.minX, dy: frame.minY) ?? frame
    }

    private func parsed() -> AttributedString {
        let escaped = content.components(separatedBy: "\n").map { line -> String in
            let rewritten = NSMutableString(string: line)
            for link in NoteSyntax.wikiLinks(in: line).reversed() {
                var items = [URLQueryItem(name: "target", value: link.target)]
                if let heading = link.heading { items.append(URLQueryItem(name: "heading", value: heading)) }
                guard let url = NoteLinks.url(kind: "note", items: items) else { continue }
                let label = link.label.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
                let destination = url.absoluteString.replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E")
                rewritten.replaceCharacters(in: link.range, with: "[\(label)](<\(destination)>)")
            }
            return rewritten as String
        }.joined(separator: "\n")
        var rich = (try? AttributedString(markdown: escaped, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(content)
        for run in rich.runs {
            if run.link != nil { rich[run.range].foregroundColor = Theme.accent }
            if run.inlinePresentationIntent?.contains(.code) == true {
                rich[run.range].backgroundColor = Theme.raised
            }
        }
        return rich
    }

    private func termPieces(_ rich: AttributedString) -> (text: Text, terms: [Term]) {
        guard !index.terms.isEmpty else { return (Text(rich), []) }
        let plain = String(rich.characters)
        var position = rich.startIndex
        var text = Text("")
        var terms: [Term] = []
        for match in index.matches(in: plain) {
            guard let start = AttributedString.Index(match.range.lowerBound, within: rich),
                  let end = AttributedString.Index(match.range.upperBound, within: rich),
                  start >= position else { continue }
            var segment = AttributedString(rich[start..<end])
            guard !segment.runs.contains(where: { $0.link != nil || $0.inlinePresentationIntent?.contains(.code) == true }),
                  let url = NoteLinks.url(kind: "term", items: [URLQueryItem(name: "target", value: match.term.id)]) else { continue }
            let before = Text(AttributedString(rich[position..<start]))
            segment.link = url
            segment.foregroundColor = Theme.text
            let linked = Text(segment).customAttribute(TermRun(term: match.term))
            text = Text("\(text)\(before)\(linked)")
            terms.append(match.term)
            position = end
        }
        guard !terms.isEmpty else { return (Text(rich), []) }
        let tail = Text(AttributedString(rich[position..<rich.endIndex]))
        return (Text("\(text)\(tail)"), terms)
    }
}
