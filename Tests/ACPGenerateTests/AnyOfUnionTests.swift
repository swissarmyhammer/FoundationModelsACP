import Foundation
import Testing

@testable import ACPGenerateCore

/// Tests the `anyOf` generator stage that resolves discriminated unions and
/// objects carrying a value union.
///
/// Every case here is driven by an inline synthetic schema, so the shapes are
/// named `Thing` / `Choice` / `Change` rather than after any vendored
/// definition: a discriminated union becomes a tagged enum with a
/// discriminator-less default variant, and an object carrying a `value` union
/// becomes a struct with a nested value enum. No vendored v2 definition takes
/// the value-union path — the schema's one object-plus-`anyOf` request defers
/// to a placeholder seam instead, which `VendoredSchemaTests` pins.
@Suite struct AnyOfUnionTests {
    @Test func discriminatedUnionClassifiesAndEmits() throws {
        let schema = Data(
            """
            {
              "$defs": {
                "Alpha": {
                  "type": "object",
                  "properties": { "x": { "type": "string" } },
                  "required": ["x"]
                },
                "Beta": {
                  "type": "object",
                  "properties": { "y": { "type": "string" } },
                  "required": ["y"]
                },
                "Thing": {
                  "anyOf": [
                    {
                      "type": "object",
                      "properties": { "type": { "type": "string", "const": "alpha" } },
                      "required": ["type"],
                      "allOf": [{ "$ref": "#/$defs/Alpha" }]
                    },
                    { "title": "beta", "allOf": [{ "$ref": "#/$defs/Beta" }] }
                  ]
                }
              }
            }
            """.utf8)
        let files = try SchemaGenerator().generate(schemaJSON: schema)
        let unions = try #require(files.first { $0.name == "Unions.generated.swift" }).contents
        #expect(unions.contains("public enum Thing: Codable, Hashable, Sendable"))
        #expect(unions.contains("case alpha(Alpha)"))
        #expect(unions.contains("case beta(Beta)"))
        let unresolved = try #require(files.first { $0.name == "Unresolved.generated.swift" }).contents
        #expect(!unresolved.contains("typealias Thing"))
    }

    @Test func explicitUnknownVariantBecomesTheSynthesizedFallback() throws {
        // ACP v2 spells the unknown case out in the schema: a final variant
        // whose `not` excludes every known discriminator and which accepts
        // any additional properties. That is the `unknown(String)` case the
        // emitter already synthesizes, so it must not be modeled as a variant
        // of its own.
        let files = try SchemaGenerator().generate(schemaJSON: Self.explicitUnknownVariantSchema)
        let unions = try #require(files.first { $0.name == "Unions.generated.swift" }).contents
        #expect(unions.contains("public enum Thing: Codable, Hashable, Sendable"))
        #expect(unions.contains("case alpha(Alpha)"))
        #expect(unions.contains("case unknown(String)"))
        // The catch-all is not a case of its own, under its title or otherwise.
        #expect(!unions.contains("case other"))
        let unresolved = try #require(files.first { $0.name == "Unresolved.generated.swift" }).contents
        #expect(!unresolved.contains("typealias Thing"))
    }

    @Test func unknownVariantCarryingPayloadStaysDeferred() throws {
        // ACP v2's `AuthMethod` catch-all requires `methodId` and `name`
        // alongside the unrecognized tag, and its own description says clients
        // "should preserve the raw payload when storing, replaying, proxying,
        // or forwarding". A synthesized `unknown(String)` holds the tag and
        // drops the rest, so such a union must not be modeled as a tagged enum
        // at all — raw JSON is lossless where a truncating enum is not.
        let files = try SchemaGenerator().generate(schemaJSON: Self.payloadBearingUnknownVariantSchema)
        let unresolved = try #require(files.first { $0.name == "Unresolved.generated.swift" }).contents
        #expect(unresolved.contains("public typealias Thing = JSONValue"))
        let unions = try #require(files.first { $0.name == "Unions.generated.swift" }).contents
        #expect(!unions.contains("public enum Thing"))
    }

    @Test func valueUnionDefaultDeclaringTheDiscriminatorFailsLoudly() throws {
        // The value-union emitter writes only the `value` member for its
        // default case. A default variant that *declares* the discriminator
        // therefore round-trips to JSON missing a member the schema requires,
        // so the shape is rejected instead of emitted.
        #expect(throws: GeneratorError.self) {
            _ = try SchemaGenerator().generate(schemaJSON: Self.valueUnionDefaultWithDiscriminatorSchema)
        }
    }

    @Test func objectCarryingATaggedPayloadUnionStaysDeferred() throws {
        // A base object whose variants flatten `$ref` payloads is neither a
        // plain tagged union nor the object-plus-`value`-union shape. It has no
        // emission model yet, so it stays a placeholder seam rather than
        // being forced through the value-union stage.
        let files = try SchemaGenerator().generate(schemaJSON: Self.objectWithTaggedPayloadUnionSchema)
        let unresolved = try #require(files.first { $0.name == "Unresolved.generated.swift" }).contents
        #expect(unresolved.contains("public typealias Change = JSONValue"))
    }

    @Test func objectValueUnionClassifiesAndEmits() throws {
        let files = try SchemaGenerator().generate(schemaJSON: Self.objectValueUnionSchema)
        let models = try #require(files.first { $0.name == "Models.generated.swift" }).contents
        #expect(models.contains("public struct Choice: Codable, Hashable, Sendable"))
        #expect(models.contains("public enum Value: Codable, Hashable, Sendable"))
        #expect(models.contains("case boolean(Bool)"))
        #expect(models.contains("case text(String)"))
        #expect(models.contains("public var id: String"))
    }

    @Test func objectValueUnionFiltersTheBareUnknownFallback() throws {
        // The string-enum and tagged-union stages read their variants through
        // `unionVariants(of:)`, which drops the schema's explicit
        // unknown-discriminator catch-all because each of those emitters
        // synthesizes its own fallback. The value-union stage must read them
        // the same way: a catch-all declaring nothing beyond the pinned
        // discriminator has no `value` member, so reading raw `anyOf` here
        // would reject a union its sibling stages accept.
        let files = try SchemaGenerator().generate(schemaJSON: Self.objectValueUnionWithBareFallbackSchema)
        let models = try #require(files.first { $0.name == "Models.generated.swift" }).contents
        #expect(models.contains("public struct Choice: Codable, Hashable, Sendable"))
        #expect(models.contains("public enum Value: Codable, Hashable, Sendable"))
        #expect(models.contains("case boolean(Bool)"))
        #expect(models.contains("case text(String)"))
        // The catch-all is not a case of its own, under its title or otherwise.
        #expect(!models.contains("case other"))
    }

    @Test func discriminatedUnionWithoutDefaultFailsLoudly() throws {
        // Every variant is discriminated; there is no discriminator-less
        // default to select when `type` is absent.
        let schema = Data(
            """
            {
              "$defs": {
                "Alpha": { "type": "object", "properties": { "x": { "type": "string" } }, "required": ["x"] },
                "Beta": { "type": "object", "properties": { "y": { "type": "string" } }, "required": ["y"] },
                "Thing": {
                  "anyOf": [
                    { "type": "object", "properties": { "type": { "type": "string", "const": "a" } }, "required": ["type"], "allOf": [{ "$ref": "#/$defs/Alpha" }] },
                    { "type": "object", "properties": { "type": { "type": "string", "const": "b" } }, "required": ["type"], "allOf": [{ "$ref": "#/$defs/Beta" }] }
                  ]
                }
              }
            }
            """.utf8)
        #expect(throws: GeneratorError.self) {
            _ = try SchemaGenerator().generate(schemaJSON: schema)
        }
    }

    @Test func discriminatedVariantWithoutPayloadRefFailsLoudly() throws {
        // A discriminated variant that carries no `$ref` payload cannot be
        // modeled as a flattened case.
        let schema = Data(
            """
            {
              "$defs": {
                "Beta": { "type": "object", "properties": { "y": { "type": "string" } }, "required": ["y"] },
                "Thing": {
                  "anyOf": [
                    { "type": "object", "properties": { "type": { "type": "string", "const": "a" } }, "required": ["type"] },
                    { "title": "beta", "allOf": [{ "$ref": "#/$defs/Beta" }] }
                  ]
                }
              }
            }
            """.utf8)
        #expect(throws: GeneratorError.self) {
            _ = try SchemaGenerator().generate(schemaJSON: schema)
        }
    }

    @Test func objectValueUnionWithoutDefaultFailsLoudly() throws {
        // Both value variants are discriminated, leaving no default to absorb
        // an absent or unknown discriminator.
        let schema = Data(
            """
            {
              "$defs": {
                "Choice": {
                  "type": "object",
                  "properties": { "id": { "type": "string" } },
                  "required": ["id"],
                  "anyOf": [
                    { "type": "object", "properties": { "value": { "type": "boolean" }, "type": { "type": "string", "const": "boolean" } }, "required": ["type", "value"] },
                    { "type": "object", "properties": { "value": { "type": "integer" }, "type": { "type": "string", "const": "number" } }, "required": ["type", "value"] }
                  ]
                }
              }
            }
            """.utf8)
        #expect(throws: GeneratorError.self) {
            _ = try SchemaGenerator().generate(schemaJSON: schema)
        }
    }

    /// A miniature ACP v2-shaped tagged union: one discriminated `$ref`
    /// payload variant plus the schema's explicit unknown-discriminator
    /// catch-all, which `not`-excludes every known tag.
    private static let explicitUnknownVariantSchema = Data(
        """
        {
          "$defs": {
            "Alpha": {
              "type": "object",
              "properties": { "x": { "type": "string" } },
              "required": ["x"]
            },
            "Thing": {
              "anyOf": [
                {
                  "type": "object",
                  "properties": { "type": { "type": "string", "const": "alpha" } },
                  "required": ["type"],
                  "allOf": [{ "$ref": "#/$defs/Alpha" }]
                },
                {
                  "title": "other",
                  "type": "object",
                  "properties": { "type": { "type": "string" } },
                  "required": ["type"],
                  "not": {
                    "anyOf": [
                      {
                        "type": "object",
                        "properties": { "type": { "type": "string", "const": "alpha" } },
                        "required": ["type"]
                      }
                    ]
                  },
                  "additionalProperties": true
                }
              ]
            }
          }
        }
        """.utf8)

    /// A tagged union whose catch-all requires members beyond the
    /// discriminator — ACP v2's `AuthMethod` shape.
    private static let payloadBearingUnknownVariantSchema = Data(
        """
        {
          "$defs": {
            "Alpha": {
              "type": "object",
              "properties": { "x": { "type": "string" } },
              "required": ["x"]
            },
            "Thing": {
              "anyOf": [
                {
                  "type": "object",
                  "properties": { "type": { "type": "string", "const": "alpha" } },
                  "required": ["type"],
                  "allOf": [{ "$ref": "#/$defs/Alpha" }]
                },
                {
                  "title": "other",
                  "type": "object",
                  "properties": {
                    "type": { "type": "string" },
                    "methodId": { "type": "string" },
                    "name": { "type": "string" }
                  },
                  "required": ["type", "methodId", "name"],
                  "not": {
                    "anyOf": [
                      {
                        "type": "object",
                        "properties": { "type": { "type": "string", "const": "alpha" } },
                        "required": ["type"]
                      }
                    ]
                  },
                  "additionalProperties": true
                }
              ]
            }
          }
        }
        """.utf8)

    /// A value union whose default variant declares the discriminator without
    /// pinning it. The emitter's default case writes only the value member, so
    /// this shape cannot round-trip and must be rejected.
    private static let valueUnionDefaultWithDiscriminatorSchema = Data(
        """
        {
          "$defs": {
            "Choice": {
              "type": "object",
              "properties": { "id": { "type": "string" } },
              "required": ["id"],
              "anyOf": [
                {
                  "type": "object",
                  "properties": { "value": { "type": "boolean" }, "type": { "type": "string", "const": "boolean" } },
                  "required": ["type", "value"]
                },
                {
                  "title": "other",
                  "type": "object",
                  "properties": { "value": { "description": "Raw value payload." }, "type": { "type": "string" } },
                  "required": ["type", "value"]
                }
              ]
            }
          }
        }
        """.utf8)

    /// A base object that also carries a tagged union whose variants flatten
    /// `$ref` payloads — ACP v2's `DiffChange` shape, which has no emission
    /// model yet.
    private static let objectWithTaggedPayloadUnionSchema = Data(
        """
        {
          "$defs": {
            "Alpha": {
              "type": "object",
              "properties": { "x": { "type": "string" } },
              "required": ["x"]
            },
            "Change": {
              "type": "object",
              "properties": { "id": { "type": "string" } },
              "required": ["id"],
              "anyOf": [
                {
                  "type": "object",
                  "properties": { "operation": { "type": "string", "const": "add" } },
                  "required": ["operation"],
                  "allOf": [{ "$ref": "#/$defs/Alpha" }]
                },
                {
                  "title": "other",
                  "type": "object",
                  "properties": { "operation": { "type": "string" } },
                  "required": ["operation"],
                  "not": {
                    "anyOf": [
                      {
                        "type": "object",
                        "properties": { "operation": { "type": "string", "const": "add" } },
                        "required": ["operation"]
                      }
                    ]
                  },
                  "additionalProperties": true
                }
              ]
            }
          }
        }
        """.utf8)

    /// The object-with-value-union shape closed by the schema's explicit
    /// unknown-discriminator catch-all, which declares nothing beyond the
    /// pinned discriminator and so carries no `value` member.
    private static let objectValueUnionWithBareFallbackSchema = Data(
        """
        {
          "$defs": {
            "Choice": {
              "type": "object",
              "properties": { "id": { "type": "string" } },
              "required": ["id"],
              "anyOf": [
                {
                  "type": "object",
                  "properties": { "value": { "type": "boolean" }, "type": { "type": "string", "const": "boolean" } },
                  "required": ["type", "value"]
                },
                {
                  "title": "text",
                  "type": "object",
                  "properties": { "value": { "type": "string" } },
                  "required": ["value"]
                },
                {
                  "title": "other",
                  "type": "object",
                  "properties": { "type": { "type": "string" } },
                  "required": ["type"],
                  "not": {
                    "anyOf": [
                      {
                        "type": "object",
                        "properties": { "type": { "type": "string", "const": "boolean" } },
                        "required": ["type"]
                      }
                    ]
                  },
                  "additionalProperties": true
                }
              ]
            }
          }
        }
        """.utf8)

    /// A miniature object-with-value-union schema: a base `id` plus a boolean
    /// discriminated variant and a discriminator-less `text` default.
    private static let objectValueUnionSchema = Data(
        """
        {
          "$defs": {
            "Choice": {
              "type": "object",
              "properties": { "id": { "type": "string" } },
              "required": ["id"],
              "anyOf": [
                {
                  "type": "object",
                  "properties": { "value": { "type": "boolean" }, "type": { "type": "string", "const": "boolean" } },
                  "required": ["type", "value"]
                },
                {
                  "title": "text",
                  "type": "object",
                  "properties": { "value": { "type": "string" } },
                  "required": ["value"]
                }
              ]
            }
          }
        }
        """.utf8)
}
