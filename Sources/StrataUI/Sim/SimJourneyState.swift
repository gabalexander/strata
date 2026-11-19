import AppKit
import Foundation
import Observation
import SwiftUI
import StrataCore

// The journey player (docs/manifest.md, Journeys): one open journey per window, for one map. It is kept
// on the app model, not the session, so it stays open while a deep-dive step dives into a node and comes
// back out. Stepping is discrete: each step lands at once (a click, a key, the timer while playing),
// and nothing is laid out per frame.

@MainActor
@Observable
final class SimJourneyState {
    private(set) var player: SimJourneyPlayer?
    /// A How it works mechanism a step asked for on another level: it opens when that level appears.
    @ObservationIgnored var pendingHow: (manifest: String, path: [String], node: String, op: String?, mechanism: String)?

    private init() {}

    private static let stores = NSMapTable<AppModel, SimJourneyState>.weakToStrongObjects()

    static func of(_ model: AppModel) -> SimJourneyState {
        if let store = stores.object(forKey: model) { return store }
        let store = SimJourneyState()
        stores.setObject(store, forKey: model)
        return store
    }

    /// The player open on this map, if any.
    func player(for manifest: String) -> SimJourneyPlayer? {
        player?.manifestID == manifest ? player : nil
    }

    /// Opens a journey at the start (or at `step`, from 0), paused unless `autoplay`.
    func open(_ journey: Journey, in manifest: Manifest, step: Int = -1, autoplay: Bool = false) {
        player?.pause()
        let next = SimJourneyPlayer(journey: journey, manifest: manifest)
        next.go(to: step)
        player = next
        if autoplay { next.play() }
    }

    func close() {
        player?.pause()
        player = nil
    }

    /// Space plays or pauses, ← and → step, Home and End jump, Esc closes. False when the journey of
    /// another map is open, or the key isn't one of these.
    func key(_ event: NSEvent, manifest: String) -> Bool {
        guard let player = player(for: manifest) else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard flags.isEmpty else { return false }
        switch event.keyCode {
        case 53: if !event.isARepeat { close() }
        case 49: if !event.isARepeat { player.toggle() }
        case 123: player.step(-1)
        case 124: player.step(1)
        case 115: player.go(to: -1)
        case 119: player.go(to: player.count - 1)
        default: return false
        }
        return true
    }
}

@MainActor
@Observable
final class SimJourneyPlayer {
    let manifestID: String
    let journey: Journey
    let playback: JourneyPlayback
    /// The step on screen, from 0; -1 is the start, before the first step.
    private(set) var shown = -1
    private(set) var playing = false
    /// Rows whose card lists every column, not only the ones the journey touches.
    var expanded: Set<JourneyRowID> = []
    /// The narrow layout's choice between the step and the rows.
    var narrowRows = false
    @ObservationIgnored private var timer: Task<Void, Never>?

    /// How long playback stays on a step before the next.
    static let dwell = Duration.milliseconds(2600)

    init(journey: Journey, manifest: Manifest) {
        self.journey = journey
        manifestID = manifest.id
        playback = manifest.replay(journey)
    }

    var count: Int { playback.frames.count }
    var frame: JourneyFrame? { playback.frames.indices.contains(shown) ? playback.frames[shown] : nil }
    var atEnd: Bool { shown >= count - 1 }

    func go(to index: Int) {
        let clamped = min(count - 1, max(-1, index))
        if clamped != shown { shown = clamped }
    }

    /// To the next or previous step, paused there.
    func step(_ direction: Int) {
        pause()
        go(to: shown + direction)
    }

    /// A click on a step or a status chip: there at once, paused.
    func jump(to index: Int) {
        pause()
        go(to: index)
    }

    func play() {
        guard !playing else { return }
        if atEnd { go(to: -1) }
        playing = true
        timer = Task { @MainActor [weak self] in
            // The first step lands at once; each later one after the dwell.
            if let self, self.shown < 0 { self.go(to: 0) }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.dwell)
                guard let self, !Task.isCancelled, self.playing else { return }
                if self.atEnd { self.pause(); return }
                self.go(to: self.shown + 1)
                if self.atEnd { self.pause(); return }
            }
        }
    }

    func pause() {
        timer?.cancel()
        timer = nil
        if playing { playing = false }
    }

    func toggle() { playing ? pause() : play() }
}

/// Offscreen snapshots: open a journey at a step.
@_spi(Snapshots) @MainActor
public enum SimJourneySnapshot {
    /// Opens `journey` of the manifest paused at `step`: a step id, or its 1-based number (0: the start).
    public static func open(_ model: AppModel, manifest: Manifest, journey id: String, step: String) {
        guard let journey = manifest.journey(id) else { return }
        let number = Int(step) ?? (journey.steps.firstIndex { $0.id == step }.map { $0 + 1 } ?? 0)
        SimJourneyState.of(model).open(journey, in: manifest, step: number - 1)
    }

    /// Shows the narrow layout's rows instead of the step.
    public static func showRows(_ model: AppModel) {
        SimJourneyState.of(model).player?.narrowRows = true
    }

    /// Expands every row card to all of its columns.
    public static func expandRows(_ model: AppModel) {
        guard let player = SimJourneyState.of(model).player else { return }
        player.expanded = Set(player.playback.initial.map(\.id))
    }
}
