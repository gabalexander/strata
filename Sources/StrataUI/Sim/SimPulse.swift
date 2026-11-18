import Observation
import SwiftUI
import StrataCore

/// The beat for live numbers outside the stage. The stage's frame clock beats it four times a second
/// while the simulation plays and the stage is on screen, so panels never refresh while paused or hidden.
/// Selection, tabs and control values never wait for it: they are observed state and update on the
/// frame they change.
@MainActor
@Observable
final class SimPulse {
    static let interval: TimeInterval = 0.25

    private(set) var beat = 0

    func advance() { beat &+= 1 }
}

/// A leaf that shows live simulation numbers. Its content re-evaluates on every pulse and on every
/// discrete change (`revision`: a command, a parameter, a log entry, a scenario step, a step while
/// paused), and nothing else around it does.
@MainActor
struct SimLive<Content: View>: View {
    let sim: Simulation
    let pulse: SimPulse?
    @ViewBuilder var content: () -> Content

    var body: some View {
        let _ = (pulse?.beat, sim.revision)
        content()
    }
}
