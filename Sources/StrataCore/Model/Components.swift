import Foundation

extension Node {
    /// Kinds that run code a team builds and deploys: the processes a service card lists as chips.
    public static let componentKinds: Set<NodeKind> = [.service, .worker, .cron, .function]

    /// The processes inside this node's `inside:` level (binaries, workers, schedulers, functions), in
    /// declaration order. Ports, notes, stores and buffers are left out. Empty without `inside:`.
    public var components: [Node] {
        inside?.nodes.filter { Self.componentKinds.contains($0.kind) } ?? []
    }
}
