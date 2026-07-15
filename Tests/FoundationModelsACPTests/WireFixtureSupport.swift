import Foundation
import Testing

import FoundationModelsACP

// MARK: - Wire-conformance fixture helpers

/// Parses a JSON string fixture into a structural `JSONValue`.
///
/// Comparison against a `JSONValue` is order-independent for object keys,
/// so tests assert wire shape without depending on encoder key ordering.
///
/// - Parameter fixture: The raw JSON text.
/// - Returns: The parsed structural value.
/// - Throws: `DecodingError` when the fixture is not valid JSON.
func jsonValue(fixture: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(fixture.utf8))
}

/// Decodes a fixture string into a model of the requested type.
///
/// - Parameters:
///   - type: The model type to decode.
///   - fixture: The raw JSON text.
/// - Returns: The decoded model.
/// - Throws: `DecodingError` when the fixture does not satisfy the type.
func decoded<T: Decodable>(_ type: T.Type, fixture: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(fixture.utf8))
}

/// Encodes a model and re-parses the bytes into a structural `JSONValue`.
///
/// - Parameter value: The model to encode.
/// - Returns: The encoded wire shape as a structural value.
/// - Throws: Rethrows any encoding or re-parse failure.
func encodedValue<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}

/// Asserts a fixture decodes and re-encodes to the identical wire shape,
/// proving lossless round-trip conformance for the type.
///
/// - Parameters:
///   - type: The model type under test.
///   - fixture: The published-form JSON to round-trip.
///   - sourceLocation: The caller location, for failure reporting.
/// - Throws: Rethrows any decode or encode failure.
func expectExactRoundTrip<T: Codable>(
    _ type: T.Type,
    fixture: String,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let model = try decoded(T.self, fixture: fixture)
    let actual = try encodedValue(model)
    let expected = try jsonValue(fixture: fixture)
    #expect(actual == expected, sourceLocation: sourceLocation)
}

/// Asserts a fixture survives a decode → encode → decode cycle unchanged,
/// proving the model carries no information across the wire that a second
/// decode would not recover.
///
/// Used for types whose encoded form always includes defaulted sub-objects
/// (e.g. the capability trees), where an exact-shape fixture would only
/// restate the encoder's own defaults.
///
/// - Parameters:
///   - type: The model type under test.
///   - fixture: The published-form JSON to round-trip.
///   - sourceLocation: The caller location, for failure reporting.
/// - Throws: Rethrows any decode or encode failure.
func expectStableRoundTrip<T: Codable & Equatable>(
    _ type: T.Type,
    fixture: String,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let first = try decoded(T.self, fixture: fixture)
    let second = try JSONDecoder().decode(T.self, from: JSONEncoder().encode(first))
    #expect(first == second, sourceLocation: sourceLocation)
}

/// Reports whether any JSON null appears anywhere within a structural value.
///
/// Absent optional fields must be omitted on encode, never emitted as null,
/// so encoded models are expected to contain no null at any depth.
///
/// - Parameter value: The structural value to scan.
/// - Returns: `true` when a `.null` is present at any depth.
func containsNull(_ value: JSONValue) -> Bool {
    switch value {
    case .null:
        return true
    case .array(let elements):
        return elements.contains(where: containsNull)
    case .object(let fields):
        return fields.values.contains(where: containsNull)
    case .bool, .number, .string:
        return false
    }
}

/// Returns the field value at a key when the value is an object.
///
/// - Parameters:
///   - key: The object key to look up.
///   - value: The structural value expected to be an object.
/// - Returns: The field value, or `nil` when absent or not an object.
func field(_ key: String, of value: JSONValue) -> JSONValue? {
    guard case .object(let fields) = value else { return nil }
    return fields[key]
}
