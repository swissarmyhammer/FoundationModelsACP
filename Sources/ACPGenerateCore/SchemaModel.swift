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

    /// An `anyOf` of `$ref`-payload variants keyed on a `const` discriminator
    /// member, with one discriminator-less default variant, emitted as a Swift
    /// enum with an `unknown(String)` fallback.
    case discriminatedUnion

    /// A `type: object` definition that also carries a top-level `anyOf`
    /// value union, emitted as a struct with a nested value-union enum.
    case objectValueUnion

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

/// The emission model for one discriminated-`anyOf`-union variant.
struct DiscriminatedCaseModel {
    /// The discriminator value on the wire (e.g. `http`), or `nil` for the
    /// discriminator-less default variant selected when the discriminator is
    /// absent.
    let tag: String?

    /// The camelCase Swift case name (e.g. `http`, `stdio`).
    let swiftName: String

    /// The emitted payload type whose fields sit flattened beside the
    /// discriminator.
    let payloadType: String

    /// The schema `description`, emitted as a doc comment.
    let documentation: String?
}

/// The emission model for a discriminated `anyOf` union with a default variant.
struct DiscriminatedUnionModel {
    /// The emitted Swift type name (after renames).
    let name: String

    /// The schema `description`, emitted as a doc comment.
    let documentation: String?

    /// The wire name of the discriminator member (e.g. `type`).
    let discriminator: String

    /// Cases in schema order; exactly one carries a `nil` `tag` (the default).
    let cases: [DiscriminatedCaseModel]
}

/// The emission model for one variant of an object's embedded value union.
struct ValueUnionCaseModel {
    /// The discriminator value on the wire (e.g. `boolean`), or `nil` for the
    /// default variant selected when the discriminator is absent or unknown.
    let tag: String?

    /// The camelCase Swift case name (e.g. `boolean`, `valueId`).
    let swiftName: String

    /// The Swift type of the variant's `value` payload (e.g. `Bool`).
    let valueType: String

    /// The schema `description`, emitted as a doc comment.
    let documentation: String?
}

/// The emission model for an object definition that carries a value union.
///
/// The base object properties are modeled as an ordinary struct; the top-level
/// `anyOf` becomes a nested value-union enum whose fields flatten beside the
/// base properties on the wire.
struct ObjectValueUnionModel {
    /// The base struct model built from the object's `properties`/`required`.
    let base: StructModel

    /// The wire name of the discriminator member (e.g. `type`).
    let discriminator: String

    /// The wire name of the union's payload member (e.g. `value`).
    let valueWireName: String

    /// The emitted name of the nested value-union enum (e.g. `Value`).
    let valueEnumName: String

    /// Cases in schema order; exactly one carries a `nil` `tag` (the default).
    let cases: [ValueUnionCaseModel]
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

/// The emission model for one stable routing-table entry.
struct MethodModel {
    /// The method name as it crosses the wire (e.g. `session/new`).
    let wireMethod: String

    /// The Swift handler name (e.g. `newSession`).
    let handlerName: String

    /// The participant that serves the method.
    let side: MethodSide

    /// Whether the method is a request or a notification.
    let kind: MethodKind

    /// The emitted Swift type name of the method's parameters.
    let paramsTypeName: String

    /// The emitted Swift type name of the method's result; `nil` for
    /// notifications.
    let resultTypeName: String?

    /// The configured deprecation message, if the method is deprecated.
    let deprecationMessage: String?
}

/// The emission model for one unstable routing-table entry.
struct UnstableMethodModel {
    /// The method name as it crosses the wire (e.g. `session/fork`).
    let wireMethod: String

    /// The Swift handler name derived from the manifest's routing key.
    let handlerName: String

    /// The participant that serves the method.
    let side: MethodSide
}
