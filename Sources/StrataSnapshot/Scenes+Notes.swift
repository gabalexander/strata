import SwiftUI
import StrataCore
import StrataUI

@MainActor func notesScenes() -> [Scene] {
    [Scene(name: "notes-note", size: CGSize(width: 1100, height: 800), hosted: true) {
        let model = AppModel(library: Library(manifests: [Fixtures.checkout]), vault: Vault(root: URL(fileURLWithPath: "/tmp/strata-snap-vault")))
        return AnyView(NoteScreen(model: model, path: "Welcome.md"))
    }]
}
