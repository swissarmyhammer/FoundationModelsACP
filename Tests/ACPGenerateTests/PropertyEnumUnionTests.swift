import Foundation
import Testing

@testable import ACPGenerateCore

/// Tests the property-enum union: an object definition whose `anyOf` variants
/// pin `const` values on one of the object's own declared properties, with an
/// optional `$ref` payload that a variant flattens beside the object's members
/// (ACP v2's `IdleStateUpdate` shape, where `stopReason` selects the variant
/// and the `error` variant adds an `error` member).
///
/// Every case is driven by an inline synthetic schema, so the shapes are named
/// `Idle` / `Reason` / `FailureDetail` rather than after any vendored
/// definition. Generation passes an explicit empty `GeneratorConfig()`, for
/// the reason `FlattenedScopeUnionTests` states.
@Suite struct PropertyEnumUnionTests {
    @Test func propertyEnumUnionEmitsAnEnumForTheProperty() throws {
        let files = try Self.generate(Self.schema())
        let unions = try Self.contents(of: "Unions.generated.swift", in: files)
        #expect(unions.contains("public enum Reason: Codable, Hashable, Sendable {"))
        #expect(unions.contains("    case done\n"))
        #expect(unions.contains("    case failed\n"))
        #expect(unions.contains("    case unknown(String)"))
        #expect(unions.contains("    /// The work failed."))
    }

    @Test func propertyEnumUnionEmitsAStructWithTheFlattenedPayloadMembers() throws {
        let files = try Self.generate(Self.schema())
        let models = try Self.contents(of: "Models.generated.swift", in: files)
        #expect(models.contains("public struct Idle: Codable, Hashable, Sendable {"))
        #expect(models.contains("    public var reason: Reason?"))
        #expect(models.contains("    public var failure: Failure?"))
        #expect(models.contains("self.reason = container.forgivingDecodeIfPresent(Reason.self, forKey: .reason)"))
        #expect(models.contains("self.failure = container.forgivingDecodeIfPresent(Failure.self, forKey: .failure)"))
        let unresolved = try Self.contents(of: "Unresolved.generated.swift", in: files)
        #expect(!unresolved.contains("typealias Idle"))
    }

    @Test func requiredPayloadMemberFailsLoudly() throws {
        // A flattened member is optional on the object, because only one
        // variant carries it. A payload that requires it states a rule the
        // optional property cannot keep.
        #expect(
            throws: GeneratorError.unsupportedShape(
                context: "Idle variant 1",
                detail: "flattened payload FailureDetail requires failure; a variant payload's members must be optional"
            )
        ) {
            _ = try Self.generate(Self.schema(payloadRequired: #"["failure"]"#))
        }
    }

    @Test func payloadMemberThatCollidesWithABasePropertyFailsLoudly() throws {
        #expect(
            throws: GeneratorError.unsupportedShape(
                context: "Idle",
                detail: "the union's note collides with a base property of the same name"
            )
        ) {
            _ = try Self.generate(Self.schema(payloadMember: "note"))
        }
    }

    @Test func enumNameThatCollidesWithADefinitionFailsLoudly() throws {
        #expect(
            throws: GeneratorError.unsupportedShape(
                context: "Idle",
                detail: "the enum for reason would be named Reason, which a definition already emits"
            )
        ) {
            _ = try Self.generate(Self.schema(extraDefinitions: #""Reason": { "type": "string" },"#))
        }
    }

    @Test func payloadMemberWithADefaultFailsLoudly() throws {
        // A default makes the member non-optional, so every variant would
        // encode it, also a variant that does not carry the payload.
        #expect(
            throws: GeneratorError.unsupportedShape(
                context: "Idle variant 1",
                detail: "flattened payload FailureDetail gives failure a default; a variant payload's members must be optional"
            )
        ) {
            _ = try Self.generate(Self.schema(payloadDefault: #", "default": { "code": 1 }"#))
        }
    }

    @Test func twoPayloadsThatDeclareOneMemberFailLoudly() throws {
        #expect(
            throws: GeneratorError.unsupportedShape(
                context: "Idle",
                detail: "two variant payloads declare failure"
            )
        ) {
            _ = try Self.generate(Self.schema(donePayload: ##", "allOf": [{ "$ref": "#/$defs/FailureDetail" }]"##))
        }
    }

    @Test func pinnedPropertyThatIsNotAStringFailsLoudly() throws {
        #expect(
            throws: GeneratorError.unsupportedShape(
                context: "Idle",
                detail: "the pinned property reason must be a plain string with no default"
            )
        ) {
            _ = try Self.generate(Self.schema(reasonType: #""integer""#))
        }
    }

    @Test func twoDefinitionsThatPinOnePropertyNameFailLoudly() throws {
        // Each definition makes an enum named for the property, so the two
        // enums would be two declarations of one Swift type.
        let other = """
            "Other": {
              "type": "object",
              "properties": { "reason": { "type": "string" } },
              "anyOf": [
                { "type": "object", "properties": { "reason": { "type": "string", "const": "x" } }, "required": ["reason"] }
              ]
            },
            """
        #expect(
            throws: GeneratorError.unsupportedShape(context: "Reason", detail: "two declarations have this name")
        ) {
            _ = try Self.generate(Self.schema(extraDefinitions: other))
        }
    }

    @Test func variantThatNeitherPinsNorNullsThePropertyFailsLoudly() throws {
        let error = #expect(throws: GeneratorError.self) {
            _ = try Self.generate(Self.schema(noneVariantType: "integer"))
        }
        #expect(try #require(error).description.contains("Idle variant 2"))
    }

    /// Generates Swift from a synthetic schema with an empty configuration.
    ///
    /// - Parameter schema: The schema document.
    /// - Returns: The generated files.
    /// - Throws: The generator's error.
    private static func generate(_ schema: Data) throws -> [GeneratedFile] {
        try SchemaGenerator(config: GeneratorConfig()).generate(schemaJSON: schema)
    }

    /// The contents of one generated file.
    ///
    /// - Parameters:
    ///   - name: The generated file name.
    ///   - files: The generated files.
    /// - Returns: The file's source text.
    /// - Throws: A test failure when no file has that name.
    private static func contents(of name: String, in files: [GeneratedFile]) throws -> String {
        try #require(files.first { $0.name == name }).contents
    }

    /// The `IdleStateUpdate` shape: a `reason` property, one `const` variant
    /// per value, a `failed` variant that flattens a payload, the `not`
    /// catch-all, and a variant that sets `reason` to null.
    ///
    /// - Parameters:
    ///   - payloadMember: The member the flattened payload declares.
    ///   - payloadRequired: The payload's `required` array.
    ///   - payloadDefault: More keywords for the payload member, each after a
    ///     comma.
    ///   - reasonType: The `type` the object gives `reason`.
    ///   - donePayload: More keywords for the `done` variant, each after a
    ///     comma.
    ///   - noneVariantType: The `type` the last variant gives `reason`.
    ///   - extraDefinitions: More definitions, each followed by a comma.
    /// - Returns: The schema document.
    private static func schema(
        payloadMember: String = "failure",
        payloadRequired: String = "[]",
        payloadDefault: String = "",
        reasonType: String = #"["string", "null"]"#,
        donePayload: String = "",
        noneVariantType: String = "null",
        extraDefinitions: String = ""
    ) -> Data {
        Data(
            """
            {
              "$defs": {
                \(extraDefinitions)
                "Failure": {
                  "type": "object",
                  "properties": { "code": { "type": "integer" } },
                  "required": ["code"]
                },
                "FailureDetail": {
                  "type": "object",
                  "properties": {
                    "\(payloadMember)": {
                      "anyOf": [{ "$ref": "#/$defs/Failure" }, { "type": "null" }],
                      "x-deserialize-default-on-error": true\(payloadDefault)
                    }
                  },
                  "required": \(payloadRequired)
                },
                "Idle": {
                  "type": "object",
                  "properties": {
                    "note": { "type": ["string", "null"] },
                    "reason": { "type": \(reasonType), "x-deserialize-default-on-error": true }
                  },
                  "anyOf": [
                    {
                      "description": "The work is done.",
                      "type": "object",
                      "properties": { "reason": { "type": "string", "const": "done" } },
                      "required": ["reason"]\(donePayload)
                    },
                    {
                      "description": "The work failed.",
                      "type": "object",
                      "properties": { "reason": { "type": "string", "const": "failed" } },
                      "required": ["reason"],
                      "allOf": [{ "$ref": "#/$defs/FailureDetail" }]
                    },
                    {
                      "title": "other",
                      "type": "object",
                      "properties": { "reason": { "type": "string" } },
                      "required": ["reason"],
                      "not": {
                        "anyOf": [
                          { "type": "object", "properties": { "reason": { "const": "done" } }, "required": ["reason"] },
                          { "type": "object", "properties": { "reason": { "const": "failed" } }, "required": ["reason"] }
                        ]
                      }
                    },
                    {
                      "title": "none",
                      "type": "object",
                      "properties": { "reason": { "type": "\(noneVariantType)" } }
                    }
                  ]
                }
              }
            }
            """.utf8
        )
    }
}
