import Foundation
import Testing

@testable import ACPGenerateCore

/// Tests `oneOf` tagged-union classification: the shapes it rejects loudly
/// (mixed variant shapes, disagreeing discriminator keys, payload fields
/// beyond the discriminator, Swift-keyword wire values) and the emitted
/// source's own escaping safety for a hostile tag.
///
/// Generation below passes an explicit empty `GeneratorConfig()` rather than
/// `SchemaGenerator`'s `.acpV2` default: `.acpV2` carries a
/// `patchSemanticsFields` table validated against the schema being
/// generated, and these inline fixtures do not declare the ACP v2 types that
/// table names.
@Suite struct TaggedUnionEmissionTests {
    @Test func oneOfMixingStringAndObjectVariantsFailsLoudly() throws {
        let schema = Data(
            """
            {
              "$defs": {
                "Mixed": {
                  "oneOf": [
                    { "type": "string", "const": "plain" },
                    {
                      "type": "object",
                      "properties": { "type": { "type": "string", "const": "fancy" } },
                      "required": ["type"]
                    }
                  ]
                }
              }
            }
            """.utf8)
        #expect(throws: GeneratorError.self) {
            _ = try SchemaGenerator(config: GeneratorConfig()).generate(schemaJSON: schema)
        }
    }

    @Test func variantsWithDifferingDiscriminatorKeysFailLoudly() throws {
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
        #expect(throws: GeneratorError.self) {
            _ = try SchemaGenerator(config: GeneratorConfig()).generate(schemaJSON: schema)
        }
    }

    @Test func quoteBearingTagEscapesInEmittedSource() throws {
        // `swiftCaseName` rejects such tags at the generator boundary, but
        // the emitter must be safe on its own terms: a quote or backslash in
        // a tag may never break out of the generated string literal. The tag
        // is written once, as the `Tag` enum's raw value — both decode
        // (`Tag(rawValue:)`) and encode (`Tag.aBC.rawValue`) read that one
        // literal back rather than each carrying their own copy.
        let model = TaggedUnionModel(
            name: "Weird",
            documentation: nil,
            discriminator: "type",
            siblingMembers: [],
            cases: [
                UnionCaseModel(tag: #"a"b\c"#, swiftName: "aBC", payloadType: nil, documentation: nil)
            ]
        )
        let source = Emitter.taggedUnionDeclaration(model: model)
        #expect(source.contains(#"case aBC = "a\"b\\c""#))
        #expect(source.contains("switch Tag(rawValue: discriminator) {"))
        #expect(source.contains("try container.encode(Tag.aBC.rawValue, forKey: .type)"))
        #expect(!source.contains(#"case aBC = "a"b\c""#))
    }

    @Test func swiftKeywordWireValueFailsLoudly() throws {
        // `case default` would not compile; the generator must throw at
        // generation time instead of emitting a broken file.
        let schema = Data(
            """
            {
              "$defs": {
                "Keyworded": {
                  "oneOf": [
                    { "type": "string", "const": "default" }
                  ]
                }
              }
            }
            """.utf8)
        #expect(throws: GeneratorError.self) {
            _ = try SchemaGenerator(config: GeneratorConfig()).generate(schemaJSON: schema)
        }
    }

    @Test func variantWithPropertiesBeyondDiscriminatorFailsLoudly() throws {
        // Inline payload fields beyond the discriminator are a shape this
        // stage does not model; emitting an enum would silently drop them.
        let schema = Data(
            """
            {
              "$defs": {
                "Fat": {
                  "oneOf": [
                    {
                      "type": "object",
                      "properties": {
                        "type": { "type": "string", "const": "a" },
                        "extra": { "type": "string" }
                      },
                      "required": ["type"]
                    }
                  ]
                }
              }
            }
            """.utf8)
        #expect(throws: GeneratorError.self) {
            _ = try SchemaGenerator(config: GeneratorConfig()).generate(schemaJSON: schema)
        }
    }

    @Test func oneOfFallbackPinningItsOwnConstDefersRatherThanMismodeling() throws {
        // A `not`-guarded variant that also pins a `const` of its own
        // contradicts the `not` beside it and is the union's own evidence
        // for which member the discriminator is, not a catch-all —
        // `isUnknownFallbackVariant`'s documented gap for `oneOf`. It must
        // defer the whole definition to raw JSON rather than let the
        // contradictory variant reach `discriminatorTag` unfiltered and
        // silently become an extra case.
        let schema = Data(
            """
            {
              "$defs": {
                "Ambiguous": {
                  "oneOf": [
                    {
                      "type": "object",
                      "properties": { "type": { "type": "string", "const": "a" } },
                      "required": ["type"]
                    },
                    {
                      "type": "object",
                      "not": { "properties": { "type": { "enum": ["a"] } } },
                      "properties": { "type": { "type": "string", "const": "b" } },
                      "required": ["type"]
                    }
                  ]
                }
              }
            }
            """.utf8)
        let generated = try SchemaGenerator(config: GeneratorConfig()).generate(schemaJSON: schema)
        let unresolved = try #require(generated.first { $0.name == "Unresolved.generated.swift" })
        #expect(unresolved.contents.contains("public typealias Ambiguous = JSONValue"))
        // Both variants pin a discriminator (`a` and `b`), so `deferredUnionReason`
        // must take its "Deferred" branch, not the "Permanently deferred" one
        // reserved for unions with no discriminator at all.
        #expect(
            unresolved.contents.contains(
                "Deferred: this `oneOf` union's variants pin discriminators"
            )
        )
        let unions = try #require(generated.first { $0.name == "Unions.generated.swift" })
        #expect(!unions.contents.contains("Ambiguous"))
    }

    @Test func oneOfWhoseOnlyVariantIsTheUnknownFallbackFailsOnTheEmptyUnionDetail() throws {
        // Every variant is a genuine (non-contradictory) catch-all, so
        // classification still reaches `.taggedUnion` — but `taggedUnionModel`
        // then filters it out via `unionVariants(of:)`, leaving no variant to
        // build a case from. Pins the `emptyUnionDetail` string this call
        // site shares with `classifyOneOf`'s own empty-`oneOf` guard.
        let schema = Data(
            """
            {
              "$defs": {
                "OnlyFallback": {
                  "oneOf": [
                    {
                      "type": "object",
                      "not": { "properties": { "type": { "enum": ["a"] } } }
                    }
                  ]
                }
              }
            }
            """.utf8)
        #expect(throws: GeneratorError.unsupportedShape(context: "OnlyFallback", detail: "empty union")) {
            _ = try SchemaGenerator(config: GeneratorConfig()).generate(schemaJSON: schema)
        }
    }
}
