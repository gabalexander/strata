import SwiftUI
import StrataCore

/// The whole window, including the routes and transient UI shared by all screens.
@MainActor
public struct RootView: View {
    private let catalog: ShellCatalog
    private var model: AppModel { catalog.model }
    @State private var recentPalettePicks: [String] = []

    public init(model: AppModel) {
        catalog = ShellCatalog(model: model)
    }

    /// Supplies shelf data for offscreen snapshots while the disk-backed services are under development.
    public init(model: AppModel, fixtureEntries: [Library.Entry], fixtureNotes: [String: String],
                fixturePaletteQuery: String = "") {
        catalog = ShellCatalog(model: model, fixtureEntries: fixtureEntries, fixtureNotes: fixtureNotes,
                               fixturePaletteQuery: fixturePaletteQuery)
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                if model.sidebarVisible {
                    Sidebar(catalog: catalog)
                    Rectangle().fill(Theme.border).frame(width: 1)
                }
                screen
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 34)
            }
            if !model.sidebarVisible {
                StrataIconButton("sidebar.left", title: "Show sidebar ⌘\\") {
                    ShellCommand.sidebar.perform(on: model)
                }
                .padding(.leading, 80)
                .padding(.top, 3)
            }
            if model.paletteOpen || model.switcherOpen {
                CommandPalette(catalog: catalog, switching: model.switcherOpen, recent: $recentPalettePicks)
                    .id(model.switcherOpen)
            }
            OverlayHost(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .font(Theme.ui())
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .background(Theme.bg)
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var screen: some View {
        switch model.route {
        case .home: HomeScreen(catalog: catalog)
        case .note(let path): NoteScreen(model: model, path: path)
        case .sim(let id, let path): SimScreen(model: model, id: id, path: path)
        case .graph: GraphScreen(catalog: catalog)
        case .search(let query): SearchScreen(model: model, query: query)
        }
    }
}
