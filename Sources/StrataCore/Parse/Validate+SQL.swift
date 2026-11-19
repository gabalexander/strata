import Foundation

// Validation of op queries (docs/manifest.md, Operations): a query is copied from the code in full,
// never elided, described or left out.
extension LevelValidation {
    private static let copyHint = "copy the full query verbatim from the code (the sqlc .sql file, the ORM call or the raw SQL string), every statement of a transaction"

    func query(of op: Operation, at field: Field) {
        guard op.kind == .sql || op.kind == .search else { return }
        guard let query = op.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            if op.kind == .sql {
                field.diagnose("this sql op has no query yet; \(Self.copyHint), so its detail shows exactly what runs", .warning)
            }
            return
        }
        let location = field["query"]
        if let placeholder = SQLFormat.placeholder(in: query) {
            location.diagnose("the query looks elided ('\(placeholder)'); \(Self.copyHint)", .warning)
            return
        }
        guard op.kind == .sql else { return }
        if let partial = SQLFormat.incompleteStatements(query).first {
            let shown = partial.count > 48 ? String(partial.prefix(47)) + "…" : partial
            location.diagnose("'\(shown)' is not a whole statement (no FROM, INTO or SET where one belongs); \(Self.copyHint)", .warning)
        }
    }
}
