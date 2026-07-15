import Foundation
import FoundationModelsACP

/// A single Swift source file produced by the generator.
public struct GeneratedFile: Equatable, Sendable {
    /// The file name (e.g. `Models.generated.swift`).
    public let name: String

    /// The complete Swift source text of the file.
    public let contents: String

    /// Creates a generated file value.
    ///
    /// - Parameters:
    ///   - name: The file name the contents should be written under.
    ///   - contents: The complete Swift source text.
    public init(name: String, contents: String) {
        self.name = name
        self.contents = contents
    }
}

/// Emits Swift source for the non-union shapes of an ACP JSON schema:
/// object structs, distinct ID newtypes, and placeholder seams for the
/// definitions later generator stages resolve (tagged unions, string enums).
public struct SchemaGenerator: Sendable {
    /// The configuration describing renames, hand-written types, and
    /// wire-invariant field overrides.
    public let config: GeneratorConfig

    /// Creates a generator with the given configuration.
    ///
    /// - Parameter config: Generator configuration; defaults to the vendored
    ///   ACP v1 schema's configuration.
    public init(config: GeneratorConfig = .acpV1) {
        self.config = config
    }

    /// Parses a JSON schema document and emits Swift source files.
    ///
    /// Output is deterministic: definitions are processed in name order and
    /// properties are emitted required-first, `_meta` last, alphabetical
    /// within each group.
    ///
    /// - Parameter schemaJSON: The raw bytes of the schema document.
    /// - Returns: The generated Swift files.
    /// - Throws: `GeneratorError` when the schema cannot be parsed or
    ///   contains a shape the generator does not understand.
    public func generate(schemaJSON: Data) throws -> [GeneratedFile] {
        let schema: JSONValue
        do {
            schema = try JSONDecoder().decode(JSONValue.self, from: schemaJSON)
        } catch {
            throw GeneratorError.invalidSchema("not parseable as JSON: \(error)")
        }
        guard let definitions = schema["$defs"]?.objectValue else {
            throw GeneratorError.invalidSchema("missing top-level $defs object")
        }

        var identifiers: [String] = []
        var structModels: [StructModel] = []
        var unions: [String] = []
        var placeholders: [String] = []

        for (name, fragment) in definitions.sorted(by: { $0.key < $1.key }) {
            let documentation = fragment["description"]?.stringValue
            switch try classify(name: name, fragment: fragment) {
            case .handwritten:
                continue
            case .stringIdentifier:
                identifiers.append(
                    Emitter.identifierNewtype(name: emittedName(name), documentation: documentation)
                )
            case .stringEnum:
                unions.append(
                    Emitter.stringEnumDeclaration(try stringEnumModel(name: name, fragment: fragment))
                )
            case .taggedUnion:
                unions.append(
                    Emitter.taggedUnionDeclaration(try taggedUnionModel(name: name, fragment: fragment))
                )
            case .deferredUnion(let keyword):
                placeholders.append(
                    Emitter.placeholder(
                        name: emittedName(name),
                        reason: "Placeholder seam: schema `\(keyword)` union, decoded as raw JSON until a later generator stage replaces it.",
                        documentation: documentation
                    )
                )
            case .freeform:
                placeholders.append(
                    Emitter.placeholder(
                        name: emittedName(name),
                        reason: "Free-form by schema: the definition places no shape constraints, so raw JSON is its final representation.",
                        documentation: documentation
                    )
                )
            case .objectStruct:
                structModels.append(try structModel(name: name, fragment: fragment))
            }
        }

        try validateEmptyInstanceDefaults(structModels)

        return [
            GeneratedFile(
                name: "Identifiers.generated.swift",
                contents: Emitter.file(declarations: identifiers)
            ),
            GeneratedFile(
                name: "Models.generated.swift",
                contents: Emitter.file(declarations: structModels.map(Emitter.structDeclaration))
            ),
            GeneratedFile(
                name: "Unions.generated.swift",
                contents: Emitter.file(declarations: unions)
            ),
            GeneratedFile(
                name: "Unresolved.generated.swift",
                contents: Emitter.file(declarations: placeholders)
            ),
        ]
    }

    // MARK: - Classification

    /// Classifies a definition into the shape family the generator emits.
    ///
    /// - Parameters:
    ///   - name: The definition's schema name.
    ///   - fragment: The definition's schema fragment.
    /// - Returns: The definition kind.
    /// - Throws: `GeneratorError.unsupportedShape` for shapes the generator
    ///   does not know, so new schema constructs fail loudly.
    private func classify(name: String, fragment: JSONValue) throws -> DefinitionKind {
        if config.handwrittenDefinitions.contains(name) {
            return .handwritten
        }
        guard let members = fragment.objectValue else {
            throw GeneratorError.unsupportedShape(context: name, detail: "definition is not a JSON object")
        }
        if members["oneOf"] != nil {
            guard let variants = members["oneOf"]?.arrayValue else {
                throw GeneratorError.unsupportedShape(context: name, detail: "oneOf is not an array")
            }
            return try classifyOneOf(name: name, variants: variants)
        }
        for keyword in ["anyOf", "enum"] where members[keyword] != nil {
            return .deferredUnion(keyword: keyword)
        }
        switch members["type"]?.stringValue {
        case "object":
            return .objectStruct
        case "string":
            return .stringIdentifier
        case nil where members["type"] == nil:
            return .freeform
        case let other:
            throw GeneratorError.unsupportedShape(
                context: name,
                detail: "unhandled definition type \(other.map { "\"\($0)\"" } ?? String(describing: members["type"]))"
            )
        }
    }

    /// Maps a schema definition name to its emitted Swift type name.
    ///
    /// - Parameter name: The schema definition name.
    /// - Returns: The renamed Swift type name, or the name unchanged.
    private func emittedName(_ name: String) -> String {
        config.typeRenames[name] ?? name
    }

    // MARK: - Union models

    /// Distinguishes the two `oneOf` families this stage emits.
    ///
    /// - Parameters:
    ///   - name: The definition's schema name.
    ///   - variants: The `oneOf` entries.
    /// - Returns: `.stringEnum` when every variant is a string const,
    ///   `.taggedUnion` when every variant is a discriminated object.
    /// - Throws: `GeneratorError.unsupportedShape` for an empty or
    ///   mixed-shape `oneOf`, so unknown constructs fail loudly.
    private func classifyOneOf(name: String, variants: [JSONValue]) throws -> DefinitionKind {
        guard !variants.isEmpty else {
            throw GeneratorError.unsupportedShape(context: name, detail: "empty oneOf")
        }
        let types = variants.map { $0["type"]?.stringValue }
        if types.allSatisfy({ $0 == "string" }) {
            return .stringEnum
        }
        if types.allSatisfy({ $0 == "object" }) {
            return .taggedUnion
        }
        throw GeneratorError.unsupportedShape(
            context: name,
            detail: "oneOf mixes variant shapes; expected all string consts or all discriminated objects"
        )
    }

    /// Builds the emission model for a string-enum definition.
    ///
    /// - Parameters:
    ///   - name: The definition's schema name.
    ///   - fragment: The definition's schema fragment.
    /// - Returns: The string-enum model with cases in schema order.
    /// - Throws: `GeneratorError.unsupportedShape` when a variant lacks a
    ///   const value or the case names collide.
    private func stringEnumModel(name: String, fragment: JSONValue) throws -> StringEnumModel {
        let variants = fragment["oneOf"]?.arrayValue ?? []
        let cases = try variants.enumerated().map { index, variant in
            let context = "\(name) variant \(index)"
            guard let wireValue = variant["const"]?.stringValue else {
                throw GeneratorError.unsupportedShape(context: context, detail: "string variant without a const value")
            }
            return EnumCaseModel(
                wireValue: wireValue,
                swiftName: try swiftCaseName(fromWire: wireValue, context: context),
                documentation: variant["description"]?.stringValue
            )
        }
        try validateCaseNames(cases.map(\.swiftName), context: name)
        return StringEnumModel(
            name: emittedName(name),
            documentation: fragment["description"]?.stringValue,
            cases: cases
        )
    }

    /// Builds the emission model for a tagged-union definition.
    ///
    /// Every variant must be the serde internally-tagged shape: exactly one
    /// inline property (the shared discriminator, with a const tag), that
    /// property alone in `required`, and optionally a single-`$ref` `allOf`
    /// naming the payload flattened beside the discriminator.
    ///
    /// - Parameters:
    ///   - name: The definition's schema name.
    ///   - fragment: The definition's schema fragment.
    /// - Returns: The tagged-union model with cases in schema order.
    /// - Throws: `GeneratorError.unsupportedShape` when a variant deviates
    ///   from the internally-tagged shape or the case names collide.
    private func taggedUnionModel(name: String, fragment: JSONValue) throws -> TaggedUnionModel {
        let variants = fragment["oneOf"]?.arrayValue ?? []
        var discriminator: String?
        let cases = try variants.enumerated().map { index, variant in
            let context = "\(name) variant \(index)"
            guard let properties = variant["properties"]?.objectValue, properties.count == 1,
                let (key, keyFragment) = properties.first
            else {
                throw GeneratorError.unsupportedShape(
                    context: context,
                    detail: "expected exactly one inline property (the discriminator)"
                )
            }
            guard let tag = keyFragment["const"]?.stringValue else {
                throw GeneratorError.unsupportedShape(context: context, detail: "discriminator \(key) has no const value")
            }
            let required = (variant["required"]?.arrayValue ?? []).compactMap(\.stringValue)
            guard required == [key] else {
                throw GeneratorError.unsupportedShape(context: context, detail: "expected required to be exactly [\(key)]")
            }
            if let established = discriminator, established != key {
                throw GeneratorError.unsupportedShape(
                    context: context,
                    detail: "variants disagree on the discriminator: \(established) vs \(key)"
                )
            }
            discriminator = key
            var payloadType: String?
            if let allOf = variant["allOf"]?.arrayValue {
                guard allOf.count == 1, let reference = allOf[0]["$ref"]?.stringValue else {
                    throw GeneratorError.unsupportedShape(context: context, detail: "expected allOf to be a single payload $ref")
                }
                payloadType = try referencedTypeName(reference, context: context)
            }
            return UnionCaseModel(
                tag: tag,
                swiftName: try swiftCaseName(fromWire: tag, context: context),
                payloadType: payloadType,
                documentation: variant["description"]?.stringValue
            )
        }
        guard let discriminator else {
            throw GeneratorError.unsupportedShape(context: name, detail: "empty oneOf")
        }
        try validateCaseNames(cases.map(\.swiftName), context: name)
        // The discriminator becomes the CodingKeys case, so it must itself
        // be a valid Swift identifier.
        _ = try swiftCaseName(fromWire: discriminator, context: "\(name) discriminator")
        return TaggedUnionModel(
            name: emittedName(name),
            documentation: fragment["description"]?.stringValue,
            discriminator: discriminator,
            cases: cases
        )
    }

    /// Swift keywords that cannot appear as bare `case` names; a wire value
    /// mapping onto one would emit uncompilable source, so generation fails
    /// loudly instead.
    private static let swiftKeywords: Set<String> = [
        "as", "associatedtype", "any", "break", "case", "catch", "class",
        "continue", "default", "defer", "deinit", "do", "else", "enum",
        "extension", "fallthrough", "false", "fileprivate", "for", "func",
        "guard", "if", "import", "in", "init", "inout", "internal", "is",
        "let", "nil", "operator", "precedencegroup", "private", "protocol",
        "public", "repeat", "rethrows", "return", "self", "Self", "static",
        "struct", "subscript", "super", "switch", "throw", "throws", "true",
        "try", "typealias", "var", "where", "while",
    ]

    /// Maps a snake_case wire value to a camelCase Swift case name.
    ///
    /// - Parameters:
    ///   - wireValue: The wire string (e.g. `switch_mode`).
    ///   - context: `Definition variant` for error messages.
    /// - Returns: The camelCase Swift identifier (e.g. `switchMode`).
    /// - Throws: `GeneratorError.unsupportedShape` when the wire value does
    ///   not map to a plain, non-keyword Swift identifier.
    private func swiftCaseName(fromWire wireValue: String, context: String) throws -> String {
        let parts = wireValue.split(separator: "_")
        let name = parts.enumerated()
            .map { index, part in
                index == 0 ? String(part) : part.prefix(1).uppercased() + part.dropFirst()
            }
            .joined()
        guard name.first?.isLetter == true, name.allSatisfy({ $0.isLetter || $0.isNumber }),
            !Self.swiftKeywords.contains(name)
        else {
            throw GeneratorError.unsupportedShape(
                context: context,
                detail: "wire value \"\(wireValue)\" does not map to a plain Swift identifier"
            )
        }
        return name
    }

    /// Verifies enum case names are unique and none collides with the
    /// generated `unknown` fallback case.
    ///
    /// - Parameters:
    ///   - names: The Swift case names in schema order.
    ///   - context: The definition name for error messages.
    /// - Throws: `GeneratorError.unsupportedShape` on any collision.
    private func validateCaseNames(_ names: [String], context: String) throws {
        var seen = Set<String>()
        for name in names {
            guard name != "unknown" else {
                throw GeneratorError.unsupportedShape(context: context, detail: "case name collides with the unknown fallback")
            }
            guard seen.insert(name).inserted else {
                throw GeneratorError.unsupportedShape(context: context, detail: "duplicate case name \(name)")
            }
        }
    }

    // MARK: - Struct models

    /// Builds the emission model for an object definition.
    ///
    /// - Parameters:
    ///   - name: The definition's schema name.
    ///   - fragment: The definition's schema fragment.
    /// - Returns: The struct model with properties in emission order.
    /// - Throws: `GeneratorError.unsupportedShape` for un-modelable fields.
    private func structModel(name: String, fragment: JSONValue) throws -> StructModel {
        let properties = fragment["properties"]?.objectValue ?? [:]
        let required = Set((fragment["required"]?.arrayValue ?? []).compactMap(\.stringValue))
        var models = try properties
            .sorted(by: { $0.key < $1.key })
            .map { wireName, propertyFragment in
                try propertyModel(
                    definition: name,
                    wireName: wireName,
                    fragment: propertyFragment,
                    isRequired: required.contains(wireName)
                )
            }
        models.sort { lhs, rhs in
            (emissionRank(of: lhs), lhs.wireName) < (emissionRank(of: rhs), rhs.wireName)
        }
        return StructModel(
            name: emittedName(name),
            documentation: fragment["description"]?.stringValue,
            properties: models
        )
    }

    /// Orders properties required-first, optional second, `_meta` last.
    ///
    /// - Parameter property: The property model.
    /// - Returns: The property's group rank.
    private func emissionRank(of property: PropertyModel) -> Int {
        if property.wireName == "_meta" { return 2 }
        return property.isRequired ? 0 : 1
    }

    /// Builds the emission model for one property.
    ///
    /// - Parameters:
    ///   - definition: The enclosing definition's schema name.
    ///   - wireName: The property's JSON member name.
    ///   - fragment: The property's schema fragment.
    ///   - isRequired: Whether the schema lists the property in `required`.
    /// - Returns: The property model.
    /// - Throws: `GeneratorError.unsupportedShape` when the type, default, or
    ///   forgiving annotations cannot be modeled.
    private func propertyModel(
        definition: String,
        wireName: String,
        fragment: JSONValue,
        isRequired: Bool
    ) throws -> PropertyModel {
        let context = "\(definition).\(wireName)"
        let override = config.wireInvariantFields[context]
        let resolved = try resolveType(fragment, override: override, context: context)

        let hasDefaultOnError = fragment["x-deserialize-default-on-error"]?.boolValue == true
        let skipsInvalidItems = fragment["x-deserialize-skip-invalid-items"]?.boolValue == true

        var defaultExpression: String?
        var defaultsToEmptyInstance = false
        var objectDefaultMembers: [String: JSONValue]?
        if let rawDefault = fragment["default"], rawDefault != .null {
            (defaultExpression, defaultsToEmptyInstance) = try defaultExpressionParts(
                for: rawDefault,
                type: resolved,
                context: context
            )
            if defaultsToEmptyInstance {
                objectDefaultMembers = rawDefault.objectValue
            }
        }
        let isOptional = defaultExpression == nil && (!isRequired || resolved.nullable)

        let strategy: DecodeStrategy
        if override != nil {
            // Wire invariants win over forgiving annotations: a relative path
            // or 0-based line must stay a decode-time error.
            strategy = .strict
        } else if skipsInvalidItems {
            guard resolved.element != nil else {
                throw GeneratorError.unsupportedShape(
                    context: context,
                    detail: "x-deserialize-skip-invalid-items on a non-array field"
                )
            }
            strategy = .forgivingArray
        } else if hasDefaultOnError {
            guard isOptional || defaultExpression != nil else {
                throw GeneratorError.unsupportedShape(
                    context: context,
                    detail: "x-deserialize-default-on-error on a required field with no default"
                )
            }
            strategy = .forgivingScalar
        } else {
            strategy = .strict
        }

        return PropertyModel(
            wireName: wireName,
            swiftName: swiftName(forWireName: wireName),
            typeExpression: resolved.base,
            elementType: resolved.element,
            isOptional: isOptional,
            isRequired: isRequired,
            defaultExpression: defaultExpression,
            defaultsToEmptyInstance: defaultsToEmptyInstance,
            objectDefaultMembers: objectDefaultMembers,
            strategy: strategy,
            documentation: fragment["description"]?.stringValue
        )
    }

    /// Derives the Swift property name from the wire name.
    ///
    /// Wire names are already camelCase; ACP's reserved `_meta` drops its
    /// leading underscore (mapped back through CodingKeys).
    ///
    /// - Parameter wireName: The JSON member name.
    /// - Returns: The Swift property name.
    private func swiftName(forWireName wireName: String) -> String {
        String(wireName.drop(while: { $0 == "_" }))
    }

    // MARK: - Type resolution

    /// Resolves a schema fragment to a Swift type.
    ///
    /// - Parameters:
    ///   - fragment: The schema fragment to resolve.
    ///   - override: The wire-invariant newtype the scalar position maps to.
    ///   - context: `Definition.field` for error messages.
    /// - Returns: The resolved type.
    /// - Throws: `GeneratorError.unsupportedShape` for un-modelable fragments.
    private func resolveType(
        _ fragment: JSONValue,
        override: GeneratorConfig.InvariantType?,
        context: String
    ) throws -> ResolvedType {
        guard let members = fragment.objectValue else {
            throw GeneratorError.unsupportedShape(context: context, detail: "fragment is not a JSON object")
        }

        if let reference = members["$ref"]?.stringValue {
            return ResolvedType(base: try referencedTypeName(reference, context: context), element: nil, nullable: false)
        }
        if let allOf = members["allOf"]?.arrayValue {
            guard allOf.count == 1 else {
                throw GeneratorError.unsupportedShape(context: context, detail: "allOf with \(allOf.count) entries")
            }
            return try resolveType(allOf[0], override: override, context: context)
        }
        if let anyOf = members["anyOf"]?.arrayValue {
            let nonNull = anyOf.filter { $0["type"]?.stringValue != "null" }
            if anyOf.count == 2, nonNull.count == 1 {
                var inner = try resolveType(nonNull[0], override: override, context: context)
                inner.nullable = true
                return inner
            }
            if anyOf.count == 1 {
                return try resolveType(anyOf[0], override: override, context: context)
            }
            // Inline anonymous union — the tagged-union stage's seam.
            return ResolvedType(base: "JSONValue", element: nil, nullable: false)
        }
        if members["oneOf"] != nil {
            return ResolvedType(base: "JSONValue", element: nil, nullable: false)
        }

        var nullable = false
        var typeName: String?
        switch members["type"] {
        case .some(.string(let single)):
            typeName = single
        case .some(.array(let list)):
            let names = list.compactMap(\.stringValue)
            nullable = names.contains("null")
            let concrete = names.filter { $0 != "null" }
            guard concrete.count == 1 else {
                // Multi-typed values carry no single Swift shape: raw JSON.
                return ResolvedType(base: "JSONValue", element: nil, nullable: nullable)
            }
            typeName = concrete[0]
        case nil:
            // No shape constraints at all (`_meta`-like free-form fields).
            return ResolvedType(base: "JSONValue", element: nil, nullable: false)
        case let other:
            throw GeneratorError.unsupportedShape(context: context, detail: "unhandled type \(String(describing: other))")
        }

        switch typeName {
        case "string":
            return ResolvedType(base: try scalarName("String", override: override, allowed: .absolutePath, context: context), element: nil, nullable: nullable)
        case "integer":
            return ResolvedType(base: try scalarName("Int", override: override, allowed: .lineNumber, context: context), element: nil, nullable: nullable)
        case "boolean":
            return ResolvedType(base: "Bool", element: nil, nullable: nullable)
        case "number":
            return ResolvedType(base: "Double", element: nil, nullable: nullable)
        case "object":
            // Objects without a $ref are free-form maps (`additionalProperties`).
            return ResolvedType(base: "JSONValue", element: nil, nullable: nullable)
        case "array":
            guard let items = members["items"] else {
                throw GeneratorError.unsupportedShape(context: context, detail: "array without items")
            }
            let element = try resolveType(items, override: override, context: context)
            guard element.element == nil else {
                throw GeneratorError.unsupportedShape(context: context, detail: "nested arrays are not modeled")
            }
            return ResolvedType(base: "[\(element.base)]", element: element.base, nullable: nullable)
        default:
            throw GeneratorError.unsupportedShape(context: context, detail: "unhandled scalar type \"\(typeName ?? "nil")\"")
        }
    }

    /// Resolves a scalar type name, applying a wire-invariant override.
    ///
    /// - Parameters:
    ///   - plain: The bare Swift scalar name (e.g. `String`).
    ///   - override: The configured invariant newtype, if any.
    ///   - allowed: The invariant kind this scalar may map to.
    ///   - context: `Definition.field` for error messages.
    /// - Returns: The override's type name, or `plain`.
    /// - Throws: `GeneratorError.unsupportedShape` when the configured
    ///   override does not fit the scalar (a stale config entry).
    private func scalarName(
        _ plain: String,
        override: GeneratorConfig.InvariantType?,
        allowed: GeneratorConfig.InvariantType,
        context: String
    ) throws -> String {
        guard let override else { return plain }
        guard override == allowed else {
            throw GeneratorError.unsupportedShape(
                context: context,
                detail: "wire-invariant override \(override.rawValue) does not apply to \(plain)"
            )
        }
        return override.rawValue
    }

    /// Resolves a `$ref` to the emitted Swift type name.
    ///
    /// - Parameters:
    ///   - reference: The JSON pointer (e.g. `#/$defs/SessionId`).
    ///   - context: `Definition.field` for error messages.
    /// - Returns: The referenced type's emitted name.
    /// - Throws: `GeneratorError.unsupportedShape` for external references.
    private func referencedTypeName(_ reference: String, context: String) throws -> String {
        let prefix = "#/$defs/"
        guard reference.hasPrefix(prefix) else {
            throw GeneratorError.unsupportedShape(context: context, detail: "unsupported $ref \"\(reference)\"")
        }
        return emittedName(String(reference.dropFirst(prefix.count)))
    }

    // MARK: - Defaults

    /// Renders a schema `default` value as a Swift expression.
    ///
    /// Object defaults render as `Type()`; `validateEmptyInstanceDefaults`
    /// verifies member-by-member that the schema's default object equals the
    /// target type's own per-field defaults, so `Type()` is value-faithful.
    ///
    /// - Parameters:
    ///   - value: The schema default (never JSON null).
    ///   - type: The property's resolved type.
    ///   - context: `Definition.field` for error messages.
    /// - Returns: The expression and whether it is a `Type()` empty instance.
    /// - Throws: `GeneratorError.unsupportedShape` for defaults the generator
    ///   cannot render (e.g. non-empty array defaults).
    private func defaultExpressionParts(
        for value: JSONValue,
        type: ResolvedType,
        context: String
    ) throws -> (expression: String, emptyInstance: Bool) {
        switch value {
        case .bool(let flag):
            return (flag ? "true" : "false", false)
        case .number(let number):
            if type.base == "Int", number == number.rounded() {
                return (String(Int(number)), false)
            }
            return (String(number), false)
        case .string(let string):
            let escaped = string
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return ("\"\(escaped)\"", false)
        case .array(let elements):
            guard elements.isEmpty else {
                throw GeneratorError.unsupportedShape(context: context, detail: "non-empty array default")
            }
            return ("[]", false)
        case .object(let members):
            if type.base == "JSONValue" {
                guard members.isEmpty else {
                    throw GeneratorError.unsupportedShape(
                        context: context,
                        detail: "non-empty object default on a free-form field would be lost"
                    )
                }
                return (".object([:])", false)
            }
            return ("\(type.base)()", true)
        case .null:
            throw GeneratorError.unsupportedShape(context: context, detail: "null default should be modeled as optional")
        }
    }

    /// Verifies every `Type()` default targets a generated struct whose
    /// memberwise initializer is fully defaulted, so the expression compiles
    /// and equals the schema's nested default object.
    ///
    /// - Parameter models: All generated struct models.
    /// - Throws: `GeneratorError.unsupportedShape` when a `Type()` default
    ///   points at a non-generated or not-fully-defaulted type, or when the
    ///   schema's default object diverges from the target's own defaults.
    private func validateEmptyInstanceDefaults(_ models: [StructModel]) throws {
        let byName = Dictionary(uniqueKeysWithValues: models.map { ($0.name, $0) })
        for model in models {
            for property in model.properties where property.defaultsToEmptyInstance {
                try validateObjectDefault(
                    members: property.objectDefaultMembers ?? [:],
                    targetName: property.typeExpression,
                    context: "\(model.name).\(property.wireName)",
                    structsByName: byName
                )
            }
        }
    }

    /// Verifies a `Type()` default is faithful: the target is a generated,
    /// fully-defaulted struct, and every member of the schema's default
    /// object equals the target property's own default — recursing into
    /// nested object defaults. A divergence would make `Type()` silently
    /// encode the wrong value, so it fails generation instead.
    ///
    /// - Parameters:
    ///   - members: The schema default object's members.
    ///   - targetName: The emitted name of the struct the default constructs.
    ///   - context: `Definition.field` for error messages.
    ///   - structsByName: All generated struct models by emitted name.
    /// - Throws: `GeneratorError.unsupportedShape` on any mismatch.
    private func validateObjectDefault(
        members: [String: JSONValue],
        targetName: String,
        context: String,
        structsByName: [String: StructModel]
    ) throws {
        guard let target = structsByName[targetName] else {
            throw GeneratorError.unsupportedShape(
                context: context,
                detail: "object default targets non-generated type \(targetName)"
            )
        }
        for property in target.properties where !property.isOptional && property.defaultExpression == nil {
            throw GeneratorError.unsupportedShape(
                context: context,
                detail: "object default targets \(targetName), which has required field \(property.wireName)"
            )
        }
        for (wireName, value) in members.sorted(by: { $0.key < $1.key }) {
            let memberContext = "\(context).\(wireName)"
            guard let property = target.properties.first(where: { $0.wireName == wireName }) else {
                throw GeneratorError.unsupportedShape(
                    context: memberContext,
                    detail: "default member has no matching property on \(targetName)"
                )
            }
            if value == .null {
                guard property.isOptional else {
                    throw GeneratorError.unsupportedShape(
                        context: memberContext,
                        detail: "null default member for non-optional \(targetName).\(wireName)"
                    )
                }
                continue
            }
            let resolved = ResolvedType(
                base: property.typeExpression,
                element: property.elementType,
                nullable: false
            )
            let (expression, emptyInstance) = try defaultExpressionParts(
                for: value,
                type: resolved,
                context: memberContext
            )
            guard expression == property.defaultExpression else {
                throw GeneratorError.unsupportedShape(
                    context: memberContext,
                    detail: "default member \(expression) differs from \(targetName).\(wireName)'s own default \(property.defaultExpression ?? "nil")"
                )
            }
            if emptyInstance {
                try validateObjectDefault(
                    members: value.objectValue ?? [:],
                    targetName: property.typeExpression,
                    context: memberContext,
                    structsByName: structsByName
                )
            }
        }
    }
}
