import AppKit
import SwiftUI
import StrataCore

@MainActor
enum SimSessions {
    static func cachedManifest(_ model: AppModel, id: String) -> Manifest? {
        if let manifest = model.library.manifest(id) { return manifest }
        guard let sim = model.sessions[AppModel.sessionKey(id, [])], case .inline = sim.manifest.source else { return nil }
        return sim.manifest
    }

    static func cached(_ model: AppModel, id: String, path: [String], manifest: Manifest,
                       parentRate: Double?) -> Simulation {
        if let sim = model.sessions[AppModel.sessionKey(id, path)],
           sim.parentRate == parentRate, same(sim.manifest, manifest) { return sim }
        return Simulation(manifest: manifest, path: path, parentRate: parentRate)
    }

    static func drillDestination(_ node: Node, id: String, path: [String]) -> Route? {
        if let detail = node.detail { return .sim(detail, path: []) }
        if node.inside != nil { return .sim(id, path: path + [node.id]) }
        return nil
    }

    static func remember(_ sim: Simulation, model: AppModel, id: String) {
        let prefix = AppModel.sessionKey(id, []) + "|"
        let stale = model.sessions.keys.filter { key in
            (key == id || key.hasPrefix(prefix)) && model.sessions[key].map { !same($0.manifest, sim.manifest) } == true
        }
        for key in stale { model.sessions.removeValue(forKey: key) }
        model.sessions[AppModel.sessionKey(id, sim.path)] = sim
    }

    static func forget(_ id: String, from model: AppModel) {
        let prefix = AppModel.sessionKey(id, []) + "|"
        model.sessions = model.sessions.filter { $0.key != id && !$0.key.hasPrefix(prefix) }
    }

    // Manifest has value semantics. Compare decoded fields, including nested levels, without
    // treating a library refresh for another id as a reason to discard live simulation state.
    nonisolated static func same(_ a: Manifest, _ b: Manifest) -> Bool {
        func equal(_ a: Any, _ b: Any) -> Bool {
            guard type(of: a) == type(of: b) else { return false }
            if let a = a as? AnyHashable, let b = b as? AnyHashable { return a == b }
            let am = Mirror(reflecting: a)
            let bm = Mirror(reflecting: b)
            guard am.children.count == bm.children.count else { return false }
            if am.children.isEmpty { return String(reflecting: a) == String(reflecting: b) }
            return zip(am.children, bm.children).allSatisfy { left, right in
                left.label == right.label && equal(left.value, right.value)
            }
        }
        return equal(a, b)
    }
}

@MainActor
struct SimLoadIssue: View {
    let model: AppModel
    let id: String
    let invalidPath: [String]?

    var body: some View {
        let entry = model.library.entry(id)
        let url = entry?.url ?? model.library.dirs.first?.appendingPathComponent(id + ".yaml")
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(Theme.title).foregroundStyle(Theme.warn)
                Text(invalidPath == nil ? "Simulator unavailable" : "Level unavailable")
                    .font(Theme.title).foregroundStyle(Theme.text)
                Text(invalidPath.map { "“\($0.joined(separator: " › "))” is no longer in \(entry?.title ?? id)." } ??
                     entry?.title ?? id)
                    .font(Theme.ui()).foregroundStyle(Theme.muted)
                if let url {
                    Text(url.path).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                }
                if let entry {
                    ForEach(Array(entry.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Text(diagnostic.line.map(String.init) ?? "—")
                                .font(Theme.mono(11)).foregroundStyle(diagnostic.severity == .error ? Theme.bad : Theme.warn)
                                .frame(minWidth: 28, alignment: .leading)
                            Text(diagnostic.message).font(Theme.ui()).foregroundStyle(Theme.text)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if invalidPath != nil {
                    SimButton(title: "Open root level", icon: "arrow.up") { model.open(.sim(id, path: [])) }
                }
            }
            .frame(maxWidth: 460, alignment: .leading)
            .padding(22)
            .card()
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .defaultScrollAnchor(.center, for: .alignment)
        .background(Theme.bg)
    }
}
