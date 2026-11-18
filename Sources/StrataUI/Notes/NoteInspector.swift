import SwiftUI
import StrataCore

@MainActor
struct NoteInspector: View {
    let model: AppModel
    let path: String
    let document: NoteDocument
    let showLine: (Int) -> Void

    /// A node note lives at "Sims/<sim>/<level path…>/<node>.md" (see `Vault.nodeNotePath`).
    private var node: (sim: String, path: [String], id: String, label: String, place: String)? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "Sims", let last = parts.last,
              let manifest = SimSessions.cachedManifest(model, id: parts[1]) else { return nil }
        let levelPath = Array(parts.dropFirst(2).dropLast())
        let leaf = NoteLinks.title(last)
        guard let level = manifest.level(at: levelPath), let node = level.node(leaf) else { return nil }
        var place = manifest.title
        if let parent = levelPath.last, let label = manifest.level(at: Array(levelPath.dropLast()))?.node(parent)?.label {
            place += " › " + label
        }
        return (manifest.id, levelPath, node.id, node.label, place)
    }

    var body: some View {
        let links = model.vault.outgoingLinks(from: path)
        let backlinks = model.vault.backlinks(to: path)
        let sims = linkedSims(links)
        VStack(alignment: .leading, spacing: 0) {
            Text("Note details")
                .font(Theme.heading)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 15)
                .frame(height: 42)
            Rectangle().fill(Theme.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let node {
                        item("Back to \(node.label)", detail: node.place, icon: "arrow.uturn.backward") {
                            SimFocus.of(model).reveal(node.id, in: node.sim, path: node.path, model: model)
                        }
                        .card(Theme.raised, radius: Theme.radiusSmall)
                    }
                    section("Outline", empty: document.headings.isEmpty ? "No headings" : nil) {
                        ForEach(document.headings) { heading in
                            item(heading.title, detail: nil, icon: "number") { showLine(heading.line) }
                                .padding(.leading, CGFloat(min(heading.level - 1, 4)) * 10)
                        }
                    }
                    section("Backlinks", empty: backlinks.isEmpty ? "No notes link here" : nil) {
                        ForEach(backlinks, id: \.self) { source in
                            item(NoteLinks.title(source), detail: backlinkExcerpt(from: source),
                                 icon: "arrow.up.left") { model.open(.note(source)) }
                        }
                    }
                    section("Outgoing links", empty: links.isEmpty ? "No wiki links" : nil) {
                        ForEach(links, id: \.range.location) { link in
                            item(link.label, detail: link.alias == nil ? nil : link.target, icon: "link") {
                                NoteLinks.open(link.target, heading: link.heading, from: path, model: model)
                            }
                        }
                    }
                    section("Linked sims", empty: sims.isEmpty ? "No linked simulators" : nil) {
                        ForEach(sims, id: \.self) { id in
                            let entry = model.library.entry(id)
                            item(entry?.title ?? id, detail: entry == nil ? "Simulator unavailable" : nil,
                                 icon: "play.rectangle", enabled: entry != nil) { model.open(.sim(id, path: [])) }
                        }
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 15)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surface)
    }

    private func backlinkExcerpt(from source: String) -> String? {
        guard let excerpt = model.vault.backlinkExcerpt(from: source, to: path) else { return nil }
        let display = NSMutableString(string: excerpt)
        for link in NoteSyntax.wikiLinks(in: excerpt).reversed() {
            display.replaceCharacters(in: link.range, with: link.label)
        }
        return display as String
    }

    private func linkedSims(_ links: [NoteSyntax.WikiLink]) -> [String] {
        var seen: Set<String> = []
        let wikiSims = links.map(\.target).filter { model.vault.resolve(link: $0) == nil && model.library.entry($0) != nil }
        return (model.vault.embeddedSimIDs(in: path) + wikiSims).filter { seen.insert($0).inserted }
    }

    private func section<Content: View>(_ title: String, empty: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.label).foregroundStyle(Theme.muted)
                .padding(.horizontal, 5)
                .accessibilityAddTraits(.isHeader)
            if let empty {
                Text(empty).font(Theme.small).foregroundStyle(Theme.faint)
                    .padding(.horizontal, 5).padding(.vertical, 5)
            } else {
                content()
            }
        }
    }

    private func item(_ title: String, detail: String?, icon: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        InspectorNoteRow(title: title, detail: detail, icon: icon, action: action).disabled(!enabled)
    }
}

private struct InspectorNoteRow: View {
    let title: String
    let detail: String?
    let icon: String
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon).font(Theme.ui(11)).foregroundStyle(hovered && enabled ? Theme.accent : Theme.faint)
                    .frame(width: 13)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Theme.ui(12)).foregroundStyle(enabled ? Theme.text : Theme.muted).lineLimit(1)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(Theme.small).foregroundStyle(Theme.muted).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(hovered && enabled ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
