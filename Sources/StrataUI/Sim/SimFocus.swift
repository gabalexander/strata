import Foundation
import Observation
import StrataCore

/// Asks a sim level to select a node when it appears, or right away when it is already on screen
/// (a note's "Back to node", a node picked in the ⌘K palette).
@MainActor
@Observable
final class SimFocus {
    struct Request: Equatable {
        let id = UUID()
        let session: String
        let node: String
    }

    private(set) var request: Request?

    private static let stores = NSMapTable<AppModel, SimFocus>.weakToStrongObjects()
    static func of(_ model: AppModel) -> SimFocus {
        if let store = stores.object(forKey: model) { return store }
        let store = SimFocus()
        stores.setObject(store, forKey: model)
        return store
    }

    /// Opens the level that holds `node` with it selected. An existing session for that level keeps
    /// its state (and the parent rate it was opened with).
    func reveal(_ node: String, in id: String, path: [String], model: AppModel) {
        let key = AppModel.sessionKey(id, path)
        request = Request(session: key, node: node)
        model.open(.sim(id, path: path), parentRate: model.sessions[key]?.parentRate)
    }

    /// Selects `node` when the level `session` next appears, without opening it: a dive is already on its
    /// way there (a component chip on a card).
    func select(_ node: String, onArrival session: String) {
        request = Request(session: session, node: node)
    }

    /// The node to select at this level, once.
    func take(for session: String) -> String? {
        guard let request, request.session == session else { return nil }
        self.request = nil
        return request.node
    }
}
