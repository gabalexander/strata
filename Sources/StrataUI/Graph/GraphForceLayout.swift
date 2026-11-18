import Foundation

struct ForceLayout {
    private struct Cell: Hashable {
        let x: Int
        let y: Int
    }

    let graph: GraphData
    var positions: [CGPoint]
    private var velocities: [CGPoint]
    private var temperature: CGFloat = 1

    init(graph: GraphData) {
        self.graph = graph
        // A deterministic spiral makes snapshots repeatable and keeps new points apart.
        positions = graph.nodes.indices.map { i in
            if graph.nodes.count == 1 { return .zero }
            let angle = CGFloat(i) * 2.39996323
            let radius = 50 * sqrt(CGFloat(i) + 0.5)
            return CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
        }
        velocities = Array(repeating: .zero, count: positions.count)
    }

    mutating func reheat() {
        temperature = 1
        velocities = Array(repeating: .zero, count: positions.count)
    }

    /// Repulsion is local to a 3×3 neighbourhood. Springs are evaluated once per edge.
    @discardableResult
    mutating func advance(pinning pinned: Int? = nil) -> Bool {
        guard positions.count > 1, temperature > 0.045 else { return false }
        let cutoff: CGFloat = 195
        let cellAt = positions.map { Cell(x: Int(floor($0.x / cutoff)), y: Int(floor($0.y / cutoff))) }
        var cells: [Cell: [Int]] = [:]
        for index in cellAt.indices { cells[cellAt[index], default: []].append(index) }

        var force = positions.map { CGPoint(x: -$0.x * 0.008, y: -$0.y * 0.008) }
        for i in positions.indices {
            let cell = cellAt[i]
            for y in (cell.y - 1)...(cell.y + 1) {
                for x in (cell.x - 1)...(cell.x + 1) {
                    guard let candidates = cells[Cell(x: x, y: y)] else { continue }
                    for j in candidates where j > i {
                        var dx = positions[i].x - positions[j].x
                        let dy = positions[i].y - positions[j].y
                        if dx == 0 && dy == 0 { dx = 1 }
                        let distanceSquared = dx * dx + dy * dy
                        guard distanceSquared < cutoff * cutoff else { continue }
                        let distance = sqrt(distanceSquared)
                        let strength = 630 / (distanceSquared + 120) * (1 - distance / cutoff)
                        force[i].x += dx * strength
                        force[i].y += dy * strength
                        force[j].x -= dx * strength
                        force[j].y -= dy * strength
                    }
                }
            }
        }

        for edge in graph.edges {
            let dx = positions[edge.b].x - positions[edge.a].x
            let dy = positions[edge.b].y - positions[edge.a].y
            let distance = max(1, hypot(dx, dy))
            let strength = (distance - 127) / distance * 0.049
            force[edge.a].x += dx * strength
            force[edge.a].y += dy * strength
            force[edge.b].x -= dx * strength
            force[edge.b].y -= dy * strength
        }

        var movement: CGFloat = 0
        for i in positions.indices where i != pinned {
            var dx = (velocities[i].x + force[i].x) * 0.68
            var dy = (velocities[i].y + force[i].y) * 0.68
            let speed = hypot(dx, dy)
            let limit = 15 * temperature
            if speed > limit {
                dx *= limit / speed
                dy *= limit / speed
            }
            velocities[i] = CGPoint(x: dx, y: dy)
            positions[i].x += dx
            positions[i].y += dy
            movement = max(movement, abs(dx), abs(dy))
        }
        temperature *= 0.963
        if movement < 0.13 { temperature = 0 }
        return true
    }
}

struct GraphViewport {
    var scale: CGFloat = 1
    var offset = CGSize.zero

    func point(_ world: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + offset.width + world.x * scale,
                y: size.height / 2 + offset.height + world.y * scale)
    }

    mutating func zoom(by factor: CGFloat, at anchor: CGPoint, in size: CGSize) {
        let old = scale
        scale = min(3.5, max(0.15, scale * factor))
        let ratio = scale / old
        offset.width = anchor.x - size.width / 2 - (anchor.x - size.width / 2 - offset.width) * ratio
        offset.height = anchor.y - size.height / 2 - (anchor.y - size.height / 2 - offset.height) * ratio
    }

    mutating func fit(_ positions: [CGPoint], in size: CGSize) {
        guard let minX = positions.map(\.x).min(), let maxX = positions.map(\.x).max(),
              let minY = positions.map(\.y).min(), let maxY = positions.map(\.y).max() else {
            self = GraphViewport()
            return
        }
        let width = max(1, size.width - 132)
        let height = max(1, size.height - 116)
        scale = max(0.15, min(1.15, width / max(1, maxX - minX), height / max(1, maxY - minY)))
        offset = CGSize(width: -(minX + maxX) * scale / 2, height: -(minY + maxY) * scale / 2)
    }
}
