import SwiftUI
import StrataCore

@MainActor
struct Sidebar: View {
    let catalog: ShellCatalog
    private var model: AppModel { catalog.model }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(Theme.ui(15, .medium))
                        .foregroundStyle(Theme.accent)
                    Text("Strata").font(Theme.ui(15, .semibold))
                    Spacer()
                    StrataIconButton("sidebar.left", title: "Hide the sidebar", shortcut: Shortcuts.sidebar.display) {
                        ShellCommand.sidebar.perform(on: model)
                    }
                }
                search
            }
            .padding(.horizontal, 12)
            .padding(.top, 37)
            .padding(.bottom, 12)

            Rectangle().fill(Theme.border).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    VStack(spacing: 2) {
                        quickLink("Home", symbol: "house", route: .home)
                        quickLink("Graph", symbol: "point.3.connected.trianglepath.dotted", route: .graph)
                    }

                    if !catalog.maps.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            section("Architecture maps")
                            ForEach(catalog.maps, id: \.shellIdentity) { entry in libraryRow(entry) }
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        if catalog.fixtureNotes != nil {
                            HStack {
                                StrataSectionLabel("Notes")
                                Spacer()
                                StrataIconButton("plus", title: "New note", shortcut: Shortcuts.newNote.display) { ShellCommand.newNote.perform(on: model) }
                            }
                            .padding(.leading, 8)
                            .padding(.trailing, 2)
                            ForEach(catalog.notePaths, id: \.self) { path in
                                quickLink(ShellCatalog.title(path), symbol: "note.text", route: .note(path))
                            }
                        } else {
                            // The tree draws its own header, with the creation menu on right-click.
                            NotesTree(model: model)
                        }
                    }

                    if !catalog.simulators.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            section("Simulators")
                            ForEach(catalog.simulatorGroups, id: \.category) { group in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.category).font(Theme.small).foregroundStyle(Theme.faint)
                                        .padding(.leading, 8)
                                        .padding(.top, 3)
                                    ForEach(group.entries, id: \.shellIdentity) { entry in libraryRow(entry) }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            SidebarShortcutsRow { ShellCommand.shortcuts.perform(on: model) }
        }
        .frame(width: Theme.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(Theme.surface)
    }

    private var search: some View {
        Button {
            ShellCommand.palette.perform(on: model)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(Theme.ui(12, .medium))
                Text("Search or run a command…").lineLimit(1).font(Theme.ui(11))
                Spacer(minLength: 2)
                StrataKeycap("⌘K")
            }
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 7)
            .frame(height: 34)
            .card(Theme.raised, radius: Theme.radiusSmall)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .strataHint("Every command, note, sim and node", shortcut: Shortcuts.palette.display)
    }

    private func section(_ title: String) -> some View {
        StrataSectionLabel(title).padding(.leading, 8).padding(.vertical, 3)
    }

    private func quickLink(_ title: String, symbol: String, route: Route) -> some View {
        SidebarRow(title: title, symbol: symbol, selected: model.route == route) { model.open(route) }
    }

    private func libraryRow(_ entry: Library.Entry) -> some View {
        let selected = switch model.route {
        case .sim(let id, _): id == entry.id
        default: false
        }
        // A broken manifest opens its error screen, which lists every problem with its line.
        return SidebarRow(title: entry.title, symbol: entry.shellSymbol, selected: selected,
                          trailingInset: entry.firstError != nil ? 20 : 0) {
            model.open(.sim(entry.id, path: []))
        }
        .overlay(alignment: .trailing) {
            if let error = entry.firstError { DiagnosticDot(entry: entry, diagnostic: error, overlays: model.overlays) }
        }
        .strataMenu(model.overlays) { LibraryActions(model: model).menu(for: entry) }
    }
}

@MainActor
private struct SidebarRow: View {
    let title: String
    let symbol: String
    let selected: Bool
    var trailingInset: CGFloat = 0
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(Theme.ui(12, .medium))
                    .foregroundStyle(selected ? Theme.accent : Theme.muted)
                    .frame(width: 17)
                Text(title)
                    .font(Theme.ui(12, selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.accent : Theme.text)
                    .lineLimit(1)
                Spacer(minLength: trailingInset)
            }
            .padding(.horizontal, 8)
            .frame(height: 29)
            .background(selected ? Theme.accent.opacity(0.10) : hovered ? Theme.hover : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        // A title cut short says itself in full.
        .strataHint(title.count > 28 ? title : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The sidebar's foot: the way to every shortcut, quiet until hovered.
@MainActor
private struct SidebarShortcutsRow: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "keyboard").font(Theme.ui(11, .medium)).frame(width: 17)
                Text("Keyboard shortcuts").font(Theme.ui(11))
                Spacer(minLength: 4)
                StrataKeycap("?")
            }
            .foregroundStyle(hovered ? Theme.text : Theme.faint)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(hovered ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .strataHint("Every shortcut, by area", shortcut: Shortcuts.sheet.display)
    }
}

@MainActor
private struct DiagnosticDot: View {
    let entry: Library.Entry
    let diagnostic: Diagnostic
    let overlays: Overlays
    @State private var hovered = false
    @State private var frame: CGRect = .zero
    @State private var presented = false
    private var termID: String { "manifest-error/\(entry.url.path)" }

    var body: some View {
        Circle()
            .fill(Theme.bad)
            .frame(width: 6, height: 6)
            .frame(width: 28, height: 29)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame = $0 }
            .onHover { hovered = $0 }
            .task(id: hovered) {
                guard hovered else { dismiss(); return }
                do {
                    try await Task.sleep(for: .milliseconds(300))
                    var term = Term(id: termID, term: "Manifest error", short: diagnostic.message)
                    var location = entry.url.lastPathComponent
                    if let line = diagnostic.line { location += " · line \(line)" }
                    if let path = diagnostic.path { location += " · \(path)" }
                    term.detail = location
                    overlays.showTerm(term, anchor: frame)
                    presented = overlays.card?.term.id == termID
                } catch {}
            }
            .onDisappear(perform: dismiss)
            .accessibilityLabel("Manifest error. \(diagnostic.message)")
    }

    private func dismiss() {
        if presented, overlays.card?.term.id == termID { overlays.hideTerm() }
        presented = false
    }
}
