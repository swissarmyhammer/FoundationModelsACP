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
    ///   ACP v2 schema's configuration.
    public init(config: GeneratorConfig = .acpV2) {
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
    ///   - namespace: An enclosing namespace enum to nest every emitted type
    ///     in, and a prefix on every generated file name; `nil` emits the
    ///     types at the top level (the layout for the primary schema set).
    /// - Returns: The generated Swift files.
    /// - Throws: `GeneratorError` when an input cannot be parsed, the schema
    ///   contains a shape the generator does not understand, or the routing
    ///   manifests disagree with the schema's `x-side`/`x-method`
    ///   annotations.
    public func generate(
        schemaJSON: Data,
        metaJSON: Data? = nil,
        unstableMetaJSON: Data? = nil,
        namespace: String? = nil
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
        try validatePatchSemanticsFields(definitions: definitions)

        var identifiers: [String] = []
        var structModels: [StructModel] = []
        var modelDeclarations: [String] = []
        var unions: [String] = []
        var placeholders: [String] = []

        for (name, fragment) in Self.orderedEntries(of: definitions) {
            let documentation = description(of: fragment)
            switch try classify(name: name, fragment: fragment) {
            case .handwritten:
                continue
            case .stringIdentifier:
                identifiers.append(
                    Emitter.identifierNewtype(name: emittedName(name: name), documentation: documentation)
                )
            case .scalarEnum(let rawKind):
                unions.append(
                    Emitter.scalarEnumDeclaration(model: try scalarEnumModel(name: name, rawKind: rawKind, fragment: fragment))
                )
            case .taggedUnion:
                unions.append(
                    Emitter.taggedUnionDeclaration(model: try taggedUnionModel(name: name, fragment: fragment))
                )
            case .discriminatedUnion:
                unions.append(
                    Emitter.discriminatedUnionDeclaration(model: try discriminatedUnionModel(name: name, fragment: fragment))
                )
            case .objectValueUnion:
                let model = try objectValueUnionModel(name: name, fragment: fragment)
                structModels.append(model.base)
                modelDeclarations.append(Emitter.objectValueUnionDeclaration(model: model))
            case .objectTaggedUnion:
                let model = try objectTaggedUnionModel(name: name, fragment: fragment)
                structModels.append(model.base)
                modelDeclarations.append(Emitter.objectTaggedUnionDeclaration(model: model))
            case .deferredUnion(let keyword):
                placeholders.append(
                    Emitter.placeholder(
                        name: emittedName(name: name),
                        reason: deferredUnionReason(keyword: keyword, fragment: fragment),
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
                let model = try structModel(name: name, fragment: fragment)
                structModels.append(model)
                modelDeclarations.append(Emitter.structDeclaration(model: model))
            }
        }

        try validateEmptyInstanceDefaults(models: structModels)

        var files = [
            GeneratedFile(
                name: "Identifiers.generated.swift",
                contents: Emitter.file(declarations: identifiers, namespace: namespace)
            ),
            GeneratedFile(
                name: "Models.generated.swift",
                contents: Emitter.file(declarations: modelDeclarations, namespace: namespace)
            ),
            GeneratedFile(
                name: "Unions.generated.swift",
                contents: Emitter.file(declarations: unions, namespace: namespace)
            ),
            GeneratedFile(
                name: "Unresolved.generated.swift",
                contents: Emitter.file(declarations: placeholders, namespace: namespace)
            ),
        ]
        if let metaJSON {
            files.append(
                try methodTableFile(
                    definitions: definitions,
                    metaJSON: metaJSON,
                    unstableMetaJSON: unstableMetaJSON,
                    namespace: namespace
                )
            )
        }
        guard let namespace else {
            return files
        }
        return files.map { file in
            GeneratedFile(name: "\(namespace).\(file.name)", contents: file.contents)
        }
    }

    // MARK: - Schema keywords

    /// The schema keyword holding the document's definitions.
    private static let defsKey = "$defs"

    /// The schema keyword referencing another definition.
    private static let refKey = "$ref"

    /// The schema keyword naming a fragment's JSON type.
    private static let typeKey = "type"

    /// The JSON Schema `type` value for an object fragment.
    private static let objectTypeName = "object"

    /// The JSON Schema `type` value for a string fragment.
    private static let stringTypeName = "string"

    /// The JSON Schema `type` value for an integer fragment.
    private static let integerTypeName = "integer"

    /// The JSON Schema `type` value for JSON's null.
    private static let nullTypeName = "null"

    /// The JSON Schema `type` value for a boolean fragment.
    private static let booleanTypeName = "boolean"

    /// The JSON Schema `type` value for a number fragment.
    private static let numberTypeName = "number"

    /// The JSON Schema `type` value for an array fragment.
    private static let arrayTypeName = "array"

    /// The `anyOf` arity of the nullable-type pattern (`T | null`): one
    /// concrete variant alongside a `null` variant. Used by
    /// `resolveCompositeType` to recognize a two-entry `anyOf` as sugar for a
    /// nullable `T` rather than a genuine union.
    private static let nullableAnyOfVariantCount = 2

    /// The schema keyword for exclusive unions.
    private static let oneOfKey = "oneOf"

    /// The error detail for a union with no variants.
    ///
    /// Shared by `classifyOneOf`'s empty-`oneOf` check, `classifyAnyOf`'s
    /// empty-`anyOf` check and its object-branch empty-after-catch-all-
    /// filtering check (both routed through `validateNonEmptyUnion`), and by
    /// `taggedUnionModel`'s and `objectValueUnionModel`'s own
    /// empty-after-filtering guards, which a `oneOf` *or* an `anyOf` can
    /// reach — so the wording names neither keyword specifically.
    private static let emptyUnionDetail = "empty union"

    /// The schema keyword for inclusive unions.
    private static let anyOfKey = "anyOf"

    /// The schema keyword for intersections (single-ref wrappers here).
    private static let allOfKey = "allOf"

    /// The schema keyword negating a subschema, used by a union's explicit
    /// unknown-discriminator variant to exclude every known tag.
    private static let notKey = "not"

    /// The schema keyword for closed value sets.
    private static let enumKey = "enum"

    /// The schema keyword carrying a fragment's documentation.
    private static let descriptionKey = "description"

    /// The schema keyword pinning a member to a single value.
    private static let constKey = "const"

    /// The schema keyword naming a variant, used to name a discriminator-less
    /// default union case.
    private static let titleKey = "title"

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
        if members[Self.anyOfKey] != nil {
            guard let variants = members[Self.anyOfKey]?.arrayValue else {
                throw GeneratorError.unsupportedShape(context: name, detail: "\(Self.anyOfKey) is not an array")
            }
            return try classifyAnyOf(name: name, members: members, variants: variants)
        }
        if members[Self.enumKey] != nil {
            return .deferredUnion(keyword: Self.enumKey)
        }
        switch members[Self.typeKey]?.stringValue {
        case Self.objectTypeName:
            return .objectStruct
        case Self.stringTypeName:
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

    /// The placeholder banner explaining why a `.deferredUnion` definition
    /// stays raw JSON instead of a typed declaration.
    ///
    /// Every `\(keyword)` union the vendored schema currently defers to this
    /// seam has no variant that pins any discriminator at all — nothing a
    /// Swift enum could key on — so for those the deferral is permanent: only
    /// a re-vendor that adds a discriminator could change it, not a future
    /// revision of this generator. The wording says so plainly rather than
    /// promising work already scheduled.
    ///
    /// `classifyAnyOf`'s fallback and mixed-shape branches can in principle
    /// also land a definition here for a union whose variants *do* pin a
    /// discriminator but conflict in a way the generator declines to
    /// resolve. That shape is unreached today (see `isUnknownFallbackVariant`
    /// and `classifyAnyOf`), so it gets its own wording rather than
    /// borrowing the "no discriminator" claim, which would not be true of it.
    ///
    /// - Parameters:
    ///   - keyword: The schema keyword (`oneOf`, `anyOf`, or `enum`) that
    ///     produced the deferral.
    ///   - fragment: The definition's schema fragment.
    /// - Returns: The banner text for the generated placeholder typealias.
    private func deferredUnionReason(keyword: String, fragment: JSONValue) -> String {
        guard declaredUnionVariants(of: fragment).contains(where: hasConstDiscriminator) else {
            return "Permanently deferred: no variant of this `\(keyword)` union pins a discriminator, so there is nothing to key a Swift enum on; raw JSON is its representation."
        }
        return "Deferred: this `\(keyword)` union's variants pin discriminators the generator cannot reconcile into one Swift enum; raw JSON is its representation."
    }

    /// Maps a schema definition name to its emitted Swift type name.
    ///
    /// - Parameter name: The schema definition name.
    /// - Returns: The renamed Swift type name, or the name unchanged.
    private func emittedName(name: String) -> String {
        applyKnownAcronymCasing(to: config.typeRenames[name] ?? name)
    }

    /// Uppercases every PascalCase word of `name` that matches a
    /// `GeneratorConfig.knownAcronyms` entry, case-insensitively.
    ///
    /// Splits at each capital-letter boundary, so `McpServerHttp` becomes the
    /// words `Mcp`, `Server`, `Http`; a word whose uppercased form is a known
    /// acronym (`MCP`, `HTTP`) is replaced by that all-caps form, and every
    /// other word — including one that is already all-caps, such as an
    /// earlier `typeRenames` result — passes through unchanged.
    ///
    /// - Parameter to: A PascalCase Swift type name.
    /// - Returns: `name` with every recognized acronym word uppercased.
    private func applyKnownAcronymCasing(to name: String) -> String {
        guard !config.knownAcronyms.isEmpty else { return name }
        let acronyms = Set(config.knownAcronyms.map { $0.uppercased() })
        var words: [String] = []
        var word = ""
        for character in name {
            if character.isUppercase, !word.isEmpty {
                words.append(word)
                word = ""
            }
            word.append(character)
        }
        if !word.isEmpty { words.append(word) }
        return words.map { acronyms.contains($0.uppercased()) ? $0.uppercased() : $0 }.joined()
    }

    /// A schema fragment's `description`, acronym-cased the same way
    /// `emittedName` cases an identifier.
    ///
    /// A description can quote a renamed definition by its original schema
    /// spelling (`McpServer::Http`), and that quote goes stale the moment the
    /// definition's own emitted name picks up `knownAcronyms` casing
    /// (`MCPServer::HTTP`) while the doc comment does not. Every call site
    /// that used to read a fragment's `description` directly now routes
    /// through here instead, so a doc comment can never fall behind the
    /// identifiers it quotes.
    ///
    /// - Parameter of: The schema fragment carrying the description.
    /// - Returns: The description text with acronyms cased, or `nil` when
    ///   the fragment has none.
    private func description(of fragment: JSONValue) -> String? {
        fragment[Self.descriptionKey]?.stringValue.map(applyKnownAcronymCasingToProse)
    }

    /// Applies `applyKnownAcronymCasing` to every capitalized identifier-like
    /// word in free text, rather than to one whole PascalCase type name.
    ///
    /// A description's quoted reference to a renamed type does not occupy
    /// the whole string (`Agent supports [\`McpServer::Http\`].`), so each
    /// maximal run of letters and digits is cased independently and every
    /// other character — spaces, backticks, brackets, `::` — passes through
    /// unchanged. Only a word starting with an uppercase letter is a
    /// candidate: the schema also quotes lowercase, dotted wire-member paths
    /// like `session.mcp.http`, and those name actual JSON keys rather than
    /// a renamed type, so they must not pick up the type-name casing.
    ///
    /// - Parameter text: The free-form documentation text.
    /// - Returns: `text` with every recognized acronym word capitalized as a
    ///   type name, wherever it already reads as one.
    private func applyKnownAcronymCasingToProse(_ text: String) -> String {
        guard !config.knownAcronyms.isEmpty else { return text }
        var result = ""
        var word = ""
        func flushWord() {
            guard !word.isEmpty else { return }
            result += word.first?.isUppercase == true ? applyKnownAcronymCasing(to: word) : word
            word = ""
        }
        for character in text {
            if character.isLetter || character.isNumber {
                word.append(character)
            } else {
                flushWord()
                result.append(character)
            }
        }
        flushWord()
        return result
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
    /// - Parameter of: The map to order.
    /// - Returns: The entries sorted by key.
    private static func orderedEntries<Value>(of members: [String: Value]) -> [(key: String, value: Value)] {
        members.sorted { $0.key < $1.key }
    }

    /// Unwraps a fragment's object members, failing loudly otherwise.
    ///
    /// - Parameters:
    ///   - of: The schema fragment.
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

    /// Validates that a candidate variant list is non-empty, throwing the
    /// shared `emptyUnionDetail` error otherwise.
    ///
    /// Shared by `classifyOneOf` and `classifyAnyOf`, each of which calls
    /// this twice: once on the raw `variants` list, guarding against a
    /// literally empty `oneOf`/`anyOf`; and again — after confirming any
    /// `not`-guarded fallback is a genuine catch-all — on `modeled`, the
    /// subset left once those catch-alls are filtered out, guarding against
    /// a union whose every variant turned out to be one, which would
    /// otherwise still classify as `.taggedUnion`/`.objectTaggedUnion` with
    /// no real payload variant at all. The two `variants` call sites already
    /// shared this helper; the two `modeled` call sites previously
    /// duplicated this same three-line check inline and are extracted here
    /// too, so the condition and thrown error can only drift in one place.
    ///
    /// - Parameters:
    ///   - variants: The candidate variant list — either the union's raw
    ///     variants, or the modeled (non-`not`-guarded) subset of them.
    ///   - name: The definition's schema name, for the thrown error's
    ///     context.
    /// - Throws: `GeneratorError.unsupportedShape` when `variants` is empty,
    ///   so an empty or vacuously-catch-all-only union fails loudly instead
    ///   of silently deferring to raw JSON.
    private func validateNonEmptyUnion(_ variants: [JSONValue], name: String) throws {
        guard !variants.isEmpty else {
            throw GeneratorError.unsupportedShape(context: name, detail: Self.emptyUnionDetail)
        }
    }

    /// Distinguishes the two `oneOf` families this stage emits from a `oneOf`
    /// this stage declines to model.
    ///
    /// - Parameters:
    ///   - name: The definition's schema name.
    ///   - variants: The `oneOf` entries.
    /// - Returns: `.scalarEnum` when every variant is a constant of one scalar
    ///   type, `.taggedUnion` when every variant is a discriminated object
    ///   and any `not`-guarded fallback is the genuine unknown-discriminator
    ///   catch-all, `.deferredUnion` when a fallback instead pins a `const`
    ///   of its own — see `isUnknownFallbackVariant`.
    /// - Throws: `GeneratorError.unsupportedShape` for an empty or
    ///   mixed-shape `oneOf`, so unknown constructs fail loudly. Also thrown
    ///   when every variant is a `not`-guarded catch-all: `modeled` is then
    ///   empty, and without this check classification would still return
    ///   `.taggedUnion` for a union with no real payload variant at all,
    ///   mirroring `classifyAnyOf`'s object-branch check.
    private func classifyOneOf(name: String, variants: [JSONValue]) throws -> DefinitionKind {
        try validateNonEmptyUnion(variants, name: name)
        if let rawKind = Self.agreedEnumRawKind(of: variants) {
            return .scalarEnum(rawKind)
        }
        guard variants.allSatisfy({ $0[Self.typeKey]?.stringValue == Self.objectTypeName }) else {
            throw GeneratorError.unsupportedShape(
                context: name,
                detail: "\(Self.oneOfKey) mixes variant shapes; expected all scalar consts or all discriminated objects"
            )
        }
        // Mirrors `classifyAnyOf`'s fallback guard: a `not`-guarded variant
        // that also pins a `const` of its own contradicts the `not` beside
        // it and is the union's own evidence for which member the
        // discriminator is, not a catch-all. Without this guard it would
        // survive `unionVariants(of:)` unfiltered and reach
        // `discriminatorTag`, yielding an extra case or a thrown
        // `unsupportedShape` instead of the documented deferral.
        guard fallbacksAreGenuineCatchAlls(of: variants) else {
            return .deferredUnion(keyword: Self.oneOfKey)
        }
        let modeled = variants.filter { $0[Self.notKey] == nil }
        // Symmetric with `classifyAnyOf`'s object-branch call to
        // `validateNonEmptyUnion(modeled, name:)`: when every variant is
        // `not`-guarded, `modeled` is empty. Without this check,
        // classification would still return `.taggedUnion` for a union with
        // no real payload variant at all, and only `taggedUnionModel`'s own
        // filtered-to-empty `guard let discriminator else` would catch it —
        // the same `emptyUnionDetail` error, reached less directly. Unlike
        // the `anyOf` object branch (whose `.objectTaggedUnion` path calls
        // `structModel` before ever re-deriving the union, so bypassing its
        // check can surface an unrelated, misleading error first),
        // `.taggedUnion` maps straight to `taggedUnionModel` with no other
        // processing in between: that function's own guard throws this
        // identical `context`/`detail` pair regardless, so this check cannot
        // be pinned by an externally observable "wrong error" test the way
        // the `anyOf` fix could — it is a directness/proximate-cause
        // improvement only, confirmed by mutation testing.
        try validateNonEmptyUnion(modeled, name: name)
        return .taggedUnion
    }

    /// The JSON `type` keywords a constant union may be built from, and the
    /// enum raw kind each emits.
    ///
    /// Naming them in one table is what keeps `ErrorCode`'s integer constants
    /// and the protocol's string vocabularies on a single emission path
    /// instead of two that must be kept in step.
    private static let enumRawKinds: [String: EnumRawKind] = [
        Self.stringTypeName: .string,
        Self.integerTypeName: .integer,
    ]

    /// The raw kind a union's variants agree on, when every variant is a
    /// constant of one scalar JSON type.
    ///
    /// - Parameter of: The union's variant fragments.
    /// - Returns: The shared raw kind, or `nil` when the variants disagree,
    ///   name a type no enum is emitted for, or there are none.
    private static func agreedEnumRawKind(of variants: [JSONValue]) -> EnumRawKind? {
        let kinds = variants.map { variant in
            variant[Self.typeKey]?.stringValue.flatMap { Self.enumRawKinds[$0] }
        }
        guard let first = kinds.first, let rawKind = first, kinds.allSatisfy({ $0 == rawKind }) else {
            return nil
        }
        return rawKind
    }

    /// Distinguishes the `anyOf` families this stage emits from those still
    /// deferred to a later stage.
    ///
    /// - Parameters:
    ///   - name: The definition's schema name.
    ///   - members: The definition's object members.
    ///   - variants: The `anyOf` entries.
    /// - Returns: `.scalarEnum` for a set of scalar constants, `.taggedUnion`
    ///   for a discriminated union with an explicit unknown variant,
    ///   `.objectValueUnion` for an object that also carries a value union,
    ///   `.discriminatedUnion` for a discriminated `$ref`-payload union with a
    ///   default variant, or `.deferredUnion` for every other `anyOf`.
    ///
    /// A union carrying an explicit unknown-discriminator variant is a tagged
    /// union: that variant replaces the discriminator-less default a
    /// `.discriminatedUnion` requires, and every family here has a fallback
    /// that carries both the unrecognized tag and the raw payload beside it,
    /// so nothing the catch-all declares is dropped by modeling the union.
    ///
    /// What still defers is a `not` variant that pins a `const` of its own:
    /// it contradicts the `not` beside it and is the union's own evidence for
    /// which member the discriminator is, so it is not a catch-all at all.
    /// See `isUnknownFallbackVariant`.
    ///
    /// An object that also carries a union is the `.objectValueUnion` shape
    /// when its variants differ by an inline `value` member, and the
    /// `.objectTaggedUnion` shape when they flatten `$ref` payloads instead.
    /// Mixing the two in one union has no emission model, so it defers.
    ///
    /// - Throws: `GeneratorError.unsupportedShape` for an empty `anyOf`,
    ///   mirroring `classifyOneOf`'s empty-`oneOf` guard: an empty union of
    ///   either keyword permits nothing, so silently deferring it to raw
    ///   JSON would hide the same authoring error a thrown error catches for
    ///   `oneOf`. Also thrown for an object-typed `anyOf` whose variants are
    ///   all `not`-guarded catch-alls: `modeled` is then empty, and without
    ///   this guard `modeled.allSatisfy` would succeed vacuously and
    ///   misclassify the union as `.objectTaggedUnion` instead.
    private func classifyAnyOf(
        name: String,
        members: [String: JSONValue],
        variants: [JSONValue]
    ) throws -> DefinitionKind {
        try validateNonEmptyUnion(variants, name: name)
        if let rawKind = Self.agreedEnumRawKind(of: variants),
            variants.contains(where: { $0[Self.constKey] != nil })
        {
            return .scalarEnum(rawKind)
        }
        guard fallbacksAreGenuineCatchAlls(of: variants) else {
            return .deferredUnion(keyword: Self.anyOfKey)
        }
        let modeled = variants.filter { $0[Self.notKey] == nil }
        if members[Self.typeKey]?.stringValue == Self.objectTypeName, members[Self.propertiesKey] != nil {
            // Symmetric with this function's own `.taggedUnion`-returning
            // arity condition below (still a raw `!modeled.isEmpty`, out of
            // scope here): when every variant is `not`-guarded, `modeled`
            // is empty and `allSatisfy` over it is vacuously true. Without this
            // check that would return `.objectTaggedUnion` for a union with no
            // real payload variant at all, and only `objectTaggedUnionModel`'s
            // downstream re-derivation (via `taggedUnionModel`'s own
            // filtered-to-empty guard) would catch it — the same
            // `emptyUnionDetail` error, reached less directly.
            try validateNonEmptyUnion(modeled, name: name)
            if modeled.allSatisfy({ $0[Self.allOfKey] != nil }) {
                return .objectTaggedUnion
            }
            guard !modeled.contains(where: { $0[Self.allOfKey] != nil }) else {
                return .deferredUnion(keyword: Self.anyOfKey)
            }
            return .objectValueUnion
        }
        // This arity test is why `classifyAnyOf` takes the *raw* variant list
        // rather than `unionVariants(of:)`. It is the only line here that
        // depends on the unfiltered count: `modeled.count < variants.count`
        // asks "was a catch-all present?", and over a pre-filtered list the
        // two counts are always equal, so no definition would ever reach
        // `.taggedUnion` — 11 of them do today, the inventory
        // `VendoredSchemaTests.everyTaggedUnionCarriesAPayloadBearingFallback`
        // pins. The fallback guard above is filter-invariant and is *not* the
        // reason; do not cite it as one.
        if modeled.count < variants.count, !modeled.isEmpty, modeled.allSatisfy(hasConstDiscriminator) {
            return .taggedUnion
        }
        if variants.contains(where: hasConstDiscriminator) {
            return .discriminatedUnion
        }
        return .deferredUnion(keyword: Self.anyOfKey)
    }

    /// The member names a union's variants pin with a `const` — its
    /// discriminators, usually exactly one.
    ///
    /// - Parameter of: The union's variant fragments.
    /// - Returns: Every pinned member name.
    private func pinnedDiscriminators(of variants: [JSONValue]) -> Set<String> {
        Set(
            variants.flatMap { variant in
                (variant[Self.propertiesKey]?.objectValue ?? [:])
                    .filter { $0.value[Self.constKey] != nil }
                    .keys
            }
        )
    }

    /// Reports whether a union variant is the schema's explicit
    /// unknown-discriminator catch-all.
    ///
    /// ACP v2 writes out, as a final variant, the fallback earlier schema
    /// revisions left implicit: an object that `not`-excludes every known
    /// discriminator value and accepts any additional properties. It is the
    /// document saying "a tag this revision does not list", and each union
    /// family maps it onto the fallback that family already carries.
    ///
    /// What it *declares* no longer matters. v2's `AuthMethod` requires
    /// `methodId` and `name` beside the unrecognized tag, and instructs clients
    /// to "preserve the raw payload when storing, replaying, proxying, or
    /// forwarding"; every fallback this generator emits now carries the raw
    /// payload beside the tag, so those members survive.
    ///
    /// A variant that pins a `const` of its own is *not* this shape: it names a
    /// tag, which contradicts the `not` beside it, and it is the union's own
    /// evidence for which member the discriminator is. Treating it as the
    /// catch-all would take that evidence with it — a union whose variants
    /// keyed on two different members would pass `valueUnionDiscriminator`'s
    /// agreement check with the odd variant silently unmodeled — so
    /// `classifyAnyOf` defers the whole definition to raw JSON instead.
    ///
    /// `classifyOneOf` carries the same guard, for the same reason: a
    /// contradictory fallback there would otherwise survive
    /// `unionVariants(of:)` unfiltered and reach `discriminatorTag`. Both
    /// guards are unreached today — the vendored schema contains no
    /// definition-level `oneOf` at all — but must stay correct for when a
    /// re-vendor introduces one.
    ///
    /// - Parameter variant: The union variant fragment.
    /// - Returns: `true` when the variant negates the known discriminators and
    ///   pins none itself.
    private func isUnknownFallbackVariant(_ variant: JSONValue) -> Bool {
        variant[Self.notKey] != nil && !hasConstDiscriminator(variant)
    }

    /// Reports whether every `not`-guarded variant in a union is the genuine
    /// unknown-discriminator catch-all, rather than one that also pins a
    /// `const` of its own.
    ///
    /// Shared by `classifyOneOf` and `classifyAnyOf`, whose fallback guards
    /// are otherwise identical but for which keyword their caller defers.
    ///
    /// - Parameter of: The union's variant fragments.
    /// - Returns: `true` when every `not`-guarded variant is a genuine
    ///   catch-all (vacuously true when none is `not`-guarded).
    private func fallbacksAreGenuineCatchAlls(of variants: [JSONValue]) -> Bool {
        variants.filter { $0[Self.notKey] != nil }.allSatisfy(isUnknownFallbackVariant)
    }

    /// Reports whether an `anyOf` variant pins a `const` discriminator member.
    ///
    /// A `const`-pinned inline property is the marker of a discriminated-union
    /// variant, distinguishing `McpServer`-shaped unions from the scalar,
    /// envelope, and payload-only `anyOf` unions that stay deferred.
    ///
    /// - Parameter variant: The `anyOf` variant fragment.
    /// - Returns: `true` when some inline property carries a `const` value.
    private func hasConstDiscriminator(_ variant: JSONValue) -> Bool {
        let properties = variant[Self.propertiesKey]?.objectValue ?? [:]
        return properties.values.contains { $0[Self.constKey] != nil }
    }

    /// Builds the emission model for a scalar-enum definition.
    ///
    /// - Parameters:
    ///   - name: The definition's schema name.
    ///   - rawKind: The scalar JSON type the variants' constants take.
    ///   - fragment: The definition's schema fragment.
    /// - Returns: The scalar-enum model with cases in schema order.
    /// - Throws: `GeneratorError.unsupportedShape` when a variant lacks a
    ///   const value or the case names collide.
    private func scalarEnumModel(name: String, rawKind: EnumRawKind, fragment: JSONValue) throws -> ScalarEnumModel {
        // A variant that pins no value is the enum's open tail — the values a
        // newer peer may send — which the emitter renders as `unknown`.
        let variants = unionVariants(of: fragment).filter { $0[Self.constKey] != nil }
        guard !variants.isEmpty else {
            throw GeneratorError.unsupportedShape(context: name, detail: "no variant pins a \(Self.constKey) value")
        }
        let cases = try variants.enumerated().map { index, variant in
            try enumCaseModel(of: variant, rawKind: rawKind, context: "\(name) variant \(index)")
        }
        try validateCaseNames(names: cases.map(\.swiftName), context: name)
        return ScalarEnumModel(
            name: emittedName(name: name),
            documentation: description(of: fragment),
            rawKind: rawKind,
            cases: cases
        )
    }

    /// Builds the emission model for one scalar-enum case.
    ///
    /// A string constant names its own case: the wire spelling *is* the
    /// meaning, and mapping it is reversible. An integer cannot, so an integer
    /// enum names its cases from each variant's `title` instead.
    ///
    /// - Parameters:
    ///   - of: The `const`-pinning variant fragment.
    ///   - rawKind: The scalar JSON type the constant takes.
    ///   - context: The variant's error context.
    /// - Returns: The case model.
    /// - Throws: `GeneratorError.unsupportedShape` when the constant is not of
    ///   the enum's raw kind, or the case cannot be named.
    private func enumCaseModel(of variant: JSONValue, rawKind: EnumRawKind, context: String) throws -> EnumCaseModel {
        let documentation = description(of: variant)
        switch rawKind {
        case .string:
            guard let wireValue = variant[Self.constKey]?.stringValue else {
                throw GeneratorError.unsupportedShape(context: context, detail: "string variant without a \(Self.constKey) value")
            }
            return EnumCaseModel(
                wireValue: wireValue,
                swiftName: try swiftCaseName(fromWire: wireValue, context: context),
                documentation: documentation
            )
        case .integer:
            guard let number = variant[Self.constKey]?.numberValue, let wireValue = Int(exactly: number) else {
                throw GeneratorError.unsupportedShape(context: context, detail: "integer variant without a whole \(Self.constKey) value")
            }
            guard let title = variant[Self.titleKey]?.stringValue else {
                throw GeneratorError.unsupportedShape(context: context, detail: "integer variant needs a \(Self.titleKey) to name its case")
            }
            return EnumCaseModel(
                wireValue: String(wireValue),
                swiftName: try swiftCaseName(fromTitle: title, context: context),
                documentation: documentation
            )
        }
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
            let (key, tag) = try discriminatorTag(of: variant, context: context)
            discriminator = try Self.agreedDiscriminator(discriminator, key, context: context)
            let payloadType = try flattenedPayloadType(of: variant, context: context)
            return UnionCaseModel(
                tag: tag,
                swiftName: try swiftCaseName(fromWire: tag, context: context),
                payloadType: payloadType,
                documentation: description(of: variant)
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
            documentation: description(of: fragment),
            discriminator: discriminator,
            siblingMembers: [],
            cases: cases
        )
    }

    /// The emitted name of the nested enum an object's tagged union becomes.
    ///
    /// Fixed rather than derived from the discriminator, which would name
    /// v2's `SessionConfigOption` union `Type` — a nested type whose qualified
    /// reference `SessionConfigOption.Type` is metatype syntax.
    private static let nestedPayloadEnumName = "Payload"

    /// Builds the emission model for an object definition carrying a tagged
    /// union whose variants flatten `$ref` payloads.
    ///
    /// The union is the same shape a stand-alone tagged union has, so it is
    /// built by `taggedUnionModel` and then renamed for its nested position and
    /// told which members belong to the enclosing object.
    ///
    /// - Parameters:
    ///   - name: The definition's schema name.
    ///   - fragment: The definition's schema fragment.
    /// - Returns: The object-tagged-union model.
    /// - Throws: `GeneratorError.unsupportedShape` when the union is not
    ///   well-formed, or its discriminator collides with a base property.
    private func objectTaggedUnionModel(name: String, fragment: JSONValue) throws -> ObjectTaggedUnionModel {
        let base = try structModel(name: name, fragment: fragment)
        let union = try taggedUnionModel(name: name, fragment: fragment)
        try validateUnclaimed(names: [union.discriminator], by: base, context: name)
        return ObjectTaggedUnionModel(
            base: base,
            union: TaggedUnionModel(
                name: Self.nestedPayloadEnumName,
                documentation: "The variant payload, selected by the `\(union.discriminator)` discriminator.",
                discriminator: union.discriminator,
                siblingMembers: base.properties.map(\.wireName),
                cases: union.cases
            )
        )
    }

    /// Reads the internally-tagged discriminator member of a union variant.
    ///
    /// The variant must carry exactly one inline property (the discriminator),
    /// that property must pin a `const` tag, and it must be the sole `required`
    /// member.
    ///
    /// - Parameters:
    ///   - of: The union variant fragment.
    ///   - context: The variant's error context.
    /// - Returns: The discriminator wire name and its `const` tag value.
    /// - Throws: `GeneratorError.unsupportedShape` when the variant deviates
    ///   from the internally-tagged discriminator shape.
    private func discriminatorTag(of variant: JSONValue, context: String) throws -> (key: String, tag: String) {
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
        return (key, tag)
    }

    /// Folds one variant's discriminator member name into the name the union's
    /// earlier variants already agreed on.
    ///
    /// Every union family requires a single shared discriminator, so this is
    /// the one place that check and its message live.
    ///
    /// - Parameters:
    ///   - established: The name agreed so far, `nil` before the first variant.
    ///   - key: This variant's discriminator member name.
    ///   - context: The variant's error context.
    /// - Returns: The agreed discriminator name.
    /// - Throws: `GeneratorError.unsupportedShape` when this variant names a
    ///   different member.
    private static func agreedDiscriminator(_ established: String?, _ key: String, context: String) throws -> String {
        guard let established, established != key else { return key }
        throw discriminatorDisagreement([established, key], context: context)
    }

    /// The error reporting that a union's variants key on different members.
    ///
    /// - Parameters:
    ///   - names: The conflicting discriminator member names, in report order.
    ///   - context: The error context.
    /// - Returns: The `unsupportedShape` error naming the disagreement.
    private static func discriminatorDisagreement(_ names: [String], context: String) -> GeneratorError {
        GeneratorError.unsupportedShape(
            context: context,
            detail: "variants disagree on the discriminator: \(names.joined(separator: " vs "))"
        )
    }

    /// Resolves the single `$ref` payload a union variant flattens via `allOf`.
    ///
    /// Tagged-union variants may flatten no payload at all; discriminated-union
    /// variants must, which is what `discriminatedPayloadType` adds.
    ///
    /// - Parameters:
    ///   - of: The union variant fragment.
    ///   - context: The variant's error context.
    /// - Returns: The emitted payload type name, or `nil` when the variant
    ///   declares no `allOf`.
    /// - Throws: `GeneratorError.unsupportedShape` when `allOf` is present but
    ///   is not exactly one payload `$ref`.
    private func flattenedPayloadType(of variant: JSONValue, context: String) throws -> String? {
        guard let allOf = variant[Self.allOfKey] else { return nil }
        guard let entries = allOf.arrayValue, entries.count == 1,
            let reference = entries[0][Self.refKey]?.stringValue
        else {
            throw GeneratorError.unsupportedShape(context: context, detail: "expected \(Self.allOfKey) to be a single payload \(Self.refKey)")
        }
        return try referencedTypeName(reference: reference, context: context)
    }

    /// Resolves the single `$ref` payload a discriminated variant flattens.
    ///
    /// - Parameters:
    ///   - of: The `anyOf` variant fragment.
    ///   - context: The variant's error context.
    /// - Returns: The emitted payload type name.
    /// - Throws: `GeneratorError.unsupportedShape` when the variant flattens no
    ///   payload, or `allOf` is not a single payload `$ref`.
    private func discriminatedPayloadType(of variant: JSONValue, context: String) throws -> String {
        guard let payloadType = try flattenedPayloadType(of: variant, context: context) else {
            throw GeneratorError.unsupportedShape(context: context, detail: "expected an \(Self.allOfKey) payload \(Self.refKey)")
        }
        return payloadType
    }

    /// Builds the emission model for a discriminated `anyOf` union.
    ///
    /// Each variant wraps a single `$ref` payload via `allOf`. Variants that
    /// pin a shared `const` discriminator become tagged cases; exactly one
    /// discriminator-less variant becomes the default, selected when the
    /// discriminator is absent on the wire.
    ///
    /// Variants come from `unionVariants(of:)`, as they do for every other
    /// union stage, so a catch-all declaring nothing beyond the pinned
    /// discriminator is filtered out rather than searched for the `allOf`
    /// payload it does not carry — the default variant is what absorbs an
    /// unrecognized tag here, and the catch-all names no payload to flatten
    /// beside it.
    ///
    /// - Parameters:
    ///   - name: The definition's schema name.
    ///   - fragment: The definition's schema fragment.
    /// - Returns: The discriminated-union model with cases in schema order.
    /// - Throws: `GeneratorError.unsupportedShape` when a variant deviates from
    ///   the payload-ref shape, the discriminators disagree, or there is not
    ///   exactly one default variant.
    private func discriminatedUnionModel(name: String, fragment: JSONValue) throws -> DiscriminatedUnionModel {
        let variants = unionVariants(of: fragment)
        var discriminator: String?
        var defaultCount = 0
        let cases = try variants.enumerated().map { index, variant -> DiscriminatedCaseModel in
            let context = "\(name) variant \(index)"
            let payloadType = try discriminatedPayloadType(of: variant, context: context)
            let documentation = description(of: variant)
            let properties = variant[Self.propertiesKey]?.objectValue ?? [:]
            guard !properties.isEmpty else {
                defaultCount += 1
                return DiscriminatedCaseModel(
                    tag: nil,
                    swiftName: try defaultVariantCaseName(of: variant, context: context),
                    payloadType: payloadType,
                    documentation: documentation
                )
            }
            let (key, tag) = try discriminatorTag(of: variant, context: context)
            discriminator = try Self.agreedDiscriminator(discriminator, key, context: context)
            return DiscriminatedCaseModel(
                tag: tag,
                swiftName: try swiftCaseName(fromWire: tag, context: context),
                payloadType: payloadType,
                documentation: documentation
            )
        }
        guard let discriminator else {
            throw GeneratorError.unsupportedShape(context: name, detail: "no variant carries a \(Self.constKey) discriminator")
        }
        guard defaultCount == 1 else {
            throw GeneratorError.unsupportedShape(context: name, detail: "expected exactly one discriminator-less default variant, found \(defaultCount)")
        }
        try validateCaseNames(names: cases.map(\.swiftName), context: name)
        _ = try swiftCaseName(fromWire: discriminator, context: "\(name) discriminator")
        return DiscriminatedUnionModel(
            name: emittedName(name: name),
            documentation: description(of: fragment),
            discriminator: discriminator,
            cases: cases
        )
    }

    /// Names a discriminator-less default variant from its `title`.
    ///
    /// - Parameters:
    ///   - of: The default variant fragment.
    ///   - context: The variant's error context.
    /// - Returns: The camelCase Swift case name.
    /// - Throws: `GeneratorError.unsupportedShape` when the variant carries no
    ///   `title` to name its case.
    private func defaultVariantCaseName(of variant: JSONValue, context: String) throws -> String {
        guard let title = variant[Self.titleKey]?.stringValue else {
            throw GeneratorError.unsupportedShape(context: context, detail: "default variant needs a \(Self.titleKey) to name its case")
        }
        return try swiftCaseName(fromTitle: title, context: context)
    }

    /// Builds the emission model for an object definition with a value union.
    ///
    /// The base object properties are modeled as an ordinary struct. Each
    /// modeled `anyOf` variant contributes a `value`-payload case: the
    /// `const`-pinned variants are tagged, and the single variant that does not
    /// pin the discriminator is the default, selected when the discriminator is
    /// absent or unrecognized on the wire.
    ///
    /// A default that *declares* the discriminator unpinned — v2's
    /// `SetSessionConfigOptionRequest` catch-all — captures the tag it matched
    /// as a leading associated value, so it re-encodes a member the schema
    /// requires rather than dropping it. One that declares no discriminator at
    /// all carries the value alone and re-encodes without a tag, because it has
    /// none to write.
    ///
    /// Variants come from `valueUnionVariants(of:)`, which keeps a catch-all
    /// carrying a `value` member — it becomes that tag-capturing default — and
    /// drops one declaring nothing but the discriminator, which has no value to
    /// carry.
    ///
    /// - Parameters:
    ///   - name: The definition's schema name.
    ///   - fragment: The definition's schema fragment.
    /// - Returns: The object-value-union model.
    /// - Throws: `GeneratorError.unsupportedShape` when a variant deviates from
    ///   the single-`value`-payload shape or there is not exactly one default.
    private func objectValueUnionModel(name: String, fragment: JSONValue) throws -> ObjectValueUnionModel {
        let base = try structModel(name: name, fragment: fragment)
        let variants = valueUnionVariants(of: fragment)
        let discriminator = try valueUnionDiscriminator(of: variants, context: name)
        var valueWireName: String?
        var defaultCount = 0
        let cases = try variants.enumerated().map { index, variant -> ValueUnionCaseModel in
            let context = "\(name) value variant \(index)"
            let properties = variant[Self.propertiesKey]?.objectValue ?? [:]
            let (valueKey, valueFragment) = try valueMember(
                of: properties,
                discriminator: discriminator,
                context: context
            )
            if let established = valueWireName, established != valueKey {
                throw GeneratorError.unsupportedShape(context: context, detail: "variants disagree on the value member: \(established) vs \(valueKey)")
            }
            valueWireName = valueKey
            let valueType = try resolveType(fragment: valueFragment, override: nil, context: "\(context).\(valueKey)").base
            let documentation = description(of: variant)
            guard let tag = properties[discriminator]?[Self.constKey]?.stringValue else {
                defaultCount += 1
                // A default declaring the discriminator is selected by any
                // unrecognized tag and must write that tag back; one that does
                // not declare it has none to write.
                return ValueUnionCaseModel(
                    selector: properties[discriminator] == nil ? .untagged : .capturedTag,
                    swiftName: try defaultVariantCaseName(of: variant, context: context),
                    valueType: valueType,
                    documentation: documentation
                )
            }
            return ValueUnionCaseModel(
                selector: .tag(tag),
                swiftName: try swiftCaseName(fromWire: tag, context: context),
                valueType: valueType,
                documentation: documentation
            )
        }
        guard let valueWireName else {
            throw GeneratorError.unsupportedShape(context: name, detail: Self.emptyUnionDetail)
        }
        try validateUnclaimed(names: [discriminator, valueWireName], by: base, context: name)
        guard defaultCount == 1 else {
            throw GeneratorError.unsupportedShape(context: name, detail: "expected exactly one default value variant, found \(defaultCount)")
        }
        try validateCaseNames(names: cases.map(\.swiftName), context: name)
        return ObjectValueUnionModel(
            base: base,
            discriminator: discriminator,
            valueWireName: valueWireName,
            valueEnumName: try swiftTypeName(fromWireName: valueWireName, context: name),
            cases: cases
        )
    }

    /// Fails when a base object already declares a member its nested union
    /// will encode.
    ///
    /// Both object-carrying-a-union stages write the union's members through a
    /// second keyed container over the same encoder, which shares one object
    /// with the struct's own. A name declared on both sides is therefore
    /// written twice and the later write wins, so the struct's value and the
    /// union's can silently disagree on the wire. Reject the shape instead.
    ///
    /// - Parameters:
    ///   - names: The wire member names the union encodes.
    ///   - by: The base struct model.
    ///   - context: The definition name for error messages.
    /// - Throws: `GeneratorError.unsupportedShape` naming the collision.
    private func validateUnclaimed(names: [String], by base: StructModel, context: String) throws {
        let claimed = base.properties.map(\.wireName).filter(names.contains)
        guard claimed.isEmpty else {
            throw GeneratorError.unsupportedShape(
                context: context,
                detail: "the union's \(claimed.joined(separator: ", ")) collides with a base property of the same name"
            )
        }
    }

    /// Resolves the one member name a value union's variants pin with `const`.
    ///
    /// Naming the discriminator once, from the union as a whole, is what lets a
    /// variant that repeats it *unpinned* — the default, and ACP v2's explicit
    /// unknown variant — still be told apart from the value member.
    ///
    /// - Parameters:
    ///   - of: The union's variant fragments.
    ///   - context: The definition's error context.
    /// - Returns: The discriminator's wire name.
    /// - Throws: `GeneratorError.unsupportedShape` when no variant pins a
    ///   discriminator, or the variants pin different members.
    private func valueUnionDiscriminator(of variants: [JSONValue], context: String) throws -> String {
        let pinned = pinnedDiscriminators(of: variants)
        guard let discriminator = pinned.first else {
            throw GeneratorError.unsupportedShape(
                context: context,
                detail: "value union needs a \(Self.constKey) discriminator"
            )
        }
        guard pinned.count == 1 else {
            throw Self.discriminatorDisagreement(pinned.sorted(), context: context)
        }
        return discriminator
    }

    /// Finds the single non-discriminator `value` payload member of a variant.
    ///
    /// - Parameters:
    ///   - of: The variant's inline properties.
    ///   - discriminator: The union's discriminator wire name, excluded from
    ///     the search whether or not this variant pins it.
    ///   - context: The variant's error context.
    /// - Returns: The value member's wire name and fragment.
    /// - Throws: `GeneratorError.unsupportedShape` unless exactly one member
    ///   remains once the discriminator is set aside.
    private func valueMember(
        of properties: [String: JSONValue],
        discriminator: String,
        context: String
    ) throws -> (key: String, fragment: JSONValue) {
        let payloadMembers = properties.filter { $0.key != discriminator }
        guard payloadMembers.count == 1, let member = payloadMembers.first else {
            throw GeneratorError.unsupportedShape(context: context, detail: "expected exactly one non-discriminator value member")
        }
        return (member.key, member.value)
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
    /// The first word keeps its spelling: a wire value is already an
    /// identifier, and its exact casing is part of what the case means.
    ///
    /// - Parameters:
    ///   - fromWire: The wire string (e.g. `switch_mode`).
    ///   - context: `Definition variant` for error messages.
    /// - Returns: The camelCase Swift identifier (e.g. `switchMode`).
    /// - Throws: `GeneratorError.unsupportedShape` when the wire value does
    ///   not map to a plain, non-keyword Swift identifier.
    private func swiftCaseName(fromWire wireValue: String, context: String) throws -> String {
        try swiftCaseName(
            words: wireValue.split(separator: "_"),
            lowercasingFirstWord: false,
            source: "wire value",
            spelling: wireValue,
            context: context
        )
    }

    /// Maps a wire member name to a Swift type name.
    ///
    /// Every other emitted name is validated before it reaches the emitter, so
    /// an unusable one fails generation rather than `swiftc`. The nested enum a
    /// value union becomes is named after a wire member, so it goes through the
    /// same check.
    ///
    /// - Parameters:
    ///   - fromWireName: The JSON member name (e.g. `value`).
    ///   - context: The definition name for error messages.
    /// - Returns: The UpperCamelCase Swift type name (e.g. `Value`).
    /// - Throws: `GeneratorError.unsupportedShape` when the wire name does not
    ///   map to a plain, non-keyword Swift identifier.
    private func swiftTypeName(fromWireName wireName: String, context: String) throws -> String {
        let name = try swiftCaseName(fromWire: wireName, context: context)
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Maps a schema `title` to a camelCase Swift case name.
    ///
    /// Titles are prose — `Parse error`, `Method not found` — so words split on
    /// whitespace as well as underscores and the first word is lowercased.
    /// `ErrorCode`'s integer constants and every discriminator-less default
    /// variant are named this way, because neither has a wire string to take
    /// the name from.
    ///
    /// - Parameters:
    ///   - fromTitle: The schema title (e.g. `Parse error`).
    ///   - context: `Definition variant` for error messages.
    /// - Returns: The camelCase Swift identifier (e.g. `parseError`).
    /// - Throws: `GeneratorError.unsupportedShape` when the title does not map
    ///   to a plain, non-keyword Swift identifier.
    private func swiftCaseName(fromTitle title: String, context: String) throws -> String {
        try swiftCaseName(
            words: title.split(whereSeparator: { $0 == "_" || $0.isWhitespace }),
            lowercasingFirstWord: true,
            source: Self.titleKey,
            spelling: title,
            context: context
        )
    }

    /// Joins pre-split words into a validated camelCase Swift case name.
    ///
    /// - Parameters:
    ///   - words: The words, in order.
    ///   - lowercasingFirstWord: Whether to lowercase the first word's initial.
    ///   - source: What the words came from, for error messages.
    ///   - spelling: The original text, for error messages.
    ///   - context: `Definition variant` for error messages.
    /// - Returns: The camelCase Swift identifier.
    /// - Throws: `GeneratorError.unsupportedShape` when the result is not a
    ///   plain, non-keyword Swift identifier.
    private func swiftCaseName(
        words: [Substring],
        lowercasingFirstWord: Bool,
        source: String,
        spelling: String,
        context: String
    ) throws -> String {
        let name = words.enumerated()
            .map { index, word in
                guard index > 0 else {
                    return lowercasingFirstWord ? word.prefix(1).lowercased() + word.dropFirst() : String(word)
                }
                return word.prefix(1).uppercased() + word.dropFirst()
            }
            .joined()
        guard name.first?.isLetter == true, name.allSatisfy({ $0.isLetter || $0.isNumber }),
            !Self.swiftKeywords.contains(name)
        else {
            throw GeneratorError.unsupportedShape(
                context: context,
                detail: "\(source) \"\(spelling)\" does not map to a plain Swift identifier"
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
        var seen: Set<String> = []
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
            documentation: description(of: fragment),
            properties: models
        )
    }

    /// Orders properties required-first, optional second, `_meta` last.
    ///
    /// - Parameter of: The property model.
    /// - Returns: The property's group rank.
    private func emissionRank(of property: PropertyModel) -> Int {
        if property.wireName == "_meta" { return 2 }
        return property.isRequired ? 0 : 1
    }

    /// The schema extension keyword marking a forgiving scalar field.
    private static let defaultOnErrorKey = "x-deserialize-default-on-error"

    /// The schema extension keyword marking a forgiving array field.
    private static let skipInvalidItemsKey = "x-deserialize-skip-invalid-items"

    /// Validates that every `config.patchSemanticsFields` entry names a field
    /// the schema still declares.
    ///
    /// Neither the schema nor its description prose gives the generator a
    /// keyword to check itself, so the config table is the only source of
    /// truth for which fields have patch semantics — and a stale entry (a
    /// field renamed or removed on re-vendor) must fail generation rather
    /// than silently stop applying, the same discipline `deprecatedMethods`
    /// enforces for the routing table.
    ///
    /// - Parameter definitions: The schema's top-level `$defs` object.
    /// - Throws: `GeneratorError.invalidSchema` for an entry that is not
    ///   `"Definition.field"`, names no definition, or names no property of
    ///   that definition.
    private func validatePatchSemanticsFields(definitions: [String: JSONValue]) throws {
        for key in config.patchSemanticsFields.sorted() {
            guard let separator = key.firstIndex(of: "."), key.firstIndex(of: ".") == key.lastIndex(of: ".") else {
                throw GeneratorError.invalidSchema(
                    "patch semantics config key \"\(key)\" is not \"Definition.field\""
                )
            }
            let definitionName = String(key[key.startIndex..<separator])
            let fieldName = String(key[key.index(after: separator)...])
            guard let definition = definitions[definitionName],
                let properties = definition[Self.propertiesKey]?.objectValue,
                properties[fieldName] != nil
            else {
                throw GeneratorError.invalidSchema(
                    "patch semantics config names \"\(key)\", which is not a field the schema declares"
                )
            }
        }
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
            documentation: description(of: fragment),
            hasPatchSemantics: config.patchSemanticsFields.contains(context)
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
    ///   - of: The property's schema fragment.
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
    ///   - of: The property's schema fragment.
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
    /// - Parameter forWireName: The JSON member name.
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
            nullable = names.contains(Self.nullTypeName)
            let concrete = names.filter { $0 != Self.nullTypeName }
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
            let nonNull = anyOf.filter { $0[Self.typeKey]?.stringValue != Self.nullTypeName }
            if anyOf.count == Self.nullableAnyOfVariantCount, nonNull.count == 1 {
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

    /// The scalar JSON `type` keywords mapped to Swift types and the
    /// wire-invariant kind each may carry.
    ///
    /// `object` without a `$ref` is a free-form map (`additionalProperties`),
    /// so it maps to raw JSON.
    private static let scalarTypes: [String: (swiftName: String, allowedInvariant: GeneratorConfig.InvariantType?)] = [
        Self.stringTypeName: ("String", .absolutePath),
        Self.integerTypeName: ("Int", .lineNumber),
        Self.booleanTypeName: ("Bool", nil),
        Self.numberTypeName: ("Double", nil),
        Self.objectTypeName: ("JSONValue", nil),
    ]

    /// Resolves a scalar or array `type` keyword to a Swift type.
    ///
    /// - Parameters:
    ///   - named: The JSON schema type keyword (e.g. `string`).
    ///   - nullable: Whether the wire value admits JSON `null`.
    ///   - members: The fragment's object members, for `items`.
    ///   - override: The wire-invariant newtype the scalar position maps to.
    ///   - context: `Definition.field` for error messages.
    /// - Returns: The resolved type.
    /// - Throws: `GeneratorError.unsupportedShape` for unknown keywords and
    ///   un-modelable arrays.
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
        guard typeName == Self.arrayTypeName else {
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
    ///   - for: The schema default (never JSON null).
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
            return (Emitter.stringLiteral(text: string), false)
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

    /// The manifest member naming the protocol revision it routes.
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
    /// - Parameter of: The side to rank.
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
    /// - Parameter of: The group's routing key → wire method map.
    /// - Returns: The entries sorted by wire method name.
    private static func orderedByWireMethod(of group: [String: String]) -> [(key: String, value: String)] {
        group.sorted { $0.value < $1.value }
    }

    /// A definition's union variants exactly as the schema lists them.
    ///
    /// Reads whichever union keyword the definition uses. Only the two
    /// filtering accessors below and the classifier consume this directly;
    /// every emission stage goes through one of them.
    ///
    /// - Parameter of: The definition's schema fragment.
    /// - Returns: The variant fragments in schema order, empty when absent.
    private func declaredUnionVariants(of fragment: JSONValue) -> [JSONValue] {
        fragment[Self.oneOfKey]?.arrayValue ?? fragment[Self.anyOfKey]?.arrayValue ?? []
    }

    /// A definition's modeled union variants, empty when absent.
    ///
    /// Drops the explicit unknown-discriminator catch-all: the string-enum,
    /// tagged-union, and discriminated-union emitters each synthesize their own
    /// `unknown` fallback, which captures the unrecognized tag and the raw
    /// payload beside it. Modeling the catch-all again would emit a duplicate
    /// case, or fail looking for the `allOf` payload `$ref` it does not carry.
    ///
    /// - Parameter of: The definition's schema fragment.
    /// - Returns: The modeled variant fragments in schema order.
    private func unionVariants(of fragment: JSONValue) -> [JSONValue] {
        declaredUnionVariants(of: fragment).filter { !isUnknownFallbackVariant($0) }
    }

    /// The variants the value-union stage models, empty when absent.
    ///
    /// This stage synthesizes no fallback of its own: its default case *is* the
    /// catch-all. So a catch-all declaring a member beyond the discriminator —
    /// the `value` its own union is built around — is kept, and becomes the
    /// default case that captures the tag it matched. One declaring nothing
    /// beyond the discriminator has no value to carry and is dropped, leaving
    /// the union's discriminator-less default to absorb an unrecognized tag as
    /// before.
    ///
    /// - Parameter of: The definition's schema fragment.
    /// - Returns: The modeled variant fragments in schema order.
    private func valueUnionVariants(of fragment: JSONValue) -> [JSONValue] {
        let variants = declaredUnionVariants(of: fragment)
        let pinned = pinnedDiscriminators(of: variants)
        return variants.filter { variant in
            guard isUnknownFallbackVariant(variant) else { return true }
            return (variant[Self.propertiesKey]?.objectValue ?? [:]).keys.contains { !pinned.contains($0) }
        }
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
    ///   - namespace: The enclosing namespace enum to nest the table in, or
    ///     `nil` to emit it at the top level.
    /// - Returns: The rendered `MethodTable.generated.swift`.
    /// - Throws: `GeneratorError` when a manifest cannot be parsed or the
    ///   manifests disagree with the schema's annotations.
    private func methodTableFile(
        definitions: [String: JSONValue],
        metaJSON: Data,
        unstableMetaJSON: Data?,
        namespace: String?
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
            contents: Emitter.file(declarations: declarations, namespace: namespace)
        )
    }

    /// Parses and validates a routing manifest document.
    ///
    /// The manifest must declare the configured version and carry exactly the
    /// three known routing groups; an unknown group or version fails loudly
    /// rather than silently dropping routes.
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
        guard members[Self.versionKey] == .number(Double(config.manifestVersion)) else {
            throw GeneratorError.invalidSchema("\(context) does not declare expected version \(config.manifestVersion)")
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
        var seenWires: Set<String> = []
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
    /// - Parameter from: The schema's `$defs` object.
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
        var consumed: Set<SchemaRoute> = []
        let models = try collectBySide { (side: MethodSide) -> [MethodModel] in
            let group = manifest.methodsBySide[side] ?? [:]
            var handlerNames: Set<String> = []
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
            var handlerNames: Set<String> = []
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
    ///   - in: The side's already-registered handler names.
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

    /// The property name shared by the stable and unstable routing tables.
    ///
    /// `ACPMethodTable.methods` and `Unstable.MethodTable.methods` both use
    /// this name; extracting it keeps the two header declarations in
    /// lockstep if the property is ever renamed.
    private static let methodsPropertyName = "methods"

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
                // Version-neutral on purpose: this line ships as public DocC on
                // the generated table, and a hardcoded version goes stale the
                // moment a new schema is vendored. `Schema/README.md` names the
                // vendored revision.
                "/// The method-routing table for the stable ACP surface.",
                "///",
                "/// Derived from the vendored `meta.json` routing manifest and the schema's",
                "/// `x-side`/`x-method` annotations — never hand-wired.",
                "public enum ACPMethodTable {",
                "    /// Every stable method, ordered agent, client, protocol and by wire",
                "    /// method name within each side.",
                "    public static let \(Self.methodsPropertyName): [MethodInfo] = [",
            ],
            entries: methods,
            entryLines: { method in
                [
                    "        MethodInfo(",
                    "            wireMethod: \(stringLiteral(text: method.wireMethod)),",
                    "            handlerName: \(stringLiteral(text: method.handlerName)),",
                    "            side: \(sideCase(method.side)),",
                    "            kind: .\(method.kind.rawValue),",
                    "            paramsTypeName: \(stringLiteral(text: method.paramsTypeName)),",
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
                "        public static let \(Self.methodsPropertyName): [UnstableMethodInfo] = [",
            ],
            entries: methods,
            entryLines: { method in
                [
                    "            UnstableMethodInfo(",
                    "                wireMethod: \(stringLiteral(text: method.wireMethod)),",
                    "                handlerName: \(stringLiteral(text: method.handlerName)),",
                    "                side: \(sideCase(method.side))",
                    "            ),",
                ]
            },
            footer: ["        ]", "    }", "}"]
        )
    }
}
