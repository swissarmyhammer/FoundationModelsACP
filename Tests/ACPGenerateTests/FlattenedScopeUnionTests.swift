import Foundation
import Testing

@testable import ACPGenerateCore

/// Tests the flattened untagged scope union — an object-typed definition whose
/// `anyOf` variants are single-`$ref` `allOf` wrappers with no `const`
/// discriminator, selected on the wire by which variant's required members are
/// present (ACP v2's `ElicitationFormMode` / `ElicitationUrlMode` shape).
///
/// Every case is driven by an inline synthetic schema, so the shapes are named
/// `Mode` / `SessionScope` / `RequestScope` rather than after any vendored
/// definition. Generation passes an explicit empty `GeneratorConfig()` rather
/// than `SchemaGenerator`'s `.acpV2` default: `.acpV2` carries a
/// `patchSemanticsFields` table validated against the schema being generated,
/// and these inline fixtures do not declare the ACP v2 types that table names.
@Suite struct FlattenedScopeUnionTests {
    @Test func flattenedScopeUnionClassifiesAndEmits() throws {
        let files = try SchemaGenerator(config: GeneratorConfig()).generate(schemaJSON: Self.flattenedScopeUnionSchema)
        let models = try #require(files.first { $0.name == "Models.generated.swift" }).contents
        #expect(models.contains("public struct Mode: Codable, Hashable, Sendable"))
        #expect(models.contains("    public enum Scope: Codable, Hashable, Sendable {"))
        #expect(models.contains("        case session(SessionScope)"))
        #expect(models.contains("        case request(RequestScope)"))
        #expect(models.contains("    public var scope: Scope"))
        // Decode selects the variant by its required keys, probed in schema
        // order: `sessionId` selects the session scope, `requestId` the
        // request scope.
        #expect(models.contains("if container.contains(.sessionId) {"))
        #expect(models.contains("} else if container.contains(.requestId) {"))
        #expect(models.contains("self = .session(try SessionScope(from: decoder))"))
        #expect(models.contains("self = .request(try RequestScope(from: decoder))"))
        // Encode flattens the selected variant's members into the enclosing
        // object: the wire object carries no nested `scope` key, so nothing
        // may encode under one.
        #expect(models.contains("try payload.encode(to: encoder)"))
        #expect(models.contains("try scope.encode(to: encoder)"))
        #expect(!models.contains("forKey: .scope"))
        let unresolved = try #require(files.first { $0.name == "Unresolved.generated.swift" }).contents
        #expect(!unresolved.contains("typealias Mode"))
    }

    @Test func scopeVariantsWithoutDisjointRequiredKeysFailLoudly() throws {
        // Decode probes the variants' required keys, so a key two variants
        // share would make the probe order — not the wire object — pick the
        // variant. The shape must fail loudly instead of decoding ambiguously.
        #expect(
            throws: GeneratorError.unsupportedShape(
                context: "Mode scope variant 1",
                detail: "scope variants' required members are not disjoint: sessionId"
            )
        ) {
            _ = try SchemaGenerator(config: GeneratorConfig()).generate(schemaJSON: Self.overlappingRequiredKeysSchema)
        }
    }

    @Test func scopeVariantWithoutARequiredKeyFailsLoudly() throws {
        // A variant whose referenced definition requires nothing gives decode
        // no member to probe, so no wire object could ever select it.
        let error = #expect(throws: GeneratorError.self) {
            _ = try SchemaGenerator(config: GeneratorConfig()).generate(schemaJSON: Self.unselectableScopeVariantSchema)
        }
        #expect(try #require(error).description.contains("declares no required member"))
    }

    /// The `ElicitationFormMode` shape: inline base properties plus an `anyOf`
    /// of single-`$ref` `allOf` wrappers whose referenced definitions require
    /// disjoint members.
    private static let flattenedScopeUnionSchema = Data(
        """
        {
          "$defs": {
            "SessionScope": {
              "type": "object",
              "properties": { "sessionId": { "type": "string" } },
              "required": ["sessionId"]
            },
            "RequestScope": {
              "type": "object",
              "properties": { "requestId": { "type": "string" } },
              "required": ["requestId"]
            },
            "Mode": {
              "type": "object",
              "properties": { "prompt": { "type": "string" } },
              "required": ["prompt"],
              "anyOf": [
                { "title": "Session", "allOf": [{ "$ref": "#/$defs/SessionScope" }] },
                { "title": "Request", "allOf": [{ "$ref": "#/$defs/RequestScope" }] }
              ]
            }
          }
        }
        """.utf8)

    /// A scope union whose two variants both require `sessionId`, so no probe
    /// order can tell them apart.
    private static let overlappingRequiredKeysSchema = Data(
        """
        {
          "$defs": {
            "SessionScope": {
              "type": "object",
              "properties": { "sessionId": { "type": "string" } },
              "required": ["sessionId"]
            },
            "OtherScope": {
              "type": "object",
              "properties": { "sessionId": { "type": "string" }, "other": { "type": "string" } },
              "required": ["sessionId", "other"]
            },
            "Mode": {
              "type": "object",
              "properties": { "prompt": { "type": "string" } },
              "required": ["prompt"],
              "anyOf": [
                { "title": "Session", "allOf": [{ "$ref": "#/$defs/SessionScope" }] },
                { "title": "Other", "allOf": [{ "$ref": "#/$defs/OtherScope" }] }
              ]
            }
          }
        }
        """.utf8)

    /// A scope union whose second variant's referenced definition requires no
    /// member at all, leaving decode nothing to probe.
    private static let unselectableScopeVariantSchema = Data(
        """
        {
          "$defs": {
            "SessionScope": {
              "type": "object",
              "properties": { "sessionId": { "type": "string" } },
              "required": ["sessionId"]
            },
            "EmptyScope": {
              "type": "object",
              "properties": { "note": { "type": "string" } }
            },
            "Mode": {
              "type": "object",
              "properties": { "prompt": { "type": "string" } },
              "required": ["prompt"],
              "anyOf": [
                { "title": "Session", "allOf": [{ "$ref": "#/$defs/SessionScope" }] },
                { "title": "Empty", "allOf": [{ "$ref": "#/$defs/EmptyScope" }] }
              ]
            }
          }
        }
        """.utf8)
}
