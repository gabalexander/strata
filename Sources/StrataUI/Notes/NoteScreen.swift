import SwiftUI
import StrataCore

// PLACEHOLDER (notes agent). Keep the initialisers.

/// A note: live-styled markdown editor, reading view with embedded sims (⌘E toggles), inspector with backlinks and outline.
public struct NoteScreen: View {
    let model: AppModel
    let path: String
    public init(model: AppModel, path: String) { self.model = model; self.path = path }
    public var body: some View {
        Text(path).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
    }
}

/// The vault file tree for the sidebar (right-click: new note/folder, rename, delete, reveal).
public struct NotesTree: View {
    let model: AppModel
    public init(model: AppModel) { self.model = model }
    public var body: some View { Text("Notes").foregroundStyle(Theme.muted) }
}

/// Full-text search results across the vault.
public struct SearchScreen: View {
    let model: AppModel
    let query: String
    public init(model: AppModel, query: String) { self.model = model; self.query = query }
    public var body: some View { Text("Search: \(query)").foregroundStyle(Theme.muted).frame(maxWidth: .infinity, maxHeight: .infinity) }
}
