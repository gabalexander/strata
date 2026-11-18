import StrataCore

// `Fixtures.checkoutWithData` backs the data UI's snapshots: its sample rows must really join.

func dataFixtureChecks() -> [CheckCase] {
    [
        CheckCase(name: "data fixture: rows fit, keys are unique, every ref value joins") {
            let level = Fixtures.checkoutWithData.root
            guard let db = level.node("db") else { check(false, "no db node"); return }
            let tables = Dictionary(uniqueKeysWithValues: db.schema.map { ($0.name, $0) })
            check(tables.count == 6, "expected 6 tables, got \(tables.count)")
            for table in db.schema {
                for (i, row) in table.rows.enumerated() {
                    check(row.count == table.columns.count, "\(table.name) row \(i) has \(row.count) values for \(table.columns.count) columns")
                }
                let pk = table.columns.indices.filter { table.columns[$0].pk }
                let keys = table.rows.map { row in pk.map { row[$0] ?? "NULL" }.joined(separator: "|") }
                check(!pk.isEmpty && Set(keys).count == keys.count, "\(table.name) needs a unique primary key")
                for (c, column) in table.columns.enumerated() {
                    guard let ref = column.ref else { continue }
                    let parts = ref.split(separator: ".").map(String.init)
                    guard parts.count == 2, let target = tables[parts[0]],
                          let t = target.columns.firstIndex(where: { $0.name == parts[1] }) else {
                        check(false, "\(table.name).\(column.name) → \(ref) doesn't resolve"); continue
                    }
                    let values = Set(target.rows.compactMap { $0[t] })
                    for row in table.rows {
                        if let value = row[c] { check(values.contains(value), "\(table.name).\(column.name) = \(value) joins no row of \(ref)") }
                    }
                }
            }
            check(db.schema.contains { table in table.columns.filter(\.pk).count > 1 }, "no composite key")
            check(db.schema.contains { table in table.rows.contains { $0.contains(nil) } }, "no NULL sample values")
            check(db.schema.allSatisfy { $0.volume?.rows != nil }, "every table should have a volume")
            let entities = level.nodes.flatMap(\.entities)
            check(entities.first { $0.name == "Order" }.map { 1 + $0.includes.count } == 4, "Order should span 4 tables")
            check(entities.contains { $0.name == "Price" }, "no Price entity")
            for entity in entities {
                for table in [entity.root] + entity.includes { check(tables[table] != nil, "\(entity.name) names missing table \(table)") }
            }
            for node in level.nodes {
                for op in node.ops where op.target == "db" {
                    for table in op.tables { check(tables[table] != nil, "\(node.id)/\(op.id) names missing table \(table)") }
                }
            }
        },
    ]
}
