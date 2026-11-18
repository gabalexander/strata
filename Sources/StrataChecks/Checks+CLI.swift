import Foundation

@MainActor func cliChecks() -> [CheckCase] {
    [
        CheckCase(name: "cli symlink uses installed schema and examples from another directory") {
            try withCLIDirectory { root in
                let resources = root.appendingPathComponent("Strata.app/Contents/Resources")
                let cli = resources.appendingPathComponent("bin/strata")
                let link = root.appendingPathComponent("local/bin/strata")
                let docs = resources.appendingPathComponent("Docs")
                let examples = resources.appendingPathComponent("Examples")
                let cwd = root.appendingPathComponent("elsewhere")
                let fm = FileManager.default
                for directory in [cli.deletingLastPathComponent(), link.deletingLastPathComponent(), docs, examples, cwd] {
                    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                }
                try fm.copyItem(at: builtCLI, to: cli)
                try fm.createSymbolicLink(at: link, withDestinationURL: cli)

                let marker = "Schema from the installed resources\n"
                try Data(marker.utf8).write(to: docs.appendingPathComponent("manifest.md"))
                let example = examples.appendingPathComponent("installed-probe.yaml")
                try Data("strata: 1\nid: installed-probe\ntitle: Installed example\nnodes: []\n".utf8).write(to: example)

                let schema = try invokeCLI(link, ["schema"], cwd: cwd)
                check(schema.status == 0 && schema.output == marker, "schema did not read the bundled file")
                let list = try invokeCLI(link, ["list", "--json"], cwd: cwd)
                check(list.status == 0, "list failed: \(list.output)")
                let entries = try JSONSerialization.jsonObject(with: Data(list.output.utf8)) as? [[String: Any]]
                check(entries?.count == 1 && entries?.first?["id"] as? String == "installed-probe" &&
                      entries?.first?["source"] as? String == example.path,
                      "list did not read the staged Examples directory: \(list.output)")
            }
        },
        CheckCase(name: "cli simulate exits for a zero-time cycle or a rate above the limit") {
            try withCLIDirectory { root in
                let cycle = root.appendingPathComponent("cycle.yaml")
                let manifest = """
                    strata: 1
                    id: cycle
                    title: Zero-time cycle
                    nodes:
                      - { id: client, kind: client }
                      - { id: queue, kind: queue, latency: fixed 0ms }
                      - { id: worker, kind: worker, latency: fixed 0ms }
                    edges:
                      - { from: client, to: queue, latency: fixed 1ms }
                      - { from: queue, to: worker, latency: fixed 0ms }
                      - { from: worker, to: queue, latency: fixed 0ms }
                    flows:
                      - { id: initial, from: client, rate: manual, steps: [{ publish: queue }] }
                      - { id: loop, on: queue, by: worker, steps: [{ publish: queue }] }
                    scenarios: [{ id: seed, setup: [send initial] }]
                    """
                try Data(manifest.utf8).write(to: cycle)
                let loop = try invokeCLI(builtCLI, ["simulate", cycle.path, "--scenario", "seed", "--seconds", "0.01"], cwd: root)
                check(loop.status == 1 && loop.output.contains("zero-time publish cycle") &&
                      loop.output.contains("Paused: zero-time loop"), "simulate did not report and exit from the cycle: \(loop.output)")

                let rate = root.appendingPathComponent("high-rate.yaml")
                try Data(manifest.replacingOccurrences(of: "rate: manual", with: "rate: 1000000000000/s").utf8).write(to: rate)
                let excessive = try invokeCLI(builtCLI, ["simulate", rate.path, "--seconds", "0.01"], cwd: root)
                check(excessive.status == 1 && excessive.output.contains("a flow rate cannot exceed 10000/s"),
                      "simulate did not reject the excessive rate: \(excessive.output)")
            }
        },
    ]
}

private var builtCLI: URL {
    URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().appendingPathComponent("strata")
}

private func withCLIDirectory(_ body: (URL) throws -> Void) throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try body(root)
}

private func invokeCLI(_ executable: URL, _ args: [String], cwd: URL) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = executable
    process.arguments = args
    process.currentDirectoryURL = cwd
    var environment = ProcessInfo.processInfo.environment
    environment.removeValue(forKey: "STRATA_RESOURCES")
    environment["STRATA_HOME"] = cwd.appendingPathComponent("home").path
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let watchdog = DispatchWorkItem {
        if process.isRunning { process.terminate() }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)
    defer { watchdog.cancel() }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationReason == .exit ? process.terminationStatus : -1, String(decoding: data, as: UTF8.self))
}
