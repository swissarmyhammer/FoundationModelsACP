import Foundation
import Testing

@testable import ACPGenerateCore

/// Tests the `anyOf` generator stage that resolves discriminated unions and
/// objects carrying a value union.
///
/// `McpServer` becomes a tagged enum with a discriminator-less default variant;
/// `SetSessionConfigOptionRequest` becomes a struct with a nested value union.
/// The remaining `anyOf` definitions stay deferred as placeholder seams.
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

    @Test func objectValueUnionClassifiesAndEmits() throws {
        let files = try SchemaGenerator().generate(schemaJSON: Self.objectValueUnionSchema)
        let models = try #require(files.first { $0.name == "Models.generated.swift" }).contents
        #expect(models.contains("public struct Choice: Codable, Hashable, Sendable"))
        #expect(models.contains("public enum Value: Codable, Hashable, Sendable"))
        #expect(models.contains("case boolean(Bool)"))
        #expect(models.contains("case text(String)"))
        #expect(models.contains("public var id: String"))
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
