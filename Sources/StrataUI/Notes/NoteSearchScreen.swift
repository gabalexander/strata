import SwiftUI
import StrataCore

/// Full-text search across the vault.
@MainActor
public struct SearchScreen: View {
    let model: AppModel
    let query: String
    @State private var input: String
    @State private var results: SearchResults
    @FocusState private var focused: Bool

    public init(model: AppModel, query: String) {
        self.model = model
        self.query = query
        _input = State(initialValue: query)
        _results = State(initialValue: SearchResults(query: query.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    public var body: some View {
        let request = SearchRequest(input: input, revision: model.vault.revision)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Search notes")
                    .font(Theme.title)
                    .accessibilityAddTraits(.isHeader)
                searchField
            }
            .frame(maxWidth: 744, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity)
            .background(Theme.surface)

            Rectangle().fill(Theme.border).frame(height: 1)

            if results.groups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        Text(results.groups.count == 1 ? "1 note" : "\(results.groups.count) notes")
                            .font(Theme.label).foregroundStyle(Theme.muted).padding(.bottom, 2)
                        ForEach(results.groups) { group in resultGroup(group) }
                    }
                    .frame(maxWidth: 744, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .foregroundStyle(Theme.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .onChange(of: query) { _, new in input = new }
        .task(id: request) {
            let query = request.input.trimmingCharacters(in: .whitespacesAndNewlines)
            if results.query != query {
                do { try await Task.sleep(for: .milliseconds(110)) }
                catch { return }
            }
            guard let groups = try? await model.vault.searchNotes(query),
                  !Task.isCancelled, request.input == input, request.revision == model.vault.revision else { return }
            results = SearchResults(query: query, groups: groups)
        }
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").font(Theme.ui(14)).foregroundStyle(focused ? Theme.accent : Theme.muted)
                .accessibilityHidden(true)
            TextField("Find a title or text", text: $input)
                .font(Theme.ui(14))
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { model.replace(.search(input.trimmingCharacters(in: .whitespacesAndNewlines))) }
            if !input.isEmpty {
                NoteIconButton(title: "Clear search", symbol: "xmark.circle.fill") { input = ""; focused = true }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 37)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(focused ? Theme.accent.opacity(0.5) : Theme.borderStrong))
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(Theme.ui(22))
                .foregroundStyle(Theme.faint)
                .accessibilityHidden(true)
            Text(results.query.isEmpty ? "Search your vault" : "No matching notes")
                .font(Theme.heading)
            Text(results.query.isEmpty ? "Enter a title or a phrase from a note." : "Try a shorter or different phrase.")
                .font(Theme.ui())
                .foregroundStyle(Theme.muted)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultGroup(_ group: NoteSearchGroup) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text").font(Theme.ui(12)).foregroundStyle(Theme.muted)
                    .accessibilityHidden(true)
                Text(highlight(NoteLinks.title(group.path))).font(Theme.ui(13, .semibold))
                    .lineLimit(1).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                let folder = (group.path as NSString).deletingLastPathComponent
                if !folder.isEmpty {
                    Text(folder.replacingOccurrences(of: "/", with: "  /  "))
                        .font(Theme.small).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Theme.raised)
            ForEach(group.hits) { hit in
                Rectangle().fill(Theme.border).frame(height: 1)
                HitRow(hit: hit, excerpt: highlight(hit.excerpt)) {
                    if case .search = model.route, model.route != .search(results.query) {
                        model.replace(.search(results.query))
                    }
                    NoteWorkspace.of(model).open(hit.path, at: .line(hit.line), model: model)
                }
            }
        }
        .card(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    private func highlight(_ text: String) -> AttributedString {
        var result = AttributedString()
        var cursor = text.startIndex
        while !results.query.isEmpty, let match = text.range(of: results.query, options: .caseInsensitive, range: cursor..<text.endIndex) {
            result += AttributedString(text[cursor..<match.lowerBound])
            var marked = AttributedString(text[match])
            marked.foregroundColor = Theme.accent
            marked.backgroundColor = Theme.accent.opacity(0.12)
            result += marked
            cursor = match.upperBound
        }
        result += AttributedString(text[cursor...])
        return result
    }
}

private struct SearchRequest: Equatable {
    var input: String
    var revision: Int
}

private struct SearchResults {
    let query: String
    var groups: [NoteSearchGroup] = []
}

private struct HitRow: View {
    let hit: SearchHit
    let excerpt: AttributedString
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(hit.line)")
                    .font(Theme.mono(11)).foregroundStyle(Theme.faint)
                    .frame(minWidth: 20, alignment: .trailing)
                    .accessibilityLabel("Line \(hit.line)")
                Text(excerpt).font(Theme.ui(13)).foregroundStyle(Theme.text)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.left")
                    .font(Theme.ui(10, .medium)).foregroundStyle(hovered ? Theme.accent : Theme.faint)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(hovered ? Theme.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
