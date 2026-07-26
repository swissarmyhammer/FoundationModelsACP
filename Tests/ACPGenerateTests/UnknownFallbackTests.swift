import Foundation
import Testing

@testable import ACPGenerateCore

/// Tests the string-enum generator stage and the `unknown(String)` fallback.
///
/// snake_case wire strings map to camelCase Swift cases, and any value a
/// newer peer sends routes to `unknown(String)` instead of failing decode.
@Suite struct UnknownFallbackEmissionTests {
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
