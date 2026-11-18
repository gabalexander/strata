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

extension Route {
    init?(strataURL string: String) {
        guard let url = URLComponents(string: string), url.scheme?.lowercased() == "strata",
              url.user == nil, url.password == nil, url.port == nil else { return nil }
        let target = String(url.path.dropFirst())
        switch url.host?.lowercased() {
        case "sim" where !target.isEmpty && !target.contains("/"):
            let path = url.queryItems?.first { $0.name == "path" }?.value ?? ""
            self = .sim(target, path: path.split(separator: "/").map(String.init))
        case "note" where !target.isEmpty:
            let parts = target.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !target.contains("\0") else { return nil }
            self = .note(target)
        case "search" where target.isEmpty:
            self = .search(url.queryItems?.first { $0.name == "q" }?.value ?? "")
        default: return nil
        }
    }
}
