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

/// Emits Swift source from an ACP JSON schema document.
///
/// This stage covers object structs, distinct ID newtypes, string enums,
/// tagged unions, the method-routing table, and placeholder seams for the
/// definitions later generator stages resolve.
public struct SchemaGenerator: Sendable {
    /// The configuration for this generator run.
    ///
    /// Describes renames, hand-written types, wire-invariant field
    /// overrides, and deprecated methods.
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
    /// - Parameters:
    ///   - schemaJSON: The raw bytes of the schema document.
    ///   - metaJSON: The raw bytes of the stable routing manifest
    ///     (`meta.json`); when present, the method-routing table is emitted.
    ///   - unstableMetaJSON: The raw bytes of the unstable routing manifest
    ///     (`meta.unstable.json`); when present, methods it routes beyond
    ///     the stable manifest are emitted into the `Unstable` namespace.
    ///     Requires `metaJSON`.
    /// - Returns: The generated Swift files.
    /// - Throws: `GeneratorError` when an input cannot be parsed, the schema
    ///   contains a shape the generator does not understand, or the routing
    ///   manifests disagree with the schema's `x-side`/`x-method`
    ///   annotations.
    public func generate(
        schemaJSON: Data,
        metaJSON: Data? = nil,
        unstableMetaJSON: Data? = nil
    ) throws -> [GeneratedFile] {
        guard metaJSON != nil || unstableMetaJSON == nil else {
            throw GeneratorError.invalidSchema(
                "unstable routing manifest requires the stable routing manifest"
            )
        }
        let schema = try decodeJSON(data: schemaJSON, context: "schema document")
        guard let definitions = schema[Self.defsKey]?.objectValue else {
            throw GeneratorError.invalidSchema("missing top-level \(Self.defsKey) object")
        }

        var identifiers: [String] = []
        var structModels: [StructModel] = []
        var unions: [String] = []
        var placeholders: [String] = []

        for (name, fragment) in Self.orderedEntries(of: definitions) {
            let documentation = fragment[Self.descriptionKey]?.stringValue
            switch try classify(name: name, fragment: fragment) {
            case .handwritten:
                continue
            case .stringIdentifier:
                identifiers.append(
                    Emitter.identifierNewtype(name: emittedName(name: name), documentation: documentation)
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
                        name: emittedName(name: name),
                        reason: "Placeholder seam: schema `\(keyword)` union, decoded as raw JSON until a later generator stage replaces it.",
                        documentation: documentation
                    )
                )
            case .freeform:
                placeholders.append(
                    Emitter.placeholder(
                        name: emittedName(name: name),
                        reason: "Free-form by schema: the definition places no shape constraints, so raw JSON is its final representation.",
                        documentation: documentation
                    )
                )
            case .objectStruct:
                structModels.append(try structModel(name: name, fragment: fragment))
            }
        }

        try validateEmptyInstanceDefaults(models: structModels)

        var files = [
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
        if let metaJSON {
            files.append(
                try methodTableFile(
                    definitions: definitions,
                    metaJSON: metaJSON,
                    unstableMetaJSON: unstableMetaJSON
                )
            )
        }
        return files
    }

    // MARK: - Schema keywords

    /// The schema keyword holding the document's definitions.
    private static let defsKey = "$defs"

    /// The schema keyword referencing another definition.
    private static let refKey = "$ref"

    /// The schema keyword naming a fragment's JSON type.
    private static let typeKey = "type"

    /// The schema keyword for exclusive unions.
    private static let oneOfKey = "oneOf"

    /// The error detail for a union with no variants.
    private static let emptyUnionDetail = "empty \(oneOfKey)"

    /// The schema keyword for inclusive unions.
    private static let anyOfKey = "anyOf"

    /// The schema keyword for intersections (single-ref wrappers here).
    private static let allOfKey = "allOf"

    /// The schema keyword for closed value sets.
    private static let enumKey = "enum"

    /// The schema keyword carrying a fragment's documentation.
    private static let descriptionKey = "description"

    /// The schema keyword pinning a member to a single value.
    private static let constKey = "const"

    /// The schema keyword listing an object's required members.
    private static let requiredKey = "required"

    /// The schema keyword declaring an object's members.
    private static let propertiesKey = "properties"

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
        let members = try objectMembers(of: fragment, context: name, subject: "definition")
        if members[Self.oneOfKey] != nil {
            guard let variants = members[Self.oneOfKey]?.arrayValue else {
                throw GeneratorError.unsupportedShape(context: name, detail: "\(Self.oneOfKey) is not an array")
            }
            return try classifyOneOf(name: name, variants: variants)
        }
        for keyword in [Self.anyOfKey, Self.enumKey] where members[keyword] != nil {
            return .deferredUnion(keyword: keyword)
        }
        switch members[Self.typeKey]?.stringValue {
        case "object":
            return .objectStruct
        case "string":
            return .stringIdentifier
        case nil where members[Self.typeKey] == nil:
            return .freeform
        case let other:
            throw GeneratorError.unsupportedShape(
                context: name,
                detail: "unhandled definition type \(other.map { "\"\($0)\"" } ?? String(describing: members[Self.typeKey]))"
            )
        }
    }

    /// Maps a schema definition name to its emitted Swift type name.
    ///
    /// - Parameter name: The schema definition name.
    /// - Returns: The renamed Swift type name, or the name unchanged.
    private func emittedName(name: String) -> String {
        config.typeRenames[name] ?? name
    }

    /// Decodes raw input bytes as a JSON value.
    ///
    /// Every generator input (schema document, routing manifests) routes
    /// through this one decode-and-fail path.
    ///
    /// - Parameters:
    ///   - data: The raw JSON bytes.
    ///   - context: Which document, for error messages.
    /// - Returns: The parsed JSON value.
    /// - Throws: `GeneratorError.invalidSchema` when the bytes are not JSON.
    private func decodeJSON(data: Data, context: String) throws -> JSONValue {
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw GeneratorError.invalidSchema("\(context) is not parseable as JSON: \(error)")
        }
    }

    /// A string-keyed map's entries in deterministic key order.
    ///
    /// - Parameter members: The map to order.
    /// - Returns: The entries sorted by key.
    private static func orderedEntries<Value>(of members: [String: Value]) -> [(key: String, value: Value)] {
        members.sorted { $0.key < $1.key }
    }

    /// Unwraps a fragment's object members, failing loudly otherwise.
    ///
    /// - Parameters:
    ///   - fragment: The schema fragment.
    ///   - context: The definition or field, for error messages.
    ///   - subject: What the fragment is (`definition`/`fragment`), for the
    ///     error message.
    /// - Returns: The fragment's object members.
    /// - Throws: `GeneratorError.unsupportedShape` when the fragment is not
    ///   a JSON object.
    private func objectMembers(
        of fragment: JSONValue,
        context: String,
        subject: String
    ) throws -> [String: JSONValue] {
        guard let members = fragment.objectValue else {
            throw GeneratorError.unsupportedShape(context: context, detail: "\(subject) is not a JSON object")
        }
        return members
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
            throw GeneratorError.unsupportedShape(context: name, detail: Self.emptyUnionDetail)
        }
        let types = variants.map { $0[Self.typeKey]?.stringValue }
        if types.allSatisfy({ $0 == "string" }) {
            return .stringEnum
        }
        if types.allSatisfy({ $0 == "object" }) {
            return .taggedUnion
        }
        throw GeneratorError.unsupportedShape(
            context: name,
            detail: "\(Self.oneOfKey) mixes variant shapes; expected all string consts or all discriminated objects"
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
        let variants = unionVariants(of: fragment)
        let cases = try variants.enumerated().map { index, variant in
            let context = "\(name) variant \(index)"
            guard let wireValue = variant[Self.constKey]?.stringValue else {
                throw GeneratorError.unsupportedShape(context: context, detail: "string variant without a \(Self.constKey) value")
            }
            return EnumCaseModel(
                wireValue: wireValue,
                swiftName: try swiftCaseName(fromWire: wireValue, context: context),
                documentation: variant[Self.descriptionKey]?.stringValue
            )
        }
        try validateCaseNames(names: cases.map(\.swiftName), context: name)
        return StringEnumModel(
            name: emittedName(name: name),
            documentation: fragment[Self.descriptionKey]?.stringValue,
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
        let variants = unionVariants(of: fragment)
        var discriminator: String?
        let cases = try variants.enumerated().map { index, variant in
            let context = "\(name) variant \(index)"
            guard let properties = variant[Self.propertiesKey]?.objectValue, properties.count == 1,
                let (key, keyFragment) = properties.first
            else {
                throw GeneratorError.unsupportedShape(
                    context: context,
                    detail: "expected exactly one inline property (the discriminator)"
                )
            }
            guard let tag = keyFragment[Self.constKey]?.stringValue else {
                throw GeneratorError.unsupportedShape(context: context, detail: "discriminator \(key) has no \(Self.constKey) value")
            }
            let required = (variant[Self.requiredKey]?.arrayValue ?? []).compactMap(\.stringValue)
            guard required == [key] else {
                throw GeneratorError.unsupportedShape(context: context, detail: "expected \(Self.requiredKey) to be exactly [\(key)]")
            }
            if let established = discriminator, established != key {
                throw GeneratorError.unsupportedShape(
                    context: context,
                    detail: "variants disagree on the discriminator: \(established) vs \(key)"
                )
            }
            discriminator = key
            var payloadType: String?
            if let allOf = variant[Self.allOfKey]?.arrayValue {
                guard allOf.count == 1, let reference = allOf[0][Self.refKey]?.stringValue else {
                    throw GeneratorError.unsupportedShape(context: context, detail: "expected \(Self.allOfKey) to be a single payload \(Self.refKey)")
                }
                payloadType = try referencedTypeName(reference: reference, context: context)
            }
            return UnionCaseModel(
                tag: tag,
                swiftName: try swiftCaseName(fromWire: tag, context: context),
                payloadType: payloadType,
                documentation: variant[Self.descriptionKey]?.stringValue
            )
        }
        guard let discriminator else {
            throw GeneratorError.unsupportedShape(context: name, detail: Self.emptyUnionDetail)
        }
        try validateCaseNames(names: cases.map(\.swiftName), context: name)
        // The discriminator becomes the CodingKeys case, so it must itself
        // be a valid Swift identifier.
        _ = try swiftCaseName(fromWire: discriminator, context: "\(name) discriminator")
        return TaggedUnionModel(
            name: emittedName(name: name),
            documentation: fragment[Self.descriptionKey]?.stringValue,
            discriminator: discriminator,
            cases: cases
        )
    }

    /// Swift keywords that cannot appear as bare `case` names.
    ///
    /// A wire value mapping onto one would emit uncompilable source, so
    /// generation fails loudly instead.
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
    private func validateCaseNames(names: [String], context: String) throws {
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
        let properties = fragment[Self.propertiesKey]?.objectValue ?? [:]
        let required = Set((fragment[Self.requiredKey]?.arrayValue ?? []).compactMap(\.stringValue))
        var models = try Self.orderedEntries(of: properties)
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
            name: emittedName(name: name),
            documentation: fragment[Self.descriptionKey]?.stringValue,
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

    /// The schema extension keyword marking a forgiving scalar field.
    private static let defaultOnErrorKey = "x-deserialize-default-on-error"

    /// The schema extension keyword marking a forgiving array field.
    private static let skipInvalidItemsKey = "x-deserialize-skip-invalid-items"

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
        let resolved = try resolveType(fragment: fragment, override: override, context: context)
        let defaults = try defaultParts(of: fragment, type: resolved, context: context)
        let isOptional = defaults.expression == nil && (!isRequired || resolved.nullable)
        let strategy = try decodeStrategy(
            of: fragment,
            resolved: resolved,
            override: override,
            isOptional: isOptional,
            hasDefault: defaults.expression != nil,
            context: context
        )

        return PropertyModel(
            wireName: wireName,
            swiftName: swiftName(forWireName: wireName),
            typeExpression: resolved.base,
            elementType: resolved.element,
            isOptional: isOptional,
            isRequired: isRequired,
            defaultExpression: defaults.expression,
            defaultsToEmptyInstance: defaults.isEmptyInstance,
            objectDefaultMembers: defaults.objectMembers,
            strategy: strategy,
            documentation: fragment[Self.descriptionKey]?.stringValue
        )
    }

    /// The parsed `default` state of a property fragment.
    ///
    /// The three mutually exclusive states are explicit cases, so an
    /// impossible combination (say, object members without an empty
    /// instance) cannot be represented.
    private enum DefaultParts {
        /// The fragment carries no schema `default`.
        case none

        /// A plain rendered Swift default expression.
        case simple(expression: String)

        /// A `Type()` empty-instance default with the schema's object
        /// members to validate against the target's own defaults.
        case emptyInstance(expression: String, members: [String: JSONValue])

        /// The rendered Swift default expression, if any.
        var expression: String? {
            switch self {
            case .none: nil
            case .simple(let expression): expression
            case .emptyInstance(let expression, _): expression
            }
        }

        /// Whether the expression is a `Type()` empty instance.
        var isEmptyInstance: Bool {
            if case .emptyInstance = self { return true }
            return false
        }

        /// The schema default's object members for empty-instance defaults.
        var objectMembers: [String: JSONValue]? {
            if case .emptyInstance(_, let members) = self { return members }
            return nil
        }
    }

    /// Parses a property fragment's schema `default`, if any.
    ///
    /// - Parameters:
    ///   - fragment: The property's schema fragment.
    ///   - type: The property's resolved type.
    ///   - context: `Definition.field` for error messages.
    /// - Returns: The parsed default state; `.none` when absent.
    /// - Throws: `GeneratorError.unsupportedShape` for un-renderable
    ///   defaults.
    private func defaultParts(
        of fragment: JSONValue,
        type: ResolvedType,
        context: String
    ) throws -> DefaultParts {
        guard let rawDefault = fragment["default"], rawDefault != .null else {
            return .none
        }
        let (expression, emptyInstance) = try defaultExpressionParts(
            for: rawDefault,
            type: type,
            context: context
        )
        guard emptyInstance else {
            return .simple(expression: expression)
        }
        return .emptyInstance(expression: expression, members: rawDefault.objectValue ?? [:])
    }

    /// Chooses how the generated `init(from:)` decodes a property.
    ///
    /// Wire invariants win over forgiving annotations: a relative path or
    /// 0-based line must stay a decode-time error.
    ///
    /// - Parameters:
    ///   - fragment: The property's schema fragment.
    ///   - resolved: The property's resolved type.
    ///   - override: The wire-invariant newtype, if configured.
    ///   - isOptional: Whether the property is `Optional` in Swift.
    ///   - hasDefault: Whether the property carries a schema default.
    ///   - context: `Definition.field` for error messages.
    /// - Returns: The decode strategy.
    /// - Throws: `GeneratorError.unsupportedShape` when a forgiving
    ///   annotation cannot apply to the field's shape.
    private func decodeStrategy(
        of fragment: JSONValue,
        resolved: ResolvedType,
        override: GeneratorConfig.InvariantType?,
        isOptional: Bool,
        hasDefault: Bool,
        context: String
    ) throws -> DecodeStrategy {
        guard override == nil else {
            return .strict
        }
        if fragment[Self.skipInvalidItemsKey]?.boolValue == true {
            guard resolved.element != nil else {
                throw GeneratorError.unsupportedShape(
                    context: context,
                    detail: "\(Self.skipInvalidItemsKey) on a non-array field"
                )
            }
            return .forgivingArray
        }
        if fragment[Self.defaultOnErrorKey]?.boolValue == true {
            guard isOptional || hasDefault else {
                throw GeneratorError.unsupportedShape(
                    context: context,
                    detail: "\(Self.defaultOnErrorKey) on a required field with no default"
                )
            }
            return .forgivingScalar
        }
        return .strict
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
        fragment: JSONValue,
        override: GeneratorConfig.InvariantType?,
        context: String
    ) throws -> ResolvedType {
        let members = try objectMembers(of: fragment, context: context, subject: "fragment")
        if let composite = try resolveCompositeType(members: members, override: override, context: context) {
            return composite
        }

        var nullable = false
        let typeName: String
        switch members[Self.typeKey] {
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
        return try resolveScalarType(
            named: typeName,
            nullable: nullable,
            members: members,
            override: override,
            context: context
        )
    }

    /// Resolves a fragment's composite forms: `$ref`, `allOf`, `anyOf`, and
    /// `oneOf`.
    ///
    /// - Parameters:
    ///   - members: The fragment's object members.
    ///   - override: The wire-invariant newtype the scalar position maps to.
    ///   - context: `Definition.field` for error messages.
    /// - Returns: The resolved type, or `nil` when the fragment is not a
    ///   composite and scalar resolution should proceed.
    /// - Throws: `GeneratorError.unsupportedShape` for un-modelable
    ///   composites.
    private func resolveCompositeType(
        members: [String: JSONValue],
        override: GeneratorConfig.InvariantType?,
        context: String
    ) throws -> ResolvedType? {
        if let reference = members[Self.refKey]?.stringValue {
            return ResolvedType(base: try referencedTypeName(reference: reference, context: context), element: nil, nullable: false)
        }
        if let allOf = members[Self.allOfKey]?.arrayValue {
            guard allOf.count == 1 else {
                throw GeneratorError.unsupportedShape(context: context, detail: "\(Self.allOfKey) with \(allOf.count) entries")
            }
            return try resolveType(fragment: allOf[0], override: override, context: context)
        }
        if let anyOf = members[Self.anyOfKey]?.arrayValue {
            let nonNull = anyOf.filter { $0[Self.typeKey]?.stringValue != "null" }
            if anyOf.count == 2, nonNull.count == 1 {
                var inner = try resolveType(fragment: nonNull[0], override: override, context: context)
                inner.nullable = true
                return inner
            }
            if anyOf.count == 1 {
                return try resolveType(fragment: anyOf[0], override: override, context: context)
            }
            // Inline anonymous union — the tagged-union stage's seam.
            return ResolvedType(base: "JSONValue", element: nil, nullable: false)
        }
        if members[Self.oneOfKey] != nil {
            return ResolvedType(base: "JSONValue", element: nil, nullable: false)
        }
        return nil
    }

    /// Resolves a scalar or array `type` keyword to a Swift type.
    ///
    /// - Parameters:
    ///   - typeName: The JSON schema type keyword (e.g. `string`).
    ///   - nullable: Whether the wire value admits JSON `null`.
    ///   - members: The fragment's object members, for `items`.
    ///   - override: The wire-invariant newtype the scalar position maps to.
    ///   - context: `Definition.field` for error messages.
    /// - Returns: The resolved type.
    /// - Throws: `GeneratorError.unsupportedShape` for unknown keywords and
    ///   un-modelable arrays.
    /// The scalar JSON `type` keywords mapped to Swift types and the
    /// wire-invariant kind each may carry.
    ///
    /// `object` without a `$ref` is a free-form map (`additionalProperties`),
    /// so it maps to raw JSON.
    private static let scalarTypes: [String: (swiftName: String, allowedInvariant: GeneratorConfig.InvariantType?)] = [
        "string": ("String", .absolutePath),
        "integer": ("Int", .lineNumber),
        "boolean": ("Bool", nil),
        "number": ("Double", nil),
        "object": ("JSONValue", nil),
    ]

    private func resolveScalarType(
        named typeName: String,
        nullable: Bool,
        members: [String: JSONValue],
        override: GeneratorConfig.InvariantType?,
        context: String
    ) throws -> ResolvedType {
        if let scalar = Self.scalarTypes[typeName] {
            var base = scalar.swiftName
            if let allowed = scalar.allowedInvariant {
                base = try scalarName(plain: base, override: override, allowed: allowed, context: context)
            }
            return ResolvedType(base: base, element: nil, nullable: nullable)
        }
        guard typeName == "array" else {
            throw GeneratorError.unsupportedShape(context: context, detail: "unhandled scalar type \"\(typeName)\"")
        }
        guard let items = members["items"] else {
            throw GeneratorError.unsupportedShape(context: context, detail: "array without items")
        }
        let element = try resolveType(fragment: items, override: override, context: context)
        guard element.element == nil else {
            throw GeneratorError.unsupportedShape(context: context, detail: "nested arrays are not modeled")
        }
        return ResolvedType(base: "[\(element.base)]", element: element.base, nullable: nullable)
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
        plain: String,
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
    private func referencedTypeName(reference: String, context: String) throws -> String {
        let prefix = "#/\(Self.defsKey)/"
        guard reference.hasPrefix(prefix) else {
            throw GeneratorError.unsupportedShape(context: context, detail: "unsupported \(Self.refKey) \"\(reference)\"")
        }
        return emittedName(name: String(reference.dropFirst(prefix.count)))
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
            return (Emitter.stringLiteral(string), false)
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

    /// Verifies every `Type()` default is compilable and value-faithful.
    ///
    /// Each such default must target a generated struct whose memberwise
    /// initializer is fully defaulted, so the expression compiles and
    /// equals the schema's nested default object.
    ///
    /// - Parameter models: All generated struct models.
    /// - Throws: `GeneratorError.unsupportedShape` when a `Type()` default
    ///   points at a non-generated or not-fully-defaulted type, or when the
    ///   schema's default object diverges from the target's own defaults.
    private func validateEmptyInstanceDefaults(models: [StructModel]) throws {
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

    /// Verifies one `Type()` default against the target struct's defaults.
    ///
    /// The target must be a generated, fully-defaulted struct, and every
    /// member of the schema's default object must equal the target
    /// property's own default — recursing into nested object defaults. A
    /// divergence would make `Type()` silently encode the wrong value, so
    /// it fails generation instead.
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
        for (wireName, value) in Self.orderedEntries(of: members) {
            try validateDefaultMember(
                value: value,
                wireName: wireName,
                target: target,
                targetName: targetName,
                context: "\(context).\(wireName)",
                structsByName: structsByName
            )
        }
    }

    /// Verifies one member of a schema default object.
    ///
    /// The member must match a target property whose own default renders to
    /// the same expression, recursing into nested object defaults.
    ///
    /// - Parameters:
    ///   - value: The member's default value.
    ///   - wireName: The member's JSON name.
    ///   - target: The struct model the default constructs.
    ///   - targetName: The target's emitted name, for error messages.
    ///   - context: `Definition.field.member` for error messages.
    ///   - structsByName: All generated struct models by emitted name.
    /// - Throws: `GeneratorError.unsupportedShape` on any mismatch.
    private func validateDefaultMember(
        value: JSONValue,
        wireName: String,
        target: StructModel,
        targetName: String,
        context memberContext: String,
        structsByName: [String: StructModel]
    ) throws {
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
            return
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

// MARK: - Method-routing table

/// A parsed routing manifest (`meta.json` / `meta.unstable.json`).
///
/// The manifest carries three side groups, each mapping a snake_case
/// routing key to a wire method name.
private struct RoutingManifest {
    /// Routing groups keyed by side: routing key → wire method name.
    let methodsBySide: [MethodSide: [String: String]]
}

/// One `x-side`/`x-method` annotation target in the schema.
///
/// The (side, wire method) pair a definition belongs to.
private struct SchemaRoute: Hashable {
    /// The participant that serves the method.
    let side: MethodSide

    /// The method name as it crosses the wire.
    let wireMethod: String
}

extension SchemaGenerator {
    /// The manifest's routing groups in emission order, mapped to sides.
    private static let manifestGroups: [(key: String, side: MethodSide)] = [
        ("agentMethods", .agent),
        ("clientMethods", .client),
        ("protocolMethods", .protocolLevel),
    ]

    /// The only manifest layout revision this generator understands.
    private static let supportedManifestVersion = JSONValue.number(1)

    /// The manifest member naming its layout revision.
    private static let versionKey = "version"

    /// The schema annotation naming a routed definition's serving side.
    private static let sideAnnotationKey = "x-side"

    /// The schema annotation naming a routed definition's wire method.
    private static let methodAnnotationKey = "x-method"

    /// The definition-name suffix classifying a route's request shape.
    private static let requestSuffix = "Request"

    /// The definition-name suffix classifying a route's response shape.
    private static let responseSuffix = "Response"

    /// The definition-name suffix classifying a route's notification shape.
    private static let notificationSuffix = "Notification"

    /// The shape suffixes in match order.
    ///
    /// `Notification` is matched first so a name ending in it can never be
    /// misread as one of the shorter suffixes.
    private static let definitionSuffixes = [notificationSuffix, responseSuffix, requestSuffix]

    /// A side's position in emission order (agent, client, protocol).
    ///
    /// - Parameter side: The side to rank.
    /// - Returns: The side's emission rank.
    private static func rank(of side: MethodSide) -> Int {
        manifestGroups.firstIndex { $0.side == side } ?? manifestGroups.count
    }

    /// Collects the entries produced for each manifest side.
    ///
    /// - Parameter entries: Produces one side's entries.
    /// - Returns: All sides' entries: agent, then client, then protocol.
    /// - Throws: Rethrows the producer's error.
    private func collectBySide<Entry>(entries: (MethodSide) throws -> [Entry]) rethrows -> [Entry] {
        try Self.manifestGroups.flatMap { try entries($0.side) }
    }

    /// A routing group's entries ordered by wire method name.
    ///
    /// - Parameter group: The group's routing key → wire method map.
    /// - Returns: The entries sorted by wire method name.
    private static func orderedByWireMethod(of group: [String: String]) -> [(key: String, value: String)] {
        group.sorted { $0.value < $1.value }
    }

    /// A definition's `oneOf` variants, empty when absent.
    ///
    /// - Parameter fragment: The definition's schema fragment.
    /// - Returns: The variant fragments in schema order.
    private func unionVariants(of fragment: JSONValue) -> [JSONValue] {
        fragment[Self.oneOfKey]?.arrayValue ?? []
    }

    /// Builds the method-routing table file.
    ///
    /// Routing is derived from the routing manifests and the schema's
    /// `x-side`/`x-method` annotations.
    ///
    /// - Parameters:
    ///   - definitions: The schema's `$defs` object.
    ///   - metaJSON: The raw bytes of the stable routing manifest.
    ///   - unstableMetaJSON: The raw bytes of the unstable routing manifest;
    ///     when present, its methods beyond the stable manifest are emitted
    ///     into the `Unstable` namespace.
    /// - Returns: The rendered `MethodTable.generated.swift`.
    /// - Throws: `GeneratorError` when a manifest cannot be parsed or the
    ///   manifests disagree with the schema's annotations.
    private func methodTableFile(
        definitions: [String: JSONValue],
        metaJSON: Data,
        unstableMetaJSON: Data?
    ) throws -> GeneratedFile {
        let manifest = try parseRoutingManifest(data: metaJSON, context: "routing manifest")
        let stable = try stableMethodModels(manifest: manifest, routes: try schemaRoutes(from: definitions))
        var declarations = [Emitter.methodTableDeclaration(stable)]
        if let unstableMetaJSON {
            let unstableManifest = try parseRoutingManifest(
                data: unstableMetaJSON,
                context: "unstable routing manifest"
            )
            declarations.append(
                Emitter.unstableNamespaceDeclaration(
                    try unstableMethodModels(stable: manifest, unstable: unstableManifest)
                )
            )
        }
        return GeneratedFile(
            name: "MethodTable.generated.swift",
            contents: Emitter.file(declarations: declarations)
        )
    }

    /// Parses and validates a routing manifest document.
    ///
    /// The manifest must be a version-1 object carrying exactly the three
    /// known routing groups; an unknown group or version fails loudly rather
    /// than silently dropping routes.
    ///
    /// - Parameters:
    ///   - data: The raw manifest bytes.
    ///   - context: Which manifest, for error messages.
    /// - Returns: The parsed manifest.
    /// - Throws: `GeneratorError.invalidSchema` for any shape deviation.
    private func parseRoutingManifest(data: Data, context: String) throws -> RoutingManifest {
        let manifest = try decodeJSON(data: data, context: context)
        guard let members = manifest.objectValue else {
            throw GeneratorError.invalidSchema("\(context) is not a JSON object")
        }
        guard members[Self.versionKey] == Self.supportedManifestVersion else {
            throw GeneratorError.invalidSchema("\(context) does not declare supported version 1")
        }
        let knownKeys = Set(Self.manifestGroups.map(\.key) + [Self.versionKey])
        for key in members.keys.sorted() where !knownKeys.contains(key) {
            throw GeneratorError.invalidSchema("\(context) has unknown member \"\(key)\"")
        }

        var methodsBySide: [MethodSide: [String: String]] = [:]
        for (key, side) in Self.manifestGroups {
            guard let group = members[key]?.objectValue else {
                throw GeneratorError.invalidSchema("\(context) is missing routing group \"\(key)\"")
            }
            methodsBySide[side] = try parseRoutingGroup(group: group, key: key, context: context)
        }
        return RoutingManifest(methodsBySide: methodsBySide)
    }

    /// Parses one routing group's members.
    ///
    /// - Parameters:
    ///   - group: The group's JSON members.
    ///   - key: The group's manifest key, for error messages.
    ///   - context: Which manifest, for error messages.
    /// - Returns: Routing key → wire method name.
    /// - Throws: `GeneratorError.invalidSchema` on a non-string value or a
    ///   wire method routed twice.
    private func parseRoutingGroup(
        group: [String: JSONValue],
        key: String,
        context: String
    ) throws -> [String: String] {
        var methods: [String: String] = [:]
        var seenWires = Set<String>()
        for (routingKey, value) in Self.orderedEntries(of: group) {
            guard let wireMethod = value.stringValue else {
                throw GeneratorError.invalidSchema("\(context) member \(key).\(routingKey) is not a string")
            }
            guard seenWires.insert(wireMethod).inserted else {
                throw GeneratorError.invalidSchema("\(context) routes \"\(wireMethod)\" twice in \(key)")
            }
            methods[routingKey] = wireMethod
        }
        return methods
    }

    /// Indexes the schema's `x-side`/`x-method` annotations.
    ///
    /// - Parameter definitions: The schema's `$defs` object.
    /// - Returns: Each annotated (side, method) route mapped to its
    ///   definition names, in name order.
    /// - Throws: `GeneratorError.unsupportedShape` when a definition carries
    ///   only one of the two annotations or an unknown side.
    private func schemaRoutes(from definitions: [String: JSONValue]) throws -> [SchemaRoute: [String]] {
        var routes: [SchemaRoute: [String]] = [:]
        for (name, fragment) in Self.orderedEntries(of: definitions) {
            let sideValue = fragment[Self.sideAnnotationKey]?.stringValue
            let methodValue = fragment[Self.methodAnnotationKey]?.stringValue
            if sideValue == nil, methodValue == nil {
                continue
            }
            guard let sideValue, let methodValue else {
                throw GeneratorError.unsupportedShape(
                    context: name,
                    detail: "\(Self.sideAnnotationKey) and \(Self.methodAnnotationKey) must appear together"
                )
            }
            guard let side = MethodSide(rawValue: sideValue) else {
                throw GeneratorError.unsupportedShape(
                    context: name,
                    detail: "unknown \(Self.sideAnnotationKey) \"\(sideValue)\""
                )
            }
            routes[SchemaRoute(side: side, wireMethod: methodValue), default: []].append(name)
        }
        return routes
    }

    /// Builds the stable routing-table entries.
    ///
    /// Cross-validates the manifest against the schema's annotations in
    /// both directions: every manifest route must resolve to schema
    /// definitions and every annotated definition must be routed by the
    /// manifest — the double-entry check that makes hand-miswiring
    /// structurally impossible.
    ///
    /// - Parameters:
    ///   - manifest: The parsed stable routing manifest.
    ///   - routes: The schema's annotation index from `schemaRoutes`.
    /// - Returns: Entries ordered agent, client, protocol, then by wire
    ///   method name within each side.
    /// - Throws: `GeneratorError` on any manifest/schema disagreement,
    ///   duplicate handler name, or stale deprecation config entry.
    private func stableMethodModels(
        manifest: RoutingManifest,
        routes: [SchemaRoute: [String]]
    ) throws -> [MethodModel] {
        var consumed = Set<SchemaRoute>()
        let models = try collectBySide { (side: MethodSide) -> [MethodModel] in
            let group = manifest.methodsBySide[side] ?? [:]
            var handlerNames = Set<String>()
            var sideModels: [MethodModel] = []
            for (routingKey, wireMethod) in Self.orderedByWireMethod(of: group) {
                let route = SchemaRoute(side: side, wireMethod: wireMethod)
                guard let definitionNames = routes[route] else {
                    throw GeneratorError.invalidSchema(
                        "manifest routes \"\(wireMethod)\" on the \(side.rawValue) side but the schema defines no types for it"
                    )
                }
                consumed.insert(route)
                let model = try methodModel(
                    routingKey: routingKey,
                    wireMethod: wireMethod,
                    side: side,
                    definitionNames: definitionNames
                )
                try registerHandlerName(handlerName: model.handlerName, side: side, in: &handlerNames, label: "handler")
                sideModels.append(model)
            }
            return sideModels
        }

        let unrouted = routes.keys
            .filter { !consumed.contains($0) }
            .sorted { (Self.rank(of: $0.side), $0.wireMethod) < (Self.rank(of: $1.side), $1.wireMethod) }
        if let first = unrouted.first {
            throw GeneratorError.invalidSchema(
                "schema annotates \"\(first.wireMethod)\" on the \(first.side.rawValue) side but the manifest does not route it"
            )
        }

        let wireMethods = Set(models.map(\.wireMethod))
        for wireMethod in config.deprecatedMethods.keys.sorted() where !wireMethods.contains(wireMethod) {
            throw GeneratorError.invalidSchema(
                "deprecation config names \"\(wireMethod)\", which is not a routed method"
            )
        }
        return models
    }

    /// Builds one stable entry from a route's schema definitions.
    ///
    /// A `*Request`/`*Response` pair is a request whose handler is the pair's
    /// shared base name (`NewSessionRequest` → `newSession`); a single
    /// `*Notification` is a notification whose handler is the manifest
    /// routing key camelCased (`session_update` → `sessionUpdate`).
    ///
    /// - Parameters:
    ///   - routingKey: The manifest's snake_case routing key.
    ///   - wireMethod: The wire method name.
    ///   - side: The serving participant.
    ///   - definitionNames: The schema definitions annotated with this route.
    /// - Returns: The routing-table entry model.
    /// - Throws: `GeneratorError.unsupportedShape` when the definitions form
    ///   neither shape or a name yields no plain Swift identifier.
    private func methodModel(
        routingKey: String,
        wireMethod: String,
        side: MethodSide,
        definitionNames: [String]
    ) throws -> MethodModel {
        let context = "method \(wireMethod)"
        var definitionsBySuffix: [String: [String]] = [:]
        for name in definitionNames.sorted() {
            guard let suffix = Self.definitionSuffixes.first(where: { name.hasSuffix($0) }) else {
                throw GeneratorError.unsupportedShape(
                    context: context,
                    detail: "definition \(name) is neither a \(Self.requestSuffix), a \(Self.responseSuffix), nor a \(Self.notificationSuffix)"
                )
            }
            definitionsBySuffix[suffix, default: []].append(name)
        }
        let requests = definitionsBySuffix[Self.requestSuffix] ?? []
        let responses = definitionsBySuffix[Self.responseSuffix] ?? []
        let notifications = definitionsBySuffix[Self.notificationSuffix] ?? []
        let deprecationMessage = config.deprecatedMethods[wireMethod]
        if requests.count == 1, responses.count == 1, notifications.isEmpty {
            let base = String(requests[0].dropLast(Self.requestSuffix.count))
            return MethodModel(
                wireMethod: wireMethod,
                handlerName: try swiftCaseName(fromWire: lowerFirst(name: base), context: context),
                side: side,
                kind: .request,
                paramsTypeName: emittedName(name: requests[0]),
                resultTypeName: emittedName(name: responses[0]),
                deprecationMessage: deprecationMessage
            )
        }
        if notifications.count == 1, requests.isEmpty, responses.isEmpty {
            return MethodModel(
                wireMethod: wireMethod,
                handlerName: try swiftCaseName(fromWire: routingKey, context: context),
                side: side,
                kind: .notification,
                paramsTypeName: emittedName(name: notifications[0]),
                resultTypeName: nil,
                deprecationMessage: deprecationMessage
            )
        }
        throw GeneratorError.unsupportedShape(
            context: context,
            detail: "definitions [\(definitionNames.sorted().joined(separator: ", "))] form neither a \(Self.requestSuffix)/\(Self.responseSuffix) pair nor a single \(Self.notificationSuffix)"
        )
    }

    /// Builds the `Unstable` namespace entries.
    ///
    /// These are the methods the unstable manifest routes beyond the stable
    /// manifest, per side. The vendored stable schema defines no types for
    /// them, so entries carry names and side only, with handlers camelCased
    /// from the manifest routing keys.
    ///
    /// - Parameters:
    ///   - stable: The parsed stable routing manifest.
    ///   - unstable: The parsed unstable routing manifest.
    /// - Returns: Entries ordered agent, client, protocol, then by wire
    ///   method name within each side.
    /// - Throws: `GeneratorError` on a routing key that yields no plain
    ///   Swift identifier or a duplicate handler name within a side.
    private func unstableMethodModels(
        stable: RoutingManifest,
        unstable: RoutingManifest
    ) throws -> [UnstableMethodModel] {
        try collectBySide { (side: MethodSide) -> [UnstableMethodModel] in
            let stableWires = Set((stable.methodsBySide[side] ?? [:]).values)
            let group = unstable.methodsBySide[side] ?? [:]
            var handlerNames = Set<String>()
            var sideModels: [UnstableMethodModel] = []
            for (routingKey, wireMethod) in Self.orderedByWireMethod(of: group)
            where !stableWires.contains(wireMethod) {
                let handlerName = try swiftCaseName(
                    fromWire: routingKey,
                    context: "unstable method \(wireMethod)"
                )
                try registerHandlerName(handlerName: handlerName, side: side, in: &handlerNames, label: "unstable handler")
                sideModels.append(
                    UnstableMethodModel(wireMethod: wireMethod, handlerName: handlerName, side: side)
                )
            }
            return sideModels
        }
    }

    /// Records a handler name in a side's seen-set, failing on a collision.
    ///
    /// Both the stable and unstable builders route through this single
    /// check, so the uniqueness rule cannot drift between the two tables.
    ///
    /// - Parameters:
    ///   - handlerName: The derived handler name to register.
    ///   - side: The side the handler serves, for the error message.
    ///   - seen: The side's already-registered handler names.
    ///   - label: The table being built (`handler` / `unstable handler`),
    ///     for the error message.
    /// - Throws: `GeneratorError.invalidSchema` when the name is taken.
    private func registerHandlerName(
        handlerName: String,
        side: MethodSide,
        in seen: inout Set<String>,
        label: String
    ) throws {
        guard seen.insert(handlerName).inserted else {
            throw GeneratorError.invalidSchema(
                "duplicate \(label) name \(handlerName) on the \(side.rawValue) side"
            )
        }
    }

    /// Lowercases a type name's leading character to form a handler name.
    ///
    /// - Parameter name: The Pascal-case base name (e.g. `NewSession`).
    /// - Returns: The lower-camel form (e.g. `newSession`).
    private func lowerFirst(name: String) -> String {
        guard let first = name.first else { return name }
        return first.lowercased() + name.dropFirst()
    }
}

extension Emitter {
    /// Maps a side to the emitted `MethodSide` case reference.
    ///
    /// `MethodSide` carries no associated values, so reflecting a value
    /// yields exactly its case name — the emitted member reference tracks
    /// the enum with no per-case mapping to keep in sync.
    ///
    /// - Parameter side: The side to render.
    /// - Returns: The Swift member-access expression (e.g. `.agent`).
    private static func sideCase(_ side: MethodSide) -> String {
        ".\(String(describing: side))"
    }

    /// Assembles a rendered table declaration.
    ///
    /// Both routing tables share this builder: header lines, one line block
    /// per entry, footer lines, joined into one declaration.
    ///
    /// - Parameters:
    ///   - header: The doc comment and opening lines.
    ///   - entries: The entries to render, in emission order.
    ///   - entryLines: Produces one entry's rendered lines.
    ///   - footer: The closing lines.
    /// - Returns: The joined declaration text.
    private static func tableDeclaration<Entry>(
        header: [String],
        entries: [Entry],
        entryLines: (Entry) -> [String],
        footer: [String]
    ) -> String {
        (header + entries.flatMap(entryLines) + footer).joined(separator: "\n")
    }

    /// Renders the stable method-routing table.
    ///
    /// - Parameter methods: The entries in emission order.
    /// - Returns: The rendered `ACPMethodTable` declaration.
    fileprivate static func methodTableDeclaration(_ methods: [MethodModel]) -> String {
        tableDeclaration(
            header: [
                "/// The method-routing table for the stable ACP v1 surface.",
                "///",
                "/// Derived from the vendored `meta.json` routing manifest and the schema's",
                "/// `x-side`/`x-method` annotations — never hand-wired.",
                "public enum ACPMethodTable {",
                "    /// Every stable method, ordered agent, client, protocol and by wire",
                "    /// method name within each side.",
                "    public static let methods: [MethodInfo] = [",
            ],
            entries: methods,
            entryLines: { method in
                [
                    "        MethodInfo(",
                    "            wireMethod: \(stringLiteral(method.wireMethod)),",
                    "            handlerName: \(stringLiteral(method.handlerName)),",
                    "            side: \(sideCase(method.side)),",
                    "            kind: .\(method.kind.rawValue),",
                    "            paramsTypeName: \(stringLiteral(method.paramsTypeName)),",
                    "            resultTypeName: \(method.resultTypeName.map(stringLiteral) ?? "nil"),",
                    "            deprecationMessage: \(method.deprecationMessage.map(stringLiteral) ?? "nil")",
                    "        ),",
                ]
            },
            footer: ["    ]", "}"]
        )
    }

    /// Renders the `Unstable` namespace and its method table.
    ///
    /// - Parameter methods: The unstable-only entries in emission order.
    /// - Returns: The rendered `Unstable` declaration.
    fileprivate static func unstableNamespaceDeclaration(_ methods: [UnstableMethodModel]) -> String {
        tableDeclaration(
            header: [
                "/// Protocol surface upstream ACP has not stabilized.",
                "///",
                "/// Everything in this namespace is unsettled — wire names and shapes can",
                "/// change between releases — so callers must gate use behind explicitly",
                "/// negotiated capabilities, never protocol version alone.",
                "public enum Unstable {",
                "    /// Methods routed only by the vendored `meta.unstable.json` manifest.",
                "    ///",
                "    /// The vendored stable schema defines no parameter or result types for",
                "    /// them, so entries carry names and side only.",
                "    public enum MethodTable {",
                "        /// Every unstable-only method, ordered agent, client, protocol and",
                "        /// by wire method name within each side.",
                "        public static let methods: [UnstableMethodInfo] = [",
            ],
            entries: methods,
            entryLines: { method in
                [
                    "            UnstableMethodInfo(",
                    "                wireMethod: \(stringLiteral(method.wireMethod)),",
                    "                handlerName: \(stringLiteral(method.handlerName)),",
                    "                side: \(sideCase(method.side))",
                    "            ),",
                ]
            },
            footer: ["        ]", "    }", "}"]
        )
    }
}
