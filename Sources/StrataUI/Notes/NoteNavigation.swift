import AppKit
import Observation
import SwiftUI
import StrataCore

@MainActor
@Observable
final class NoteWorkspace {
    enum Location { case line(Int), heading(String) }

    struct Destination: Identifiable {
        let id = UUID()
        let path: String
        let location: Location
    }

    private static let workspaces = NSMapTable<AppModel, NoteWorkspace>.weakToStrongObjects()
    static func of(_ model: AppModel) -> NoteWorkspace {
        if let workspace = workspaces.object(forKey: model) { return workspace }
        let workspace = NoteWorkspace()
        workspaces.setObject(workspace, forKey: model)
        return workspace
    }

    var reading: Set<String> = []
    var expanded: Set<String> = []
    var destination: Destination?
    var commandOwner: UUID?
    @ObservationIgnored var drafts: [String: String] = [:]
    @ObservationIgnored weak var session: NoteSession?

    func open(_ path: String, at location: Location, model: AppModel) {
        destination = Destination(path: path, location: location)
        model.open(.note(path))
    }

    func remap(_ old: String, to new: String?, model: AppModel) {
        func remapped(_ path: String) -> String? {
            guard path == old || path.hasPrefix(old + "/") else { return path }
            return new.map { $0 + path.dropFirst(old.count) }
        }
        reading = Set(reading.compactMap(remapped))
        expanded = Set(expanded.compactMap(remapped))
        if let destination, let moved = remapped(destination.path) {
            self.destination = Destination(path: moved, location: destination.location)
        } else {
            destination = nil
        }
        if case .note(let current) = model.route, current == old || current.hasPrefix(old + "/") {
            model.replace(remapped(current).map(Route.note) ?? .home)
        }
    }

    func expandAncestors(of path: String) {
        var folder = (path as NSString).deletingLastPathComponent
        while !folder.isEmpty {
            expanded.insert(folder)
            folder = (folder as NSString).deletingLastPathComponent
        }
    }
}

@MainActor
enum NoteLinks {
    static func open(_ target: String, heading: String? = nil, from note: String, model: AppModel) {
        let path = target.isEmpty ? note : model.vault.resolve(link: target)
        if let path {
            if let heading { NoteWorkspace.of(model).open(path, at: .heading(heading), model: model) }
            else { model.open(.note(path)) }
        } else if let entry = model.library.entry(target) {
            model.open(.sim(entry.id, path: []))
        } else {
            let path = target.lowercased().hasSuffix(".md") ? target : target + ".md"
            model.open(.note(path))
        }
    }

    static func url(kind: String, items: [URLQueryItem]) -> URL? {
        var components = URLComponents()
        components.scheme = "strata"
        components.host = kind
        components.queryItems = items
        return components.url
    }

    static func copy(_ content: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
    }

    static func title(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    static func label(_ path: String) -> String {
        path.lowercased().hasSuffix(".md") ? String(path.dropLast(3)) : path
    }
}

struct NoteIconButton: View {
    let title: String
    let symbol: String
    var active = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(Theme.ui(13, .medium))
                .foregroundStyle(active ? Theme.accent : hover ? Theme.text : Theme.muted)
                .frame(width: 28, height: 28)
                .background(active ? Theme.accent.opacity(0.12) : hover ? Theme.hover : .clear,
                            in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(title)
    }
}
