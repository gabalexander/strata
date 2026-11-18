import SwiftUI
import StrataCore

@MainActor
struct SimParameters: View {
    private struct Parameter: Identifiable {
        let id: String
        let title: String
        var input: Input

        enum Input {
            case number(step: Double, minimum: Double, maximum: Double?)
            case choices([Value])
        }

        init(_ id: String, _ title: String, step: Double = 1, minimum: Double = 0, maximum: Double? = nil) {
            self.id = id; self.title = title; input = .number(step: step, minimum: minimum, maximum: maximum)
        }

        init(_ id: String, _ title: String, options: [Value]) {
            self.id = id; self.title = title; input = .choices(options)
        }
    }

    let node: Node
    let sim: Simulation
    let model: AppModel

    private var parameters: [Parameter] {
        var fields: [Parameter] = []
        if node.kind.role == .server {
            fields += [
                Parameter("replicas", "Replicas", minimum: 1),
                Parameter("concurrency", "Concurrency", minimum: 1),
                Parameter("latency", "Latency", step: 0.001),
                Parameter("queue", "Queue limit"),
                Parameter("errors", "Errors", step: 0.01, maximum: 1),
                Parameter("timeout", "Timeout", step: 0.05),
                Parameter("retries", "Retries"),
                Parameter("backoff", "Backoff", step: 0.01),
                Parameter("async", "Async", options: [.bool(false), .bool(true)]),
            ]
        }
        if node.kind.role == .buffer {
            fields += [
                Parameter("capacity", "Capacity", minimum: 1),
                Parameter("overflow", "Overflow", options: Overflow.allCases.map { .string($0.rawValue) }),
                Parameter("ttl", "TTL", step: 1),
            ]
        }
        if node.kind.role == .buffer || sim.level.flows.contains(where: { $0.by == node.id }) {
            let deadLetters = sim.level.nodes.filter { $0.kind.role == .buffer && $0.id != node.id }.map { Value.string($0.id) }
            if !deadLetters.isEmpty {
                fields.append(Parameter("dlq", "Dead letters", options: [.string("")] + deadLetters))
            }
        }
        let consumerBuffers = sim.level.flows.filter { $0.by == node.id }.compactMap { $0.on }.compactMap(sim.level.node)
        if consumerBuffers.contains(where: { $0.kind == .queue }) {
            fields += [
                Parameter("prefetch", "Prefetch", minimum: 1),
                Parameter("ack", "Ack", options: AckMode.allCases.map { .string($0.rawValue) }),
                Parameter("maxDeliveries", "Max deliveries", minimum: 1),
            ]
        }
        if !consumerBuffers.isEmpty {
            let queue = consumerBuffers.contains { $0.kind == .queue }
            let topic = consumerBuffers.contains { $0.kind == .topic }
            let choices: [OnError] = (queue ? [.requeue, .drop] : []) + (topic ? [.retry, .skip] : []) + [.dlq]
            fields.append(Parameter("onError", "On error", options: choices.map { .string($0.rawValue) }))
        }
        if node.kind == .cache { fields.append(Parameter("hitRate", "Hit rate", step: 0.01, maximum: 1)) }
        return fields
    }

    var body: some View {
        let parameters = parameters
        if !parameters.isEmpty {
            SimSection(title: "Parameters") {
                VStack(spacing: 0) {
                    ForEach(parameters) { field in
                        if field.id != parameters.first?.id { Rectangle().fill(Theme.border).frame(height: 1) }
                        row(field)
                    }
                }
                .padding(.horizontal, 8)
                .card()
            }
        }
    }

    private func row(_ parameter: Parameter) -> some View {
        let key = StrataCore.Binding(.node(node.id), parameter.id)
        let current = sim.value(key)
        return HStack(spacing: 6) {
            Text(parameter.title).font(Theme.ui(12)).foregroundStyle(Theme.muted)
            Spacer(minLength: 0)
            switch parameter.input {
            case .number(let step, let minimum, let maximum):
                let n = current?.number ?? minimum
                SimButton(title: "Decrease \(parameter.title)", icon: "minus", iconOnly: true) {
                    sim.setValue(.number(max(minimum, n - step)), for: key)
                }
                .disabled(n <= minimum).opacity(n <= minimum ? 0.42 : 1)
                Text(current.map { SimFormat.value($0, param: parameter.id) } ?? "—")
                    .font(Theme.mono(11)).foregroundStyle(Theme.text)
                    .lineLimit(1).frame(minWidth: 52)
                SimButton(title: "Increase \(parameter.title)", icon: "plus", iconOnly: true) {
                    sim.setValue(.number(min(maximum ?? .infinity, n + step)), for: key)
                }
                .disabled(maximum.map { n >= $0 } ?? false)
            case .choices(let options):
                SimValuePicker(model: model, options: options, value: current, label: { value in
                    value == .string("") ? "None" : value.description
                }) {
                    sim.setValue($0, for: key)
                }
            }
        }
        .padding(.vertical, 5)
    }
}

@MainActor
struct SimValuePicker: View {
    let model: AppModel
    let options: [Value]
    let value: Value?
    let label: (Value) -> String
    let select: (Value) -> Void

    var body: some View {
        SimButton(title: value.map(label) ?? "Choose", icon: "chevron.down") { show(at: anchor) }
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { anchor = $0 }
    }

    @State private var anchor = CGRect.zero

    private func show(at rect: CGRect) {
        model.overlays.showMenu(options.map { option in
            MenuItem(label(option), checked: option == value) { select(option) }
        }, at: CGPoint(x: rect.minX, y: rect.maxY + 3))
    }
}
