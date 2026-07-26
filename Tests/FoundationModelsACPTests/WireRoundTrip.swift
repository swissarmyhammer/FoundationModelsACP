import Foundation
import Testing

@testable import FoundationModelsACP

/// Decode-then-encode helpers shared by the runtime wire suites.
///
/// Every assertion in these suites is about *the wire*, so they compare parsed
/// JSON rather than text: object member order is not part of a JSON document's
/// value, and neither `JSONEncoder` nor the generated `encode(to:)` promises
/// one. Comparing `JSONValue` trees is what makes "byte-for-byte in content"
/// a testable claim.
enum WireRoundTrip {
    /// Parses a JSON literal.
    ///
    /// - Parameter json: The JSON document text.
    /// - Returns: The parsed value.
    /// - Throws: `DecodingError` when the text is not JSON.
    static func parse(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    /// Decodes a value from a JSON literal.
    ///
    /// - Parameters:
    ///   - type: The type to decode.
    ///   - json: The JSON document text.
    /// - Returns: The decoded value.
    /// - Throws: `DecodingError` when the text is not a valid encoding of the
    ///   type.
    static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    /// Encodes a value and reparses it as JSON.
    ///
    /// - Parameter value: The value to encode.
    /// - Returns: The encoded document, parsed.
    /// - Throws: `EncodingError` when the value cannot be encoded.
    static func encode(_ value: some Encodable) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    /// Decodes a JSON literal and asserts that re-encoding reproduces it.
    ///
    /// - Parameters:
    ///   - type: The type to decode.
    ///   - json: The JSON document text.
    ///   - sourceLocation: The caller, for failure reporting.
    /// - Returns: The decoded value, for further assertions.
    /// - Throws: `DecodingError` or `EncodingError` from either direction.
    @discardableResult
    static func expectLossless<T: Codable>(
        _ type: T.Type,
        _ json: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> T {
        let decoded = try decode(type, from: json)
        #expect(try encode(decoded) == parse(json), sourceLocation: sourceLocation)
        return decoded
    }
}

/// Navigation the suites need to assert on parsed wire JSON.
///
/// `JSONValue` deliberately exposes no accessors: it is a lossless carrier,
/// and the library never interprets one. Reaching into a decoded document is a
/// test's job, so the accessor lives here rather than widening the public API.
extension JSONValue {
    /// Looks up an object member by key.
    ///
    /// - Parameter key: The member name.
    /// - Returns: The member value, or `nil` when absent or not an object.
    subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members[key]
    }
}
