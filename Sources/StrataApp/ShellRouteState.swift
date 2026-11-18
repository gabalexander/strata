import Foundation
import StrataCore
import StrataUI

struct RouteState: Codable {
    private enum Screen: String, Codable { case home, note, sim, graph, search }
    private let screen: Screen
    private var target: String?
    private var path: [String]?

    init(_ route: Route) {
        switch route {
        case .home: screen = .home
        case .graph: screen = .graph
        case .note(let note): screen = .note; target = note
        case .sim(let id, let level): screen = .sim; target = id; path = level
        case .search(let query): screen = .search; target = query
        }
    }

    var route: Route {
        switch screen {
        case .home: .home
        case .graph: .graph
        case .note: target.map(Route.note) ?? .home
        case .sim: target.map { .sim($0, path: path ?? []) } ?? .home
        case .search: .search(target ?? "")
        }
    }

    static func load(from url: URL = StrataPaths.state) -> Route {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(Self.self, from: data) else { return .home }
        return state.route
    }

    func save(to url: URL = StrataPaths.state) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
