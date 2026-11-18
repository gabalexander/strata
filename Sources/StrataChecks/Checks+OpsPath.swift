import Foundation
import StrataCore

// Deep dives into an operation's `inside:` level through a `node#op` path element (ops UI).
func opsPathChecks() -> [CheckCase] {
    [
        CheckCase(name: "ops path enters an operation's inside level") {
            let manifest = Fixtures.checkoutWithOps
            let level = manifest.level(at: ["orders#insert-order"])
            check(level?.node("backend") != nil, "orders#insert-order should open the op's inside level")
            check(manifest.level(at: ["orders#price"]) == nil, "an op without inside: has no level")
            check(manifest.level(at: ["orders#missing"]) == nil, "an unknown op has no level")
            check(manifest.level(at: ["nowhere#insert-order"]) == nil, "an unknown node has no level")
            check(manifest.level(at: ["orders"])?.node("handler") != nil, "plain node ids still follow inside:")
        },
        CheckCase(name: "ops path level simulates with a parent rate") {
            let sim = Simulation(manifest: Fixtures.checkoutWithOps, path: ["orders#insert-order"], parentRate: 8)
            sim.run(seconds: 3)
            check(sim.level.node("wal") != nil, "the simulation runs the op's level")
            check((sim.nodeState("backend")?.throughput ?? 0) > 0, "requests flow through the op's level")
        },
    ]
}
