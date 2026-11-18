import Foundation
import StrataCore

// Assertions without XCTest (Command Line Tools only): `swift run StrataChecks [filter]`.
// Each area adds checks in its own Checks+*.swift file.

struct CheckCase { var name: String; var run: @MainActor () throws -> Void }

nonisolated(unsafe) var failures: [String] = []
nonisolated(unsafe) var currentCase = ""

func check(_ cond: @autoclosure () -> Bool, _ msg: @autoclosure () -> String, file: StaticString = #fileID, line: UInt = #line) {
    if !cond() { failures.append("\(currentCase): \(msg()) (\(file):\(line))") }
}

let filter = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
MainActor.assumeIsolated {
    let all = parserChecks() + engineChecks() + vaultChecks() + cliChecks()
    var ran = 0
    for c in all where filter.map({ c.name.contains($0) }) ?? true {
        currentCase = c.name; ran += 1
        do { try c.run() } catch { failures.append("\(c.name): threw \(error)") }
    }
    if failures.isEmpty { print("ok: \(ran) checks"); exit(0) }
    for f in failures { print("FAIL \(f)") }
    print("\(failures.count) failure(s) in \(ran) checks"); exit(1)
}
