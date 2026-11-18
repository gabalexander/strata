import SwiftUI
import StrataCore
import StrataUI

@MainActor func shellScenes() -> [Scene] {
    [Scene(name: "shell-root", size: CGSize(width: 1400, height: 880), hosted: true) {
        let model = AppModel(library: Library(manifests: [Fixtures.checkout]), vault: Vault(root: URL(fileURLWithPath: "/tmp/strata-snap-vault")))
        return AnyView(RootView(model: model))
    }]
}
