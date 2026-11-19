import Foundation

// Decoding of top-level `enums:` (docs/manifest.md, Enums). Values are numbers or strings and are
// kept as written, as strings, so `3200` in a value, a transition, a sample row and a query compare equal.

extension Decode {
    static let manifestEnumKeys: Set<String> = ["enums"]
    static let enumKeys: Set<String> = ["id", "label", "doc", "code", "values", "transitions"]
    static let enumValueKeys: Set<String> = ["value", "name", "doc", "terminal"]
    static let enumTransitionKeys: Set<String> = ["from", "to", "label", "by"]

    static func enumDef(_ field: Field) -> EnumDef? {
        guard field.mapping(enumKeys) else { return nil }
        let id = field["id"].id(required: true)
        guard let id else { return nil }
        var def = EnumDef(id: id, label: field["label"].text(nonempty: true))
        def.line = field.line
        def.doc = field["doc"].text()
        def.code = field["code"].textList(orOne: true)
        let values = field["values"]
        def.values = values.items(required: true).compactMap(enumValue)
        if values.node?.elements?.isEmpty == true { values.diagnose("an enum needs at least one value") }
        def.transitions = field["transitions"].items().compactMap(enumTransition)
        return def
    }

    static func enumValue(_ field: Field) -> EnumValue? {
        guard field.mapping(enumValueKeys) else { return nil }
        let value = field["value"].enumScalar(required: true)
        let name = field["name"].enumScalar(required: true)
        guard let value, let name else { return nil }
        var result = EnumValue(value: value, name: name)
        result.doc = field["doc"].text()
        result.terminal = field["terminal"].bool() ?? false
        return result
    }

    static func enumTransition(_ field: Field) -> EnumTransition? {
        guard field.mapping(enumTransitionKeys) else { return nil }
        let from = field["from"].enumScalar(required: true)
        let to = field["to"].enumScalar(required: true)
        guard let from, let to else { return nil }
        var transition = EnumTransition(from: from, to: to)
        transition.label = field["label"].text()
        transition.by = field["by"].scalar { try Syntax.opReference($0, qualified: false) }
        return transition
    }
}

extension Field {
    /// A number or a string as written (`3200`, `scheduled`); empty text is an error.
    func enumScalar(required: Bool = false) -> String? {
        read(required: required) { node in
            guard case .scalar(let text, _) = node.content else { throw InvalidValue("expected a number or a string") }
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { throw InvalidValue("expected a nonempty value") }
            return text
        }
    }
}
