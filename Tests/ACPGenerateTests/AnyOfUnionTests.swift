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
///
/// **Where the cover lives in the catch-all filtering tests.** Each of them
/// carries the schema's explicit unknown-discriminator variant, titled
/// `other`, and asserts that generation accepts the union. The regression
/// cover is the `try` performing generation, not the expectations after it:
/// revert any stage to a raw `anyOf` read and generation throws at that
/// stage's first use of the unfiltered catch-all, before an expectation is
/// evaluated. The expectations are downstream shape pins on what the accepted
/// union emits.
///
/// Generation below passes an explicit empty `GeneratorConfig()` rather than
/// `SchemaGenerator`'s `.acpV2` default: `.acpV2` carries a
/// `patchSemanticsFields` table validated against the schema being
/// generated, and these inline fixtures do not declare the ACP v2 types that
/// table names.
///
/// So none of these tests carries a `!contains("case other")` negative. Two
/// did; both were vacuous, because every route to an emitted `case other`
/// throws upstream, and each was reachable only behind several simultaneous
/// production mutations. They are gone rather than reading as cover they never
/// provided.
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
        let files = try SchemaGenerator(config: GeneratorConfig()).generate(schemaJSON: schema)
        let unions = try #require(files.first { $0.name == "Unions.generated.swift" }).contents
        #expect(unions.contains("public enum Thing: Codable, Hashable, Sendable"))
        #expect(unions.contains("case alpha(Alpha)"))
        #expect(unions.contains("case beta(Beta)"))
        // The discriminated family gets the same Tag-enum treatment as its
        // tagged-union and value-union siblings: the tag is written once, as
        // the `Tag` enum's raw value, and both decode and encode read it back
        // instead of each carrying their own copy of `"alpha"`. `beta` is the
        // discriminator-less default, so it has no `Tag` case of its own.
        #expect(unions.contains("private enum Tag: String {"))
        #expect(unions.contains("case alpha = \"alpha\""))
        #expect(unions.contains("case Tag.alpha.rawValue?:"))
        #expect(unions.contains("try container.encode(Tag.alpha.rawValue, forKey: .type)"))
        let unresolved = try #require(files.first { $0.name == "Unresolved.generated.swift" }).contents
        #expect(!unresolved.contains("typealias Thing"))
    }

    @Test func discriminatedUnionFiltersTheBareUnknownFallback() throws {
        // Every union stage reads its variants through `unionVariants(of:)`,
        // which drops the schema's explicit unknown-discriminator catch-all.
        // The discriminated stage needs that filtering as much as its
        // siblings: the catch-all flattens no `$ref` payload, so reading raw
        // `anyOf` here rejects — at `discriminatedPayloadType`, before the
        // default-variant test is ever reached — a union whose modeled
        // variants are perfectly well formed.
        let files = try SchemaGenerator(config: GeneratorConfig()).generate(schemaJSON: Self.discriminatedUnionWithBareFallbackSchema)
        let unions = try #require(files.first { $0.name == "Unions.generated.swift" }).contents
        #expect(unions.contains("public enum Thing: Codable, Hashable, Sendable"))
        #expect(unions.contains("case alpha(Alpha)"))
        #expect(unions.contains("case beta(Beta)"))
        let unresolved = try #require(files.first { $0.name == "Unresolved.generated.swift" }).contents
        #expect(!unresolved.contains("typealias Thing"))
    }

    @Test func unknownVariantPinningItsOwnDiscriminatorStaysDeferred() throws {
        // A catch-all is the variant that says "a tag this revision does not
        // list", so it declares the discriminator *unpinned*. One that pins a
        // `const` of its own is naming a tag, which contradicts its `not`, and
        // it must not be mistaken for the bare catch-all: were it filtered
        // away, the member it pins would leave the union's discriminator
        // evidence with it, and a union whose variants key on two different
        // members would be accepted with the second variant silently
        // unmodeled. The whole definition defers to raw JSON instead, which is
        // lossless.
        let files = try SchemaGenerator(config: GeneratorConfig()).generate(schemaJSON: Self.valueUnionWithConstPinningFallbackSchema)
        let unresolved = try #require(files.first { $0.name == "Unresolved.generated.swift" }).contents
        #expect(unresolved.contains("public typealias Choice = JSONValue"))
        let models = try #require(files.first { $0.name == "Models.generated.swift" }).contents
        #expect(!models.contains("public struct Choice"))
    }

    @Test func explicitUnknownVariantBecomesTheSynthesizedFallback() throws {
        // ACP v2 spells the unknown case out in the schema: a final variant
        // whose `not` excludes every known discriminator and which accepts
        // any additional properties. That is the `unknown` case the emitter
        // already synthesizes, so it must not be modeled as a variant of its
        // own.
        //
        // Reverting `taggedUnionModel` to a raw `anyOf` read throws
        // `discriminator type has no const value` at the catch-all.
        let files = try SchemaGenerator(config: GeneratorConfig()).generate(schemaJSON: Self.explicitUnknownVariantSchema)
        let unions = try #require(files.first { $0.name == "Unions.generated.swift" }).contents
        #expect(unions.contains("public enum Thing: Codable, Hashable, Sendable"))
        #expect(unions.contains("case alpha(Alpha)"))
        #expect(unions.contains("case unknown(String, JSONValue)"))
        let unresolved = try #require(files.first { $0.name == "Unresolved.generated.swift" }).contents
        #expect(!unresolved.contains("typealias Thing"))
    }

    @Test func unknownVariantCarryingPayloadKeepsItOnTheFallback() throws {
        // ACP v2's `AuthMethod` catch-all requires `methodId` and `name`
        // alongside the unrecognized tag, and its own description says clients
        // "should preserve the raw payload when storing, replaying, proxying,
        // or forwarding". The synthesized fallback takes the raw object beside
        // the tag, so those members survive and the union is modeled rather
        // than deferred to raw JSON wholesale.
        let files = try SchemaGenerator(config: GeneratorConfig()).generate(schemaJSON: Self.payloadBearingUnknownVariantSchema)
        let unions = try #require(files.first { $0.name == "Unions.generated.swift" }).contents
        #expect(unions.contains("public enum Thing: Codable, Hashable, Sendable"))
        #expect(unions.contains("case alpha(Alpha)"))
        #expect(unions.contains("case unknown(String, JSONValue)"))
        let unresolved = try #require(files.first { $0.name == "Unresolved.generated.swift" }).contents
        #expect(!unresolved.contains("typealias Thing"))
    }

    @Test func valueUnionDefaultDeclaringTheDiscriminatorCapturesIt() throws {
        // A default variant that *declares* the discriminator without pinning
        // it is selected by any unrecognized tag, so its emitted case takes
        // that tag as a leading associated value and re-encodes it beside the
        // value. Writing the value alone would round-trip to JSON missing a
        // member the schema requires, which is why this shape was rejected
        // while the default carried one associated value.
        let files = try SchemaGenerator(config: GeneratorConfig()).generate(schemaJSON: Self.valueUnionDefaultWithDiscriminatorSchema)
        let models = try #require(files.first { $0.name == "Models.generated.swift" }).contents
        #expect(models.contains("case other(String, JSONValue)"))
    }

    @Test func valueUnionCatchAllCarryingAValueBecomesTheDefaultCase() throws {
        // ACP v2's `SetSessionConfigOptionRequest` shape: the catch-all
        // re-declares the discriminator *unpinned* beside the very `value` the
        // union is built around. That is not new payload — the modeled
        // variants declare both members already — so the definition is modeled
        // rather than deferred, with the catch-all becoming the tag-capturing
        // default case.
        let files = try SchemaGenerator(config: GeneratorConfig()).generate(schemaJSON: Self.valueUnionWithPayloadCatchAllSchema)
        let models = try #require(files.first { $0.name == "Models.generated.swift" }).contents
        #expect(models.contains("public struct Choice: Codable, Hashable, Sendable"))
        #expect(models.contains("case boolean(Bool)"))
        #expect(models.contains("case other(String, JSONValue)"))
        let unresolved = try #require(files.first { $0.name == "Unresolved.generated.swift" }).contents
        #expect(!unresolved.contains("typealias Choice"))
    }

    @Test func objectCarryingATaggedPayloadUnionEmitsANestedPayload() throws {
        // A base object whose variants flatten `$ref` payloads is neither a
        // plain tagged union nor the object-plus-`value`-union shape: the
        // payload sits beside the base members rather than under a `value`
        // key. It emits as the base struct with a nested `Payload` enum whose
        // own Codable flattens into the same object.
        let files = try SchemaGenerator(config: GeneratorConfig()).generate(schemaJSON: Self.objectWithTaggedPayloadUnionSchema)
        let models = try #require(files.first { $0.name == "Models.generated.swift" }).contents
        #expect(models.contains("public struct Change: Codable, Hashable, Sendable"))
        #expect(models.contains("    public enum Payload: Codable, Hashable, Sendable {"))
        #expect(models.contains("        case add(Alpha)"))
        #expect(models.contains("        case unknown(String, JSONValue)"))
        #expect(models.contains("    public var operation: Payload"))
        #expect(models.contains("    public var id: String"))
        // The base members travel beside the payload, so they are not part of
        // an unrecognized variant's capture — re-encoding them from both the
        // struct and the captured payload is how a stale copy wins. Both the
        // decode and encode arms read the same `excludedMembers` constant
        // rather than each carrying its own copy of the literal.
        #expect(models.contains(#"private static let excludedMembers = ["operation", "id"]"#))
        #expect(models.contains("try JSONValue(from: decoder, excludingMembers: Self.excludedMembers)"))
        #expect(models.contains("encodeMembers(to: encoder, reserving: Self.excludedMembers)"))
        let unresolved = try #require(files.first { $0.name == "Unresolved.generated.swift" }).contents
        #expect(!unresolved.contains("typealias Change"))
    }

    @Test func objectValueUnionClassifiesAndEmits() throws {
        let files = try SchemaGenerator(config: GeneratorConfig()).generate(schemaJSON: Self.objectValueUnionSchema)
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
        //
        // Reverting that filtering throws `expected exactly one
        // non-discriminator value member` at the catch-all.
        let files = try SchemaGenerator(config: GeneratorConfig()).generate(schemaJSON: Self.objectValueUnionWithBareFallbackSchema)
        let models = try #require(files.first { $0.name == "Models.generated.swift" }).contents
        #expect(models.contains("public struct Choice: Codable, Hashable, Sendable"))
        #expect(models.contains("public enum Value: Codable, Hashable, Sendable"))
        #expect(models.contains("case boolean(Bool)"))
        #expect(models.contains("case text(String)"))
    }

    @Test func aUnionMemberCollidingWithABasePropertyFailsLoudly() throws {
        // Both object-carrying-a-union stages write the union through a second
        // keyed container over the same encoder, which shares one object with
        // the struct's own. A name on both sides is written twice and the later
        // write wins, so the two can disagree on the wire — and the struct's
        // Swift property and the union's would disagree in memory as well.
        // Reject the shape rather than emit it.
        for schema in [Self.valueUnionCollidingWithBaseSchema, Self.taggedPayloadUnionCollidingWithBaseSchema] {
            let error = #expect(throws: GeneratorError.self) {
                _ = try SchemaGenerator(config: GeneratorConfig()).generate(schemaJSON: schema)
            }
            // Pinned, because "it threw" would also be satisfied by the shape
            // being rejected somewhere upstream for an unrelated reason.
            #expect(try #require(error).description.contains("collides with a base property of the same name"))
        }
    }

    @Test func aValueMemberThatIsNotAnIdentifierFailsLoudly() throws {
        // The nested enum takes its name from the value member. Every other
        // emitted name is validated at the generator boundary, so this one is
        // too: `public enum Foo-bar` would otherwise fail at `swiftc`, well
        // past the point where the schema shape is still in view.
        let error = #expect(throws: GeneratorError.self) {
            _ = try SchemaGenerator(config: GeneratorConfig()).generate(schemaJSON: Self.valueUnionWithUnusableMemberNameSchema)
        }
        #expect(try #require(error).description.contains("does not map to a plain Swift identifier"))
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
            _ = try SchemaGenerator(config: GeneratorConfig()).generate(schemaJSON: schema)
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
            _ = try SchemaGenerator(config: GeneratorConfig()).generate(schemaJSON: schema)
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
            _ = try SchemaGenerator(config: GeneratorConfig()).generate(schemaJSON: schema)
        }
    }

    /// A value union whose base object already declares the discriminator.
    private static let valueUnionCollidingWithBaseSchema = Data(
        """
        {
          "$defs": {
            "Choice": {
              "type": "object",
              "properties": { "type": { "type": "string" } },
              "required": ["type"],
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

    /// A tagged-payload union whose base object already declares the
    /// discriminator.
    private static let taggedPayloadUnionCollidingWithBaseSchema = Data(
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
              "properties": { "operation": { "type": "string" } },
              "required": ["operation"],
              "anyOf": [
                {
                  "type": "object",
                  "properties": { "operation": { "type": "string", "const": "add" } },
                  "required": ["operation"],
                  "allOf": [{ "$ref": "#/$defs/Alpha" }]
                }
              ]
            }
          }
        }
        """.utf8)

    /// A value union whose value member does not map to a Swift identifier, so
    /// the nested enum it would name cannot be emitted.
    private static let valueUnionWithUnusableMemberNameSchema = Data(
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
                  "properties": { "value-of": { "type": "boolean" }, "type": { "type": "string", "const": "boolean" } },
                  "required": ["type", "value-of"]
                },
                {
                  "title": "text",
                  "type": "object",
                  "properties": { "value-of": { "type": "string" } },
                  "required": ["value-of"]
                }
              ]
            }
          }
        }
        """.utf8)

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

    /// A discriminated `$ref`-payload union — one tagged variant plus a
    /// discriminator-less default — closed by the schema's explicit
    /// unknown-discriminator catch-all, which flattens no payload.
    private static let discriminatedUnionWithBareFallbackSchema = Data(
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
                { "title": "beta", "allOf": [{ "$ref": "#/$defs/Beta" }] },
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

    /// A value union whose `not` variant pins a `const` of its own, on a
    /// *different* member than the union's discriminator. Self-contradictory
    /// as schema, and the one shape where mistaking it for the bare catch-all
    /// would take the disagreeing member out of the discriminator evidence.
    private static let valueUnionWithConstPinningFallbackSchema = Data(
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
                  "properties": { "kind": { "type": "string", "const": "unrecognized" } },
                  "required": ["kind"],
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

    /// A tagged union whose catch-all requires members beyond the
    /// discriminator — ACP v2's `AuthMethod` shape. The fallback must keep
    /// them.
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
    /// pinning it, and without a `not` marking it as the schema's catch-all.
    /// The emitted default case captures the tag it matched so both members
    /// round-trip.
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

    /// ACP v2's `SetSessionConfigOptionRequest` shape: a base object plus a
    /// value union closed by the schema's explicit unknown-discriminator
    /// catch-all, which re-declares the discriminator *unpinned* beside the
    /// union's own `value` member.
    private static let valueUnionWithPayloadCatchAllSchema = Data(
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
                  "properties": { "type": { "type": "string" }, "value": { "description": "Raw value payload." } },
                  "required": ["type", "value"],
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

    /// A base object that also carries a tagged union whose variants flatten
    /// `$ref` payloads — ACP v2's `DiffChange` and `SessionConfigOption` shape.
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
