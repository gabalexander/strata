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

    @MainActor
    private final class Parts {
        let terms: TermIndex
        let renderer: StageRenderer
        init(_ sim: Simulation) {
            terms = TermIndex(manifest: sim.manifest)
            renderer = StageRenderer(level: sim.level)
        }
    }
    private static let parts = NSMapTable<Simulation, Parts>.weakToStrongObjects()

    private static func parts(for sim: Simulation) -> Parts {
        if let parts = parts.object(forKey: sim) { return parts }
        let made = Parts(sim)
        parts.setObject(made, forKey: sim)
        return made
    }

    /// The glossary for a session, built once: a new index recompiles its matcher on first use.
    static func terms(for sim: Simulation) -> TermIndex { parts(for: sim).terms }

    /// The stage layout and drawing caches for a session, built once instead of on every visit.
    static func renderer(for sim: Simulation) -> StageRenderer { parts(for: sim).renderer }

    private final class Handoffs { var keys: Set<String> = [] }
    private static let handoffs = NSMapTable<AppModel, Handoffs>.weakToStrongObjects()

    /// Marks an embed whose simulation now also runs full screen (⤢), so both keep sharing it.
    static func handOff(_ embed: String, model: AppModel) {
        let store = handoffs.object(forKey: model) ?? Handoffs()
        store.keys.insert(embed)
        handoffs.setObject(store, forKey: model)
    }

    /// The shared simulation for an embed that was expanded earlier, if it still matches the manifest.
    static func handedOff(_ embed: String, model: AppModel, id: String, path: [String], manifest: Manifest) -> Simulation? {
        guard handoffs.object(forKey: model)?.keys.contains(embed) == true,
              let sim = model.sessions[AppModel.sessionKey(id, path)], sim.parentRate == nil,
              same(sim.manifest, manifest) else { return nil }
        return sim
    }

    static func forget(_ id: String, from model: AppModel) {
        let prefix = AppModel.sessionKey(id, []) + "|"
        model.sessions = model.sessions.filter { $0.key != id && !$0.key.hasPrefix(prefix) }
    }

    // Manifest has value semantics. Compare decoded fields, including nested levels, without
    // treating a library refresh for another id as a reason to discard live simulation state.
    nonisolated static func same(_ a: Manifest, _ b: Manifest) -> Bool {
        // A session's manifest is usually a copy of the library's, sharing every buffer: identical bytes
        // answer at once, where the reflective walk below takes milliseconds on a large manifest.
        if withUnsafeBytes(of: a, { x in withUnsafeBytes(of: b) { y in x.elementsEqual(y) } }) { return true }
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
                Text(title(entry)).font(Theme.title).foregroundStyle(Theme.text)
                Text(message(entry)).font(Theme.ui()).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let url {
                    VStack(alignment: .leading, spacing: 3) {
                        if entry == nil { Text("Expected at").font(Theme.label).foregroundStyle(Theme.faint) }
                        Text(url.path).font(Theme.mono(11)).foregroundStyle(Theme.muted).textSelection(.enabled)
                            .strataCopyMenu("Copy path", text: url.path, overlays: model.overlays)
                    }
                }
                if let entry, invalidPath == nil {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(entry.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                            HStack(alignment: .firstTextBaseline, spacing: 9) {
                                Text(diagnostic.line.map { "line \($0)" } ?? "—")
                                    .font(Theme.mono(11))
                                    .foregroundStyle(diagnostic.severity == .error ? Theme.bad : Theme.warn)
                                    .frame(minWidth: 52, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(diagnostic.message).font(Theme.ui()).foregroundStyle(Theme.text)
                                    if let path = diagnostic.path {
                                        Text(path).font(Theme.mono(11)).foregroundStyle(Theme.faint)
                                    }
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 4)
                }
                HStack(spacing: 6) {
                    if invalidPath != nil {
                        SimButton(title: "Open root level", icon: "arrow.up") { model.open(.sim(id, path: [])) }
                    }
                    if let entry, !entry.builtIn {
                        SimButton(title: "Open file", icon: "doc.text") { model.openCode(entry.url.path, repo: nil) }
                    }
                    if let entry {
                        SimButton(title: "Reveal in Finder", icon: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                        }
                    }
                    SimButton(title: "Go home", icon: "house") { model.open(.home) }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(22)
            .card()
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .defaultScrollAnchor(.center, for: .alignment)
        .background(Theme.bg)
    }

    private func title(_ entry: Library.Entry?) -> String {
        if invalidPath != nil { return "Level unavailable" }
        guard let entry else { return "No simulator “\(id)”" }
        return entry.manifest == nil ? "\(entry.title) has an error" : entry.title
    }

    private func message(_ entry: Library.Entry?) -> String {
        if let invalidPath {
            return "“\(invalidPath.joined(separator: " › "))” is no longer in \(entry?.title ?? id)."
        }
        guard let entry else {
            return "Nothing in the library has this id. It may have been renamed or deleted. Strata opens it as soon as a manifest with this id appears."
        }
        let errors = entry.diagnostics.filter { $0.severity == .error }.count
        let count = errors == 1 ? "1 error" : "\(errors) errors"
        return entry.builtIn ? "This built-in manifest has \(count)."
            : "Fix the \(count) below and save. Strata reloads the file as soon as it changes."
    }
}
