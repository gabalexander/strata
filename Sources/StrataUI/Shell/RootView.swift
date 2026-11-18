import SwiftUI
import StrataCore

// PLACEHOLDER (shell agent). Keep the initialiser.

/// The whole window: sidebar (notes tree, sims library), the current route's screen, overlays on top.
public struct RootView: View {
    let model: AppModel
    public init(model: AppModel) { self.model = model }
    public var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading) { NotesTree(model: model) }
                .frame(width: Theme.sidebarWidth).frame(maxHeight: .infinity).background(Theme.surface)
            Group {
                switch model.route {
                case .home: Text("Strata").font(Theme.title).frame(maxWidth: .infinity, maxHeight: .infinity)
                case .note(let p): NoteScreen(model: model, path: p)
                case .sim(let id, let path): SimScreen(model: model, id: id, path: path)
                case .graph: Text("Graph").frame(maxWidth: .infinity, maxHeight: .infinity)
                case .search(let q): SearchScreen(model: model, query: q)
                }
            }
        }
        .foregroundStyle(Theme.text)
        .background(Theme.bg)
    }
}
