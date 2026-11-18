import SwiftUI
import StrataCore
import StrataUI

@MainActor func simScenes() -> [Scene] {
    [Scene(name: "sim-checkout", size: CGSize(width: 1400, height: 880)) {
        let model = AppModel(library: Library(manifests: [Fixtures.checkout]), vault: Vault(root: URL(fileURLWithPath: "/tmp/strata-snap-vault")))
        return AnyView(SimScreen(model: model, id: "checkout", path: []))
    }]
}
