import Foundation
import StrataCore

// `strata how <file|id> [--mechanism id] [--branch id]`: a mechanism (docs/manifest.md, How it works)
// as a numbered transcript, so an agent can check a writeup step by step: time, who talks to whom,
// the exact command and reply, and the state after each step with TTLs aged by `at`.

@MainActor
func printHow(_ args: Arguments) throws -> Int32 {
    let entry = try loadEntry(args.positional[0], command: "how")
    guard let manifest = entry.manifest else { return 1 }
    var sites = manifest.mechanisms()
    if let id = args.options["--mechanism"] {
        sites = sites.filter { $0.mechanism.id == id }
        guard !sites.isEmpty else {
            let known = manifest.mechanisms().map(\.mechanism.id)
            throw CLIError("unknown mechanism '\(id)'" + (known.isEmpty ? "; \(manifest.id) has none" : "; choose \(known.joined(separator: ", "))"))
        }
    }
    guard !sites.isEmpty else {
        print("No mechanisms in \(manifest.id). Add how: to a node or an operation (strata schema, How it works).")
        return 0
    }
    if let branch = args.options["--branch"] {
        guard let site = sites.first(where: { $0.mechanism.branch(branch) != nil }) else {
            let known = sites.flatMap { $0.mechanism.branches.map(\.id) }
            throw CLIError("unknown branch '\(branch)'" + (known.isEmpty ? "" : "; choose \(known.joined(separator: ", "))"))
        }
        sites = [site]
    }
    let sections = sites.map { site in
        HowTranscript(manifest: manifest, site: site).render(branch: args.options["--branch"])
    }
    print(sections.joined(separator: "\n\n"))
    return 0
}

struct HowTranscript {
    let manifest: Manifest
    let site: MechanismSite
    private var mechanism: Mechanism { site.mechanism }

    /// The header, then either the main sequence followed by each branch from its branch point, or the
    /// whole path of one branch.
    func render(branch: String?) -> String {
        var lines = header()
        if let branch, let playback = mechanism.play(branch: branch) {
            let start = playback.branchStart ?? 0
            let after = mechanism.branch(branch)?.after.map { " after \($0)" } ?? " from the start"
            lines.append("")
            lines.append("branch \(branch): \(mechanism.branch(branch)?.label ?? branch) (\(start) main step\(start == 1 ? "" : "s")\(after))")
            lines += steps(playback, from: 0)
        } else if let main = mechanism.play() {
            lines.append("")
            lines.append("main sequence")
            lines += steps(main, from: 0)
            for item in mechanism.branches {
                guard let playback = mechanism.play(branch: item.id) else { continue }
                let start = playback.branchStart ?? 0
                lines.append("")
                let point = item.after.map { "after step \(start) \($0)" } ?? "from the start"
                lines.append("branch \(item.id): \(item.label) (\(point))")
                if let note = item.note { lines.append("  " + flat(note)) }
                lines += steps(playback, from: start)
            }
        }
        return lines.joined(separator: "\n")
    }

    private func header() -> [String] {
        let place = ([manifest.id] + site.path).joined(separator: " › ")
        var lines = ["\(place) › \(site.owner) · \(mechanism.id): \(mechanism.title)"]
        if let summary = mechanism.summary { lines.append("  " + flat(summary)) }
        let cast = mechanism.participants.map { p in
            "\(p.id) = \(p.label)" + (p.node.map { " (\($0))" } ?? p.kind.map { " (\($0.rawValue))" } ?? "")
        }
        lines.append("  participants: " + cast.joined(separator: ", "))
        if let playback = mechanism.play(), !playback.initial.isEmpty {
            lines.append("  initial state: " + playback.initial.map { describe($0, change: nil) }.joined(separator: "; "))
        }
        if !mechanism.code.isEmpty { lines.append("  code: " + mechanism.code.joined(separator: ", ")) }
        return lines
    }

    /// Steps `from...` of a playback, numbered from 1 across the whole path.
    private func steps(_ playback: MechPlayback, from start: Int) -> [String] {
        let frames = Array(playback.frames.dropFirst(start))
        let numbers = frames.map { String($0.index + 1) }
        let times = frames.map { playback.timed ? "t=" + Self.time($0.time) : "" }
        let moves = frames.map { frame in "\(name(frame.step.from)) → \(name(frame.step.to))" }
        let numberWidth = numbers.map(\.count).max() ?? 1
        let timeWidth = times.map(\.count).max() ?? 0
        let moveWidth = moves.map(\.count).max() ?? 0
        let indent = String(repeating: " ", count: 2 + numberWidth + 2)
        var lines: [String] = []
        for (offset, frame) in frames.enumerated() {
            let number = String(repeating: " ", count: numberWidth - numbers[offset].count) + numbers[offset]
            let time = timeWidth == 0 ? "" : times[offset].padding(toLength: timeWidth, withPad: " ", startingAt: 0) + "  "
            let move = moves[offset].padding(toLength: moveWidth, withPad: " ", startingAt: 0)
            lines.append("  \(number)  \(time)\(move)  \(frame.step.label)")
            if let command = frame.step.command {
                lines.append(indent + command + (frame.step.reply.map { "  →  \($0)" } ?? ""))
            } else if let reply = frame.step.reply {
                lines.append(indent + "→  " + reply)
            }
            lines.append(indent + "state: " + state(frame))
            if let note = frame.step.note { lines.append(indent + "note: " + flat(note)) }
            if !frame.step.code.isEmpty { lines.append(indent + "code: " + frame.step.code.joined(separator: ", ")) }
        }
        return lines
    }

    /// Every key after the step; the ones it changed say how, and removed keys are listed last.
    private func state(_ frame: MechFrame) -> String {
        var parts = frame.state.map { describe($0, change: frame.change(of: $0.key)) }
        for change in frame.changes where !frame.state.contains(where: { $0.key == change.key }) {
            parts.append("\(change.key) \(change.kind == .expire ? "expired" : "deleted")")
        }
        return parts.isEmpty ? "(empty)" : parts.joined(separator: "; ")
    }

    private func describe(_ key: MechKey, change: MechChange.Kind?) -> String {
        var notes: [String] = []
        if let ttl = key.ttl { notes.append("ttl " + Self.time(ttl)) }
        switch change {
        case .set?: notes.append("set")
        case .renew?: notes.append("renewed")
        default: break
        }
        return "\(key.key) = \(key.value)" + (notes.isEmpty ? "" : " (\(notes.joined(separator: ", ")))")
    }

    private func name(_ participant: String) -> String {
        mechanism.participants.first { $0.id == participant }?.label ?? participant
    }

    private func flat(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }

    static func time(_ seconds: Double) -> String {
        if seconds == 0 { return "0s" }
        func trimmed(_ value: Double) -> String { Value.number((value * 1000).rounded() / 1000).description }
        return seconds < 1 ? trimmed(seconds * 1000) + "ms" : trimmed(seconds) + "s"
    }
}
