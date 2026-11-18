import Foundation
import StrataCore

// `strata analyze <file|id> [--rates flow=50/s,...] [--json]`: the Pressure analysis of a manifest's
// root level: capacity per node, flows with their daily volumes and max rates, what to scale,
// pressure on each database and cache, and the blast radius of the top bottleneck.

@MainActor
func analyze(_ args: Arguments) throws -> Int32 {
    let entry = try loadEntry(args.positional[0], command: "analyze")
    guard let manifest = entry.manifest else { return 1 }
    let level = manifest.root
    let rates = try parseRates(args.options["--rates"], level: level)
    let report = Analysis.capacity(of: level, rates: rates)
    let top = report.scalePlan.first?.node
        ?? report.nodes.first { $0.slots != nil && $0.utilization > 0 }?.node
    let radius = top.map { Analysis.blastRadius(of: $0, in: level) }
    if args.flags.contains("--json") {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let listing = AnalysisListing(manifest: manifest.id, report: report, blastRadius: radius)
        print(String(decoding: try encoder.encode(listing), as: UTF8.self))
    } else {
        print(analysisText(manifest, report: report, radius: radius, custom: !rates.isEmpty))
    }
    return 0
}

/// `place-order=50/s,email=600/min`: a number per second, or with `/s` or `/min`.
private func parseRates(_ text: String?, level: Level) throws -> [String: Double] {
    guard let text else { return [:] }
    var rates: [String: Double] = [:]
    for item in text.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !item.isEmpty {
        let parts = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { throw CLIError("--rates takes flow=rate pairs, such as place-order=50/s") }
        guard level.flow(parts[0]) != nil else { throw CLIError("unknown flow '\(parts[0])' in --rates") }
        var number = parts[1], divisor = 1.0
        if number.hasSuffix("/min") { number.removeLast(4); divisor = 60 }
        else if number.hasSuffix("/s") { number.removeLast(2) }
        guard let value = Double(number), value.isFinite, value >= 0 else {
            throw CLIError("invalid rate '\(parts[1])' for \(parts[0]); use 50/s, 600/min or 50")
        }
        rates[parts[0]] = value / divisor
    }
    return rates
}

private func analysisText(_ manifest: Manifest, report: CapacityReport, radius: BlastRadius?, custom: Bool) -> String {
    let level = manifest.root
    func label(_ id: String) -> String { level.node(id)?.label ?? id }
    let peak = level.flows.contains { $0.traffic?.peak != nil }
    var sections = ["\(manifest.id): \(manifest.title), root level, at \(custom ? "the given" : "the configured") rates"]

    let bottlenecks = Dictionary(grouping: report.flows.compactMap { flow in flow.bottleneck.map { ($0, flow.flow) } }, by: \.0)
        .mapValues { $0.map(\.1).joined(separator: ", ") }
    var nodes = [["node", "kind", "slots", "hold ms", "calls/s", "demand", "util", "bottleneck of"]]
    for node in report.nodes where node.arrivals > 0 || node.slots != nil {
        nodes.append([node.node, level.node(node.node)?.kind.rawValue ?? "", node.slots.map(String.init) ?? "–",
                      fixed(node.holdTime * 1000, 1), fixed(node.arrivals, 2), fixed(node.demand, 2),
                      node.slots == nil ? "–" : percent(node.utilization), bottlenecks[node.node] ?? ""])
    }
    sections.append("Capacity (demand = busy slots on average; util above 100% is load the node can't take)\n" + table(nodes))

    var flows = [["flow", "rate/s", "per day", "max/s", "bottleneck", "latency"]]
    for flow in report.flows {
        var shown = fixed(flow.rate, 2)
        if let offered = flow.offered, offered > flow.rate * (1 + 1e-6) { shown += " of \(fixed(offered, 2))" }
        let daily = count(flow.daily) + (flow.declared?.daily != nil ? " (declared)" : "")
        let limit = flow.maxRate.map(solvedRate) ?? "∞"
        flows.append([flow.flow, shown, daily, limit, flow.bottleneck ?? "–",
                      flow.latency.map { fixed($0 * 1000, 0) + " ms" } ?? "–"])
    }
    sections.append("Flows\n" + table(flows))

    var plan = ["Scale plan (\(peak ? "at traffic.peak where declared" : "at the analysed rates"))"]
    if report.scalePlan.isEmpty { plan.append("Nothing saturates within 100× these rates.") }
    for (number, step) in report.scalePlan.enumerated() {
        plan.append("\(number + 1). \(step.node) → \(step.replicas) replicas: \(step.reason)")
    }
    sections.append(plan.joined(separator: "\n"))

    let stores = report.pressure.keys.filter { id in
        guard let kind = level.node(id)?.kind else { return false }
        return [.database, .cache, .search].contains(kind)
    }.sorted { a, b in
        let x = report.nodes.first { $0.node == a }?.demand ?? 0, y = report.nodes.first { $0.node == b }?.demand ?? 0
        return x != y ? x > y : a < b
    }
    var pressure = ["Pressure on databases and caches"]
    if stores.isEmpty { pressure.append("No database or cache takes load at these rates.") }
    for id in stores {
        guard let node = report.nodes.first(where: { $0.node == id }), let sources = report.pressure[id] else { continue }
        pressure.append("\(id) (\(label(id))): \(fixed(node.demand, 2)) of \(node.slots.map(String.init) ?? "∞") slots busy, \(fixed(node.arrivals, 2)) calls/s")
        var rows = [["share", "calls/s", "per day", "from", "op", "flow", "access", "tables"]]
        for source in sources.prefix(5) {
            rows.append([percent(source.busyShare), fixed(source.rate, 2), count(source.daily), source.node, source.op ?? "–",
                         source.flow, source.access?.rawValue ?? "–", source.tables.joined(separator: ", ")])
        }
        pressure.append(table(rows).split(separator: "\n").map { "  " + $0 }.joined(separator: "\n"))
    }
    sections.append(pressure.joined(separator: "\n"))

    if let radius {
        func list(_ items: [String]) -> String { items.isEmpty ? "none" : items.joined(separator: ", ") }
        sections.append("""
            Blast radius of \(radius.node) (\(label(radius.node))), the top bottleneck
              upstream: \(list(radius.upstream))
              absorbers: \(list(radius.absorbers))
              lagging: \(list(radius.lagging))
              flows: \(list(radius.flows))
              edges: \(list(radius.edges))
            """)
    }
    if !report.notes.isEmpty { sections.append("Notes\n" + report.notes.map { "- " + $0 }.joined(separator: "\n")) }
    return sections.joined(separator: "\n\n")
}

private func table(_ rows: [[String]]) -> String {
    let widths = rows[0].indices.map { column in rows.map { $0[column].count }.max() ?? 0 }
    return rows.map { row in
        row.enumerated().map { index, cell in
            let padding = String(repeating: " ", count: widths[index] - cell.count)
            let numeric = cell == "–" || cell == "∞" || Double(cell.prefix { $0.isNumber || $0 == "." }) != nil
            let left = index == row.count - 1 || !numeric
            return left ? cell + padding : padding + cell
        }.joined(separator: "  ").trimmingCharacters(in: .whitespaces)
    }.joined(separator: "\n")
}

private func fixed(_ value: Double, _ digits: Int) -> String {
    value.isFinite ? String(format: "%.\(digits)f", value) : "∞"
}

/// A solved rate: one decimal below 1,000/s, four significant digits above.
private func solvedRate(_ value: Double) -> String {
    guard value.isFinite else { return "∞" }
    guard value >= 1000 else { return fixed(value, 1) }
    let unit = pow(10, floor(log10(value)) - 3)
    return count((value / unit).rounded() * unit)
}

private func percent(_ fraction: Double) -> String {
    fraction.isFinite ? String(format: "%.0f%%", fraction * 100) : "∞"
}

private func count(_ value: Double) -> String {
    guard value.isFinite else { return "∞" }
    let digits = String(Int(value.rounded()))
    var result = ""
    for (offset, character) in digits.reversed().enumerated() {
        if offset > 0, offset % 3 == 0 { result.append(",") }
        result.append(character)
    }
    return String(result.reversed())
}

/// The analysis as `strata analyze --json` prints it. Seconds and per-second rates throughout.
private struct AnalysisListing: Encodable {
    struct Node: Encodable {
        let node: String
        let slots: Int?
        let holdTime: Double
        let demand: Double
        let utilization: Double
        let arrivals: Double
        let queueWait: Double
        let visits: [String: Double]
    }
    struct Flow: Encodable {
        let flow: String
        let rate: Double
        let offered: Double?
        let daily: Double
        let maxRate: Double?
        let bottleneck: String?
        let latency: Double?
        let peak: Double?
        let declaredDaily: Double?
        let sloP50: Double?
        let sloP99: Double?
        let sloErrors: Double?
    }
    struct Step: Encodable {
        let node: String
        let replicas: Int
        let utilization: Double
        let newUtilization: Double
        let flow: String?
        let newMaxRate: Double?
        let nextBottleneck: String?
        let reason: String
    }
    struct Load: Encodable {
        let node: String
        let op: String?
        let flow: String
        let tables: [String]
        let access: String?
        let rate: Double
        let daily: Double
        let busyShare: Double
    }
    struct Radius: Encodable {
        let node: String
        let upstream: [String]
        let edges: [String]
        let absorbers: [String]
        let lagging: [String]
        let flows: [String]
    }

    let manifest: String
    let nodes: [Node]
    let flows: [Flow]
    let scalePlan: [Step]
    let pressure: [String: [Load]]
    let notes: [String]
    let blastRadius: Radius?

    init(manifest: String, report: CapacityReport, blastRadius radius: BlastRadius?) {
        self.manifest = manifest
        nodes = report.nodes.map {
            Node(node: $0.node, slots: $0.slots, holdTime: $0.holdTime, demand: $0.demand, utilization: $0.utilization,
                 arrivals: $0.arrivals, queueWait: $0.queueWait, visits: $0.visits)
        }
        flows = report.flows.map {
            Flow(flow: $0.flow, rate: $0.rate, offered: $0.offered, daily: $0.daily, maxRate: $0.maxRate, bottleneck: $0.bottleneck,
                 latency: $0.latency, peak: $0.declared?.peak, declaredDaily: $0.declared?.daily,
                 sloP50: $0.slo?.p50, sloP99: $0.slo?.p99, sloErrors: $0.slo?.errors)
        }
        scalePlan = report.scalePlan.map {
            Step(node: $0.node, replicas: $0.replicas, utilization: $0.utilization, newUtilization: $0.newUtilization,
                 flow: $0.flow, newMaxRate: $0.newMaxRate, nextBottleneck: $0.nextBottleneck, reason: $0.reason)
        }
        pressure = report.pressure.mapValues { loads in
            loads.map { Load(node: $0.node, op: $0.op, flow: $0.flow, tables: $0.tables, access: $0.access?.rawValue,
                             rate: $0.rate, daily: $0.daily, busyShare: $0.busyShare) }
        }
        notes = report.notes
        blastRadius = radius.map {
            Radius(node: $0.node, upstream: $0.upstream, edges: $0.edges, absorbers: $0.absorbers, lagging: $0.lagging, flows: $0.flows)
        }
    }
}
