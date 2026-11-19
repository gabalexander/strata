import SwiftUI
import StrataCore

// Where journeys are found: the inspector's overview (nothing selected) lists the map's journeys with a
// Follow button, and ⌘K has "Follow …" for each.

@MainActor
struct SimJourneySection: View {
    let model: AppModel
    let sim: Simulation

    var body: some View {
        let journeys = sim.manifest.journeys
        if !journeys.isEmpty {
            SimSection(title: "Journeys") {
                VStack(spacing: 0) {
                    ForEach(Array(journeys.enumerated()), id: \.offset) { index, journey in
                        if index > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                        row(journey)
                    }
                }
                .card()
            }
        }
    }

    private func row(_ journey: Journey) -> some View {
        let open = SimJourneyState.of(model).player(for: sim.manifest.id)?.journey.id == journey.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: SimJourneyMenus.icon)
                    .font(Theme.ui(10, .semibold)).foregroundStyle(Theme.accent)
                    .frame(width: 20, height: 20)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                Text(journey.title).font(Theme.ui(12, .medium)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            }
            if let brief = journey.brief {
                Text(brief).font(Theme.ui(11)).foregroundStyle(Theme.muted).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Text("\(journey.steps.count) steps · \(journey.entity.label ?? journey.entity.table) \(journey.entity.key?.description ?? "")")
                    .font(Theme.mono(10.5)).foregroundStyle(Theme.faint).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                SimButton(title: open ? "Following" : "Follow", icon: open ? "checkmark" : "play.fill", active: true,
                          hint: open ? "Playing in the dock's place; Esc closes it" : "Step through it on the map, in the dock's place") {
                    SimJourneyMenus.follow(journey, sim: sim, model: model)
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }
}

@MainActor
enum SimJourneyMenus {
    static let icon = "point.topleft.down.to.point.bottomright.curvepath"

    /// "Follow …" for each journey of the map, for ⌘K.
    static func palette(sim: Simulation, model: AppModel) -> [MenuItem] {
        sim.manifest.journeys.map { journey in
            MenuItem("Follow \(journey.title)", icon: icon) { follow(journey, sim: sim, model: model) }
        }
    }

    /// Opens the journey at its start over the root level's stage, the dock giving way to it.
    static func follow(_ journey: Journey, sim: Simulation, model: AppModel) {
        model.overlays.dismissMenu()
        SimHowState.of(sim).close()
        SimJourneyState.of(model).open(journey, in: sim.manifest)
    }
}
