import SwiftUI
import StrataCore

@MainActor
struct HomeScreen: View {
    let catalog: ShellCatalog
    private var model: AppModel { catalog.model }

    var body: some View {
        let notes = catalog.recentNotes
        let maps = catalog.maps
        let needsStarter = !catalog.entries.contains { !$0.builtIn }
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                header
                if !maps.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Architecture maps", count: maps.count)
                        if needsStarter, let example = maps.first, maps.count == 1 {
                            HStack(alignment: .top, spacing: 12) {
                                LibraryCard(entry: example, model: model)
                                    .frame(width: 254)
                                gettingStarted(compact: true)
                            }
                        } else {
                            cards(maps)
                        }
                    }
                }
                if needsStarter && maps.count != 1 {
                    gettingStarted(compact: false)
                }
                if !notes.isEmpty { recentNotes(notes) }
                if !catalog.simulators.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        sectionTitle("Simulators", count: catalog.simulators.count)
                        ForEach(catalog.simulatorGroups, id: \.category) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                StrataSectionLabel(group.category)
                                cards(group.entries)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 1220, alignment: .leading)
            .padding(.horizontal, 30)
            .padding(.top, 21)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Theme.bg)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Library").font(Theme.title)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                ShellCommand.newNote.perform(on: model)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus").font(Theme.ui(11, .semibold))
                    Text("New note").font(Theme.ui(12, .medium))
                    StrataKeycap("⌘N")
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .card(Theme.raised, radius: Theme.radiusSmall)
            }
            .buttonStyle(.plain)
        }
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title).font(Theme.heading)
            Text(count.formatted()).font(Theme.mono(11)).foregroundStyle(Theme.faint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func cards(_ entries: [Library.Entry]) -> some View {
        LazyVGrid(columns: [.init(.adaptive(minimum: 230, maximum: 370), spacing: 10)], alignment: .leading, spacing: 10) {
            ForEach(entries, id: \.shellIdentity) { entry in
                LibraryCard(entry: entry, model: model)
            }
        }
    }

    private func recentNotes(_ paths: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Recent notes", count: paths.count)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), alignment: .leading) {
                ForEach(paths, id: \.self) { path in
                    Button {
                        model.open(.note(path))
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "note.text").foregroundStyle(Theme.muted)
                            Text(ShellCatalog.title(path)).lineLimit(1)
                            Spacer(minLength: 4)
                            Image(systemName: "arrow.up.right").font(Theme.ui(9, .medium)).foregroundStyle(Theme.faint)
                        }
                        .font(Theme.ui(12))
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .card(Theme.surface, radius: Theme.radiusSmall)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func gettingStarted(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Map a project", systemImage: "square.stack.3d.up")
                .font(Theme.heading)
                .foregroundStyle(Theme.accent)
            let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
            layout {
                starterStep("Ask an agent", command: "use the strata skill to map ~/work/<repo>", symbol: "text.bubble",
                            inline: compact)
                starterStep("Use the CLI", command: "strata new <id> --kind architecture", symbol: "terminal",
                            inline: compact)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: compact ? 142 : nil, alignment: .leading)
        .card(Theme.surface)
    }

    private func starterStep(_ title: String, command: String, symbol: String, inline: Bool) -> some View {
        let layout = inline ? AnyLayout(HStackLayout(spacing: 10)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
        return layout {
            Label(title, systemImage: symbol)
                .font(Theme.label)
                .foregroundStyle(Theme.muted)
                .frame(width: inline ? 120 : nil, alignment: .leading)
            Text(command)
                .font(Theme.mono(11))
                .textSelection(.enabled)
                .strataCopyMenu("Copy command", text: command, overlays: model.overlays)
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(Theme.bg, radius: Theme.radiusSmall)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
private struct LibraryCard: View {
    let entry: Library.Entry
    let model: AppModel
    @State private var hovered = false

    var body: some View {
        Button {
            if entry.manifest != nil { model.open(.sim(entry.id, path: [])) }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    StrataChip(entry.shellKind, symbol: entry.shellSymbol,
                               tint: entry.kind == .architecture ? Theme.accent : Theme.muted)
                    Spacer()
                    if entry.firstError != nil {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.bad)
                            .accessibilityLabel("Manifest error")
                    } else {
                        Image(systemName: "arrow.up.right").font(Theme.ui(10, .medium)).foregroundStyle(Theme.faint)
                    }
                }
                Text(entry.title).font(Theme.heading).lineLimit(1)
                if let summary = entry.summary ?? entry.firstError?.message {
                    Text(summary)
                        .font(Theme.ui(12))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2, reservesSpace: true)
                }
                if !entry.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(entry.tags.prefix(3).enumerated()), id: \.offset) { _, tag in
                            StrataChip(tag)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(Theme.raised)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radius)
                    .strokeBorder(hovered ? Theme.borderStrong : .clear)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .strataMenu(model.overlays) { LibraryActions(model: model).menu(for: entry) }
    }
}
