import Foundation
import StrataCore
import StrataUI

/// What state.json keeps: the open route, and per map the stage's vertical/horizontal switch and its Links control.
struct RouteState: Codable {
    private enum Screen: String, Codable { case home, note, sim, graph, search }
    private let screen: Screen
    private var target: String?
    private var path: [String]?
    /// AppModel.layoutDirections, as raw values so an unknown one is skipped rather than failing the file.
    private var directions: [String: String]?
    /// AppModel.linkOptions that differ from the defaults ("Show all links" is not kept).
    private var links: [String: StageLinkOptions]?

    init(_ route: Route, directions: [String: FlowDirection] = [:], links: [String: StageLinkOptions] = [:]) {
        switch route {
        case .home: screen = .home
        case .graph: screen = .graph
        case .note(let note): screen = .note; target = note
        case .sim(let id, let level): screen = .sim; target = id; path = level
        case .search(let query): screen = .search; target = query
        }
        self.directions = directions.isEmpty ? nil : directions.mapValues(\.rawValue)
        let saved = links.filter(\.value.saved)
        self.links = saved.isEmpty ? nil : saved
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

    var layoutDirections: [String: FlowDirection] { (directions ?? [:]).compactMapValues(FlowDirection.init(rawValue:)) }

    var linkOptions: [String: StageLinkOptions] { links ?? [:] }

    static func load(from url: URL = StrataPaths.state) -> RouteState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save(to url: URL = StrataPaths.state) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
