import SwiftUI
import StrataCore

// PLACEHOLDER (stage agent). Keep the initialisers.

/// A full-window simulator: stage, toolbar, breadcrumbs, inspector, dock (controls, scenarios, log, glossary).
public struct SimScreen: View {
    let model: AppModel
    let id: String
    let path: [String]
    public init(model: AppModel, id: String, path: [String]) { self.model = model; self.id = id; self.path = path }
    public var body: some View {
        Text("Simulator \(id) \(path.joined(separator: " › "))").foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
    }
}

/// A live sim inside a note (a ```strata block): compact stage + toolbar, expandable to SimScreen.
public struct SimEmbedView: View {
    let model: AppModel
    let embed: Embed
    let note: String
    public init(model: AppModel, embed: Embed, note: String) { self.model = model; self.embed = embed; self.note = note }
    public var body: some View {
        Text("embedded sim").foregroundStyle(Theme.muted).frame(height: embed.height).frame(maxWidth: .infinity).card()
    }
}
