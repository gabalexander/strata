import AppKit
import Foundation
import Observation
import StrataCore

// Drift in the app (docs/manifest.md, Drift; docs/design.md, Drift). One store per app model, keyed by
// manifest id: the last report (from ~/.strata/drift/<id>.json or a fresh check), whether a check is
// running, and whether the repo is on this Mac at all. Checks run off the main thread; opening a map
// reads the cache and checks again only when the repo HEAD or the map file changed since.

@MainActor
@Observable
final class SimDriftState {
    struct Entry {
        var report: DriftReport?
        var running = false
        /// Set when the map names a repo that isn't on this Mac: the one quiet line the app shows.
        var missingRepo: String?
    }

    private(set) var entries: [String: Entry] = [:]
    /// Bumped when a check finishes, for views that list findings.
    private(set) var revision = 0

    @ObservationIgnored private var rerun: Set<String> = []
    @ObservationIgnored private var lastLook: [String: Date] = [:]
    /// The newest manifest seen per map: a delayed look or a rerun uses it, not the one it started with.
    @ObservationIgnored private var latest: [String: Manifest] = [:]
    @ObservationIgnored private var delayed: Set<String> = []
    @ObservationIgnored private var announce: Set<String> = []
    @ObservationIgnored private var badgeCache: [String: [String: Int]] = [:]
    @ObservationIgnored weak var overlays: Overlays?

    private static let stores = NSMapTable<AppModel, SimDriftState>.weakToStrongObjects()

    static func of(_ model: AppModel) -> SimDriftState {
        if let store = stores.object(forKey: model) { return store }
        let store = SimDriftState()
        store.overlays = model.overlays
        stores.setObject(store, forKey: model)
        return store
    }

    func entry(_ id: String) -> Entry? { entries[id] }
    func report(_ id: String) -> DriftReport? { entries[id]?.report }

    /// When a map opens (or reloads): read the cache once, then compare the repo HEAD and the map file with
    /// what the cached report was made from, and check again in the background when either moved.
    func ensure(_ manifest: Manifest) {
        guard manifest.repo != nil, DriftCache.file(of: manifest) != nil else { return }
        let id = manifest.id
        latest[id] = manifest
        // A map saved several times in a row (an agent at work) is looked at once, two seconds after.
        if let last = lastLook[id], Date().timeIntervalSince(last) < 2 {
            guard delayed.insert(id).inserted else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.delayed.remove(id) != nil, let newest = self.latest[id] else { return }
                self.lastLook[id] = nil
                self.ensure(newest)
            }
            return
        }
        lastLook[id] = Date()
        let known = entries[id]?.report
        Task.detached(priority: .utility) { [weak self] in
            let available = Drift.repoAvailable(manifest)
            let report = available ? known ?? DriftCache.load(id) : nil
            let digest = DriftCache.file(of: manifest).flatMap(DriftCache.digest)
            let current = report.map { DriftCache.isCurrent($0, manifest: manifest, digest: digest) } ?? false
            await self?.looked(manifest, available: available, report: report, current: current)
        }
    }

    private func looked(_ manifest: Manifest, available: Bool, report: DriftReport?, current: Bool) {
        let id = manifest.id
        var entry = entries[id] ?? Entry()
        guard available else {
            entry.report = nil
            entry.missingRepo = Drift.repoRoot(of: manifest).map(Self.tilde)
            set(id, entry)
            return
        }
        entry.missingRepo = nil
        if entry.report == nil { entry.report = report }
        set(id, entry)
        if !current { check(manifest) }
    }

    /// Runs a check in the background (⌘K "Check drift", the inspector's Check again, or a stale cache).
    /// `manual` announces the result with a toast.
    func check(_ manifest: Manifest, manual: Bool = false) {
        let id = manifest.id
        guard manifest.repo != nil else {
            if manual { overlays?.toast("This map has no repo: to compare with") }
            return
        }
        if manual { announce.insert(id) }
        latest[id] = latest[id] ?? manifest
        var entry = entries[id] ?? Entry()
        guard !entry.running else { rerun.insert(id); return }
        entry.running = true
        set(id, entry)
        Task.detached(priority: .utility) { [weak self] in
            let digest = DriftCache.file(of: manifest).flatMap(DriftCache.digest)
            let report = Drift.check(manifest, options: DriftOptions(manifestDigest: digest))
            if report.status == .checked { try? DriftCache.save(report) }
            await self?.finished(manifest, report)
        }
    }

    private func finished(_ manifest: Manifest, _ report: DriftReport) {
        let id = manifest.id
        var entry = entries[id] ?? Entry()
        entry.running = false
        switch report.status {
        case .checked:
            entry.report = report
            entry.missingRepo = nil
        case .repoMissing:
            entry.report = nil
            entry.missingRepo = report.repo.map(Self.tilde)
        case .noRepo:
            entry.report = nil
        }
        set(id, entry)
        revision += 1
        if announce.remove(id) != nil { overlays?.toast(Self.toast(report)) }
        if rerun.remove(id) != nil { check(latest[id] ?? manifest) }
    }

    private func set(_ id: String, _ entry: Entry) {
        entries[id] = entry
        badgeCache = badgeCache.filter { !$0.key.hasPrefix(id + "|") }
    }

    /// Node id → errors and warnings on it or inside it, for the level the session shows. Cached: the
    /// stage asks on every frame.
    func badges(for sim: Simulation) -> [String: Int] {
        let id = sim.manifest.id
        guard let report = entries[id]?.report else { return [:] }
        let key = id + "|" + sim.path.joined(separator: "/")
        if let cached = badgeCache[key] { return cached }
        let badges = report.staleNodes(level: sim.path)
        badgeCache[key] = badges
        return badges
    }

    /// Reads the observed state, so a stage repaints when a check finishes.
    func watch(_ id: String) -> Int { _ = entries[id]?.report?.checkedAt; return revision }

    static func toast(_ report: DriftReport) -> String {
        switch report.status {
        case .noRepo: return "This map has no repo: to compare with"
        case .repoMissing: return "The repo isn’t on this Mac"
        case .checked:
            let s = report.summary
            if s.errors == 0 && s.warnings == 0 { return "No drift · \(s.freshness)% fresh" }
            return "Drift: " + [s.errors > 0 ? "\(s.errors) \(s.errors == 1 ? "error" : "errors")" : nil,
                                s.warnings > 0 ? "\(s.warnings) \(s.warnings == 1 ? "warning" : "warnings")" : nil]
                .compactMap { $0 }.joined(separator: ", ") + " · \(s.freshness)% fresh"
        }
    }

    static func tilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// A prompt for the agent that maintains the map: run the check, fix each finding, check again.
    static func agentPrompt(_ manifest: Manifest, report: DriftReport) -> String {
        let s = report.summary
        return """
        Refresh the Strata map \(manifest.id) (\(DriftCache.file(of: manifest)?.path ?? "~/.strata/sims/\(manifest.id).yaml")) against \
        \(report.repo.map(tilde) ?? "its repo"). Run `strata drift \(manifest.id) --json` and fix each finding in the map: \
        \(s.errors) errors and \(s.warnings) warnings now, plus \(s.unmapped) repo items not on the map. Each finding has the map \
        location (level, node, op, step, manifest line), the repo location, and a suggested fix. Copy queries verbatim from the repo. \
        Then run `strata validate \(manifest.id)` and `strata drift \(manifest.id)` until it exits 0.
        """
    }
}

/// ⌘K: "Check drift" for a map with a repo.
@MainActor
enum SimDriftMenus {
    static let icon = "arrow.triangle.2.circlepath"

    static func palette(sim: Simulation, model: AppModel) -> [MenuItem] {
        let state = SimDriftState.of(model)
        // No repo, or a repo that isn't on this Mac: nothing to offer.
        guard sim.manifest.repo != nil, DriftCache.file(of: sim.manifest) != nil, state.entry(sim.manifest.id)?.missingRepo == nil else { return [] }
        let manifest = sim.manifest
        var items = [MenuItem("Check drift against the repo", icon: icon) { state.check(manifest, manual: true) }]
        if let report = state.report(manifest.id), !report.isClean {
            items.append(MenuItem("Copy drift fix-up prompt for an agent", icon: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(SimDriftState.agentPrompt(manifest, report: report), forType: .string)
                model.overlays.toast("Copied a prompt for your agent")
            })
        }
        return items
    }
}

/// StrataSnapshot: run a check synchronously and show it, so a PNG can show the badge and sections.
@_spi(Snapshots) public enum SimDriftSnapshot {
    @MainActor public static func check(_ model: AppModel, manifest: Manifest, repo: String? = nil) {
        let report = Drift.check(manifest, options: DriftOptions(repo: repo))
        SimDriftState.of(model).install(report, for: manifest.id)
    }
}

extension SimDriftState {
    func install(_ report: DriftReport, for id: String) {
        var entry = entries[id] ?? Entry()
        entry.report = report.status == .checked ? report : nil
        entry.missingRepo = report.status == .repoMissing ? report.repo.map(Self.tilde) : nil
        set(id, entry)
        lastLook[id] = Date()
        revision += 1
    }
}
