import Foundation
import Testing

@testable import ACPGenerateCore

/// Tests the string-enum generator stage and the `unknown(String)` fallback.
///
/// snake_case wire strings map to camelCase Swift cases, and any value a
/// newer peer sends routes to `unknown(String)` instead of failing decode.
@Suite struct UnknownFallbackEmissionTests {
    @Test func anyOfStringEnumWithOpenTailEmitsAnEnum() throws {
        // ACP v2 writes string enums as `anyOf` and closes them with an
        // unconstrained `type: "string"` variant standing for the values a
        // newer peer may send. That tail is the emitter's `unknown(String)`,
        // not a case of its own, and its presence must not demote the whole
        // definition to a raw-JSON placeholder.
        let schema = Data(
            """
            {
              "$defs": {
                "StopReason": {
                  "anyOf": [
                    { "type": "string", "const": "end_turn", "description": "The turn ended." },
                    { "type": "string", "const": "cancelled" },
                    { "title": "other", "type": "string", "description": "A reason this revision does not list." }
                  ]
                }
              }
            }
            """.utf8)
        let files = try SchemaGenerator().generate(schemaJSON: schema)
        let unions = try #require(files.first { $0.name == "Unions.generated.swift" }).contents
        #expect(unions.contains("public enum StopReason: Codable, Hashable, Sendable"))
        #expect(unions.contains("case endTurn"))
        #expect(unions.contains("case cancelled"))
        #expect(unions.contains("case unknown(String)"))
        #expect(!unions.contains("case other"))
        let unresolved = try #require(files.first { $0.name == "Unresolved.generated.swift" }).contents
        #expect(!unresolved.contains("typealias StopReason"))
    }

    @Test func quoteBearingWireValueEscapesInEmittedSource() throws {
        // `swiftCaseName` rejects such values at the generator boundary, but
        // the emitter must be safe on its own terms: a quote or backslash in
        // a wire value may never break out of the generated string literal.
        let model = StringEnumModel(
            name: "Weird",
            documentation: nil,
            cases: [EnumCaseModel(wireValue: #"a"b\c"#, swiftName: "aBC", documentation: nil)]
        )
        let source = Emitter.stringEnumDeclaration(model)
        #expect(source.contains(#"case .aBC: "a\"b\\c""#))
        #expect(source.contains(#"case "a\"b\\c": self = .aBC"#))
        #expect(!source.contains(#"case "a"b\c""#))
    }
}

/// Decodes wire JSON into a generated type.
///
/// - Parameters:
///   - type: The generated type to decode.
///   - json: The wire JSON, fragments allowed.
/// - Returns: The decoded value.
/// - Throws: Rethrows `DecodingError`.
private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

/// Encodes a generated value back to a wire JSON string.
///
/// - Parameter value: The value to encode.
/// - Returns: The encoded JSON text.
/// - Throws: Rethrows `EncodingError`.
