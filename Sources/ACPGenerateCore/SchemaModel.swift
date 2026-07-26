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

    /// A union of scalar-const variants emitted as a Swift enum with an
    /// `unknown` fallback carrying the unrecognized wire value.
    case scalarEnum(EnumRawKind)

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

    /// A `type: object` definition that also carries a top-level `anyOf`
    /// tagged union whose variants flatten `$ref` payloads, emitted as a
    /// struct with a nested tagged-union enum.
    case objectTaggedUnion

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

/// The scalar JSON type a constant-union enum's values take.
///
/// ACP v2 builds enums out of both: string discriminators for protocol
/// vocabulary, and `int32` constants for `ErrorCode`. Both close with an
/// unconstrained variant standing for the values a newer peer may send, so
/// both emit the same enum shape over a different raw type.
enum EnumRawKind: Equatable {
    /// String constants (e.g. `end_turn`).
    case string

    /// Integer constants (e.g. `-32700`).
    case integer

    /// The Swift type the raw wire value decodes as.
    var swiftTypeName: String {
        switch self {
        case .string: "String"
        case .integer: "Int"
        }
    }
}

/// The emission model for one scalar-enum case.
struct EnumCaseModel {
    /// The constant as it crosses the wire — the string's contents for a
    /// string enum (e.g. `switch_mode`), the decimal digits for an integer
    /// one (e.g. `-32700`). The emitter renders it as a literal of the
    /// enum's raw kind.
    let wireValue: String

    /// The camelCase Swift case name (e.g. `switchMode`).
    let swiftName: String

    /// The schema `description`, emitted as a doc comment.
    let documentation: String?
}

/// The emission model for a scalar enum with an `unknown` fallback carrying
/// the unrecognized wire value.
struct ScalarEnumModel {
    /// The emitted Swift type name (after renames).
    let name: String

    /// The schema `description`, emitted as a doc comment.
    let documentation: String?

    /// The scalar JSON type the cases' wire values take.
    let rawKind: EnumRawKind

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

    /// Wire member names that belong to an enclosing object rather than to the
    /// union, and so are not part of an unrecognized variant's captured
    /// payload. Empty for a stand-alone union; the base object's members when
    /// the union is nested in one, where capturing them would let a stale copy
    /// overwrite the struct's own on re-encode.
    let siblingMembers: [String]

    /// Cases in schema order.
    let cases: [UnionCaseModel]
}

/// The emission model for an object definition that carries a tagged union.
///
/// The base object properties are modeled as an ordinary struct; the top-level
/// `anyOf` becomes a nested enum whose `$ref` payload flattens beside the base
/// properties on the wire, exactly as it would for a stand-alone tagged union.
struct ObjectTaggedUnionModel {
    /// The base struct model built from the object's `properties`/`required`.
    let base: StructModel

    /// The nested union. Its `discriminator` is also the struct's stored
    /// property name, since that is the member the union occupies on the wire.
    let union: TaggedUnionModel
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

/// How a value-union variant is selected on the wire, and what its emitted
/// case re-encodes as the discriminator.
enum ValueUnionSelector: Equatable {
    /// A `const`-pinned variant: matched by this tag, re-encoded with it.
    case tag(String)

    /// A default variant that does not declare the discriminator at all. It is
    /// selected when the discriminator is absent, and re-encodes without one —
    /// so it has no tag to carry and its case takes the value alone.
    case untagged

    /// A default variant that declares the discriminator *unpinned* — the
    /// schema's catch-all. Any unrecognized tag selects it, so its case takes
    /// that tag as a leading associated value and re-encodes it verbatim.
    case capturedTag
}

/// The emission model for one variant of an object's embedded value union.
struct ValueUnionCaseModel {
    /// How the variant is selected on the wire.
    let selector: ValueUnionSelector

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

    /// Cases in schema order; exactly one is a default — that is, carries a
    /// selector other than `.tag`.
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
