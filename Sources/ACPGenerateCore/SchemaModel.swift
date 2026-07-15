import FoundationModelsACP

/// Errors surfaced while parsing the schema or building the emission model.
public enum GeneratorError: Error, Equatable, CustomStringConvertible {
    /// The document is not JSON or lacks the expected top-level structure.
    case invalidSchema(String)

    /// A definition or field uses a shape the generator does not understand;
    /// failing loudly beats silently emitting wrong types.
    case unsupportedShape(context: String, detail: String)

    public var description: String {
        switch self {
        case .invalidSchema(let detail):
            "invalid schema: \(detail)"
        case .unsupportedShape(let context, let detail):
            "unsupported schema shape at \(context): \(detail)"
        }
    }
}

/// The generator's classification of a schema definition.
enum DefinitionKind {
    /// A `type: object` definition emitted as a Codable struct.
    case objectStruct

    /// A bare `type: string` definition emitted as a distinct ID newtype.
    case stringIdentifier

    /// A `oneOf` of string-const variants emitted as a Swift enum with an
    /// `unknown(String)` fallback for unrecognized wire values.
    case stringEnum

    /// A `oneOf` of discriminated object variants emitted as a Swift enum
    /// with associated values, keyed on the shared discriminator member.
    case taggedUnion

    /// An `anyOf`/`enum` definition deferred to a later generator stage;
    /// emitted as a placeholder typealias seam.
    case deferredUnion(keyword: String)

    /// A definition with no shape at all (`ExtRequest` and friends): raw JSON.
    case freeform

    /// A definition whose Swift type is hand-written in Core; never emitted.
    case handwritten
}

/// A Swift type resolved from a schema fragment, before optionality is
/// decided by `required` membership.
struct ResolvedType: Equatable {
    /// The rendered non-optional Swift type, e.g. `AbsolutePath` or `[McpServer]`.
    var base: String

    /// The element type when the wire value is an array, else `nil`.
    var element: String?

    /// Whether the wire value itself admits JSON `null`.
    var nullable: Bool
}

/// How a field's generated `init(from:)` line decodes it.
enum DecodeStrategy: Equatable {
    /// `decode`/`decodeIfPresent` — errors propagate. Always used for
    /// wire-invariant fields.
    case strict

    /// `forgivingDecode`/`forgivingDecodeIfPresent` — malformed values
    /// degrade to the schema default or `nil`.
    case forgivingScalar

    /// `forgivingDecodeArray(IfPresent)` — malformed elements are skipped.
    case forgivingArray
}

/// The emission model for one struct property.
struct PropertyModel {
    /// The JSON member name on the wire (e.g. `_meta`).
    let wireName: String

    /// The Swift property name (e.g. `meta`).
    let swiftName: String

    /// The non-optional Swift type expression (e.g. `[AbsolutePath]`).
    let typeExpression: String

    /// The array element type when the field is an array, else `nil`.
    let elementType: String?

    /// Whether the property is `Optional` in Swift.
    let isOptional: Bool

    /// Whether the schema lists the field in `required`.
    let isRequired: Bool

    /// The Swift expression for the schema `default`, when present.
    let defaultExpression: String?

    /// Whether `defaultExpression` is a `Type()` empty-instance default that
    /// must be validated against the target struct's own defaults.
    let defaultsToEmptyInstance: Bool

    /// The schema default's object members when `defaultsToEmptyInstance`,
    /// compared member-by-member against the target struct's own defaults.
    let objectDefaultMembers: [String: JSONValue]?

    /// How the generated `init(from:)` decodes the field.
    let strategy: DecodeStrategy

    /// The schema `description`, emitted as a doc comment.
    let documentation: String?
}

/// The emission model for one string-enum case.
struct EnumCaseModel {
    /// The exact string as it crosses the wire (e.g. `switch_mode`).
    let wireValue: String

    /// The camelCase Swift case name (e.g. `switchMode`).
    let swiftName: String

    /// The schema `description`, emitted as a doc comment.
    let documentation: String?
}

/// The emission model for a string enum with an `unknown(String)` fallback.
struct StringEnumModel {
    /// The emitted Swift type name (after renames).
    let name: String

    /// The schema `description`, emitted as a doc comment.
    let documentation: String?

    /// Cases in schema order.
    let cases: [EnumCaseModel]
}

/// The emission model for one tagged-union variant.
struct UnionCaseModel {
    /// The discriminator value on the wire (e.g. `tool_call_update`).
    let tag: String

    /// The camelCase Swift case name (e.g. `toolCallUpdate`).
    let swiftName: String

    /// The emitted payload type whose fields sit flattened beside the
    /// discriminator, or `nil` when the variant carries only its
    /// discriminator.
    let payloadType: String?

    /// The schema `description`, emitted as a doc comment.
    let documentation: String?
}

/// The emission model for a tagged union keyed on a discriminator member.
struct TaggedUnionModel {
    /// The emitted Swift type name (after renames).
    let name: String

    /// The schema `description`, emitted as a doc comment.
    let documentation: String?

    /// The wire name of the discriminator member (e.g. `sessionUpdate`).
    let discriminator: String

    /// Cases in schema order.
    let cases: [UnionCaseModel]
}

/// The emission model for one object-struct definition.
struct StructModel {
    /// The emitted Swift type name (after renames).
    let name: String

    /// The schema `description`, emitted as a doc comment.
    let documentation: String?

    /// Properties in emission order: required, then optional, `_meta` last,
    /// alphabetical within each group.
    let properties: [PropertyModel]
}
