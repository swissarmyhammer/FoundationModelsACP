import Foundation
import Testing

@testable import ACPGenerateCore

/// Pins the exact `GeneratorError.unsupportedShape` detail strings for the
/// three validation failures an earlier round consolidated onto a single
/// code path each, so a future edit to one path cannot silently change what
/// two independent call sites say without a test noticing:
///
/// - `Self.emptyUnionDetail` — one string constant, reused by
///   `classifyOneOf`'s empty-`oneOf` guard and by `taggedUnionModel`'s
///   filtered-to-empty guard.
/// - `Self.discriminatorDisagreement(_:context:)` — one error-construction
///   helper, reached both from `agreedDiscriminator` (`taggedUnionModel`'s
///   per-variant discriminator agreement) and from `valueUnionDiscriminator`
///   (an object-value-union's pinned-discriminator agreement).
/// - `flattenedPayloadType(of:context:)` — one payload-`$ref` validator,
///   reached both directly from `taggedUnionModel` and, via
///   `discriminatedPayloadType`, from `discriminatedUnionModel`.
///
/// `GeneratorError` is `Equatable`, so each test matches the thrown error by
/// value rather than only by type.
///
/// Every generation call below passes an explicit empty `GeneratorConfig()`
/// rather than relying on `SchemaGenerator`'s `.acpV2` default: `.acpV2`
/// carries a `patchSemanticsFields` table validated against the schema being
/// generated, and these synthetic fixtures do not declare the ACP v2 types
/// that table names.
@Suite struct GeneratorErrorDetailTests {
    // MARK: - emptyUnionDetail

    @Test func emptyOneOfFailsWithTheEmptyUnionDetail() throws {
        let schema = Data(
            """
            {
              "$defs": {
                "Empty": { "oneOf": [] }
              }
            }
            """.utf8)
        #expect(throws: GeneratorError.unsupportedShape(context: "Empty", detail: "empty union")) {
            _ = try SchemaGenerator(config: GeneratorConfig()).generate(schemaJSON: schema)
        }
    }

    // The `taggedUnionModel` call site sharing this same string (a `oneOf`
    // whose only variant is filtered out as the unknown fallback) is pinned
    // by `TaggedUnionTests.oneOfWhoseOnlyVariantIsTheUnknownFallbackFailsOnTheEmptyUnionDetail`,
    // alongside the classification test it is paired with.

    @Test func emptyAnyOfFailsWithTheEmptyUnionDetail() throws {
        // `classifyAnyOf` mirrors `classifyOneOf`'s empty-union guard: an
        // empty `anyOf` permits nothing, so it must fail loudly rather than
        // silently deferring to a raw-JSON typealias the way an unrecognized
        // shape would.
        let schema = Data(
            """
            {
              "$defs": {
                "Empty": { "anyOf": [] }
              }
            }
            """.utf8)
        #expect(throws: GeneratorError.unsupportedShape(context: "Empty", detail: "empty union")) {
            _ = try SchemaGenerator(config: GeneratorConfig()).generate(schemaJSON: schema)
        }
    }

    // MARK: - discriminatorDisagreement

    @Test func taggedUnionVariantsDisagreeingOnTheDiscriminatorNameBothKeys() throws {
        let schema = Data(
            """
            {
              "$defs": {
                "Torn": {
                  "oneOf": [
                    {
                      "type": "object",
                      "properties": { "type": { "type": "string", "const": "a" } },
                      "required": ["type"]
                    },
                    {
                      "type": "object",
                      "properties": { "kind": { "type": "string", "const": "b" } },
                      "required": ["kind"]
                    }
                  ]
                }
              }
            }
            """.utf8)
        #expect(
            throws: GeneratorError.unsupportedShape(
                context: "Torn variant 1",
                detail: "variants disagree on the discriminator: type vs kind"
            )
        ) {
            _ = try SchemaGenerator(config: GeneratorConfig()).generate(schemaJSON: schema)
        }
    }

    @Test func valueUnionVariantsPinningDifferentDiscriminatorMembersNameBothSorted() throws {
        let schema = Data(
            """
            {
              "$defs": {
                "Torn": {
                  "type": "object",
                  "properties": {},
                  "anyOf": [
                    {
                      "type": "object",
                      "properties": {
                        "type": { "type": "string", "const": "a" },
                        "value": { "type": "string" }
                      },
                      "required": ["type"]
                    },
                    {
                      "type": "object",
                      "properties": {
                        "kind": { "type": "string", "const": "b" },
                        "value": { "type": "string" }
                      },
                      "required": ["kind"]
                    }
                  ]
                }
              }
            }
            """.utf8)
        #expect(
            throws: GeneratorError.unsupportedShape(
                context: "Torn",
                detail: "variants disagree on the discriminator: kind vs type"
            )
        ) {
            _ = try SchemaGenerator(config: GeneratorConfig()).generate(schemaJSON: schema)
        }
    }

    @Test func valueUnionWithNoVariantPinningADiscriminatorFailsLoudly() throws {
        // `valueUnionDiscriminator`'s other guard, split from the same
        // ternary the disagreement message came from: zero pinned
        // discriminators is `pinned.first == nil`, not `pinned.count != 1`.
        let schema = Data(
            """
            {
              "$defs": {
                "NoDiscriminator": {
                  "type": "object",
                  "properties": {},
                  "anyOf": [
                    {
                      "type": "object",
                      "properties": { "value": { "type": "string" } }
                    }
                  ]
                }
              }
            }
            """.utf8)
        #expect(
            throws: GeneratorError.unsupportedShape(
                context: "NoDiscriminator",
                detail: "value union needs a const discriminator"
            )
        ) {
            _ = try SchemaGenerator(config: GeneratorConfig()).generate(schemaJSON: schema)
        }
    }

    // MARK: - flattenedPayloadType

    @Test func taggedUnionVariantWithMalformedAllOfFailsWithTheSharedPayloadDetail() throws {
        let schema = Data(
            """
            {
              "$defs": {
                "BadPayload": {
                  "oneOf": [
                    {
                      "type": "object",
                      "properties": { "type": { "type": "string", "const": "a" } },
                      "required": ["type"],
                      "allOf": [{}, {}]
                    }
                  ]
                }
              }
            }
            """.utf8)
        #expect(
            throws: GeneratorError.unsupportedShape(
                context: "BadPayload variant 0",
                detail: "expected allOf to be a single payload $ref"
            )
        ) {
            _ = try SchemaGenerator(config: GeneratorConfig()).generate(schemaJSON: schema)
        }
    }

    @Test func discriminatedUnionVariantWithMalformedAllOfFailsWithTheSamePayloadDetail() throws {
        // Same detail string as the tagged-union path above, reached through
        // `discriminatedPayloadType` instead of `taggedUnionModel` directly —
        // proof the two call sites have not drifted apart.
        let schema = Data(
            """
            {
              "$defs": {
                "BadDiscriminated": {
                  "anyOf": [
                    {
                      "type": "object",
                      "properties": { "kind": { "type": "string", "const": "a" } },
                      "allOf": [{}, {}]
                    }
                  ]
                }
              }
            }
            """.utf8)
        #expect(
            throws: GeneratorError.unsupportedShape(
                context: "BadDiscriminated variant 0",
                detail: "expected allOf to be a single payload $ref"
            )
        ) {
            _ = try SchemaGenerator(config: GeneratorConfig()).generate(schemaJSON: schema)
        }
    }
}
