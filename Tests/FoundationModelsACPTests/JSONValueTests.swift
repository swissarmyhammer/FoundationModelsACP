import Foundation
import Testing

import FoundationModelsACP

/// Decodes a JSON string into a `JSONValue`.
private func decodeValue(_ json: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
}

/// Encodes a `JSONValue` back to JSON data and decodes it again,
/// returning the second-generation value for round-trip comparison.
private func roundTrip(_ value: JSONValue) throws -> JSONValue {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(JSONValue.self, from: data)
}

@Test func jsonValueRoundTripsNestedFixture() throws {
    let fixture = """
        {
          "name": "acp",
          "version": 1,
          "fraction": 2.5,
          "enabled": true,
          "missing": null,
          "tags": ["a", "b", "c"],
          "nested": {
            "inner": {
              "list": [1, false, null, "x", {"deep": []}]
            }
          }
        }
        """
    let decoded = try decodeValue(fixture)
    let rereaded = try roundTrip(decoded)
    #expect(rereaded == decoded)
}

@Test func jsonValueDecodesScalarsIntoExpectedCases() throws {
    #expect(try decodeValue("null") == .null)
    #expect(try decodeValue("true") == .bool(true))
    #expect(try decodeValue("false") == .bool(false))
    #expect(try decodeValue("42") == .number(42))
    #expect(try decodeValue("-3.25") == .number(-3.25))
    #expect(try decodeValue("\"hi\"") == .string("hi"))
}

@Test func jsonValueDoesNotConflateBoolAndNumber() throws {
    // `true` must decode as .bool, never as .number(1).
    let value = try decodeValue("[true, 1]")
    #expect(value == .array([.bool(true), .number(1)]))
}

@Test func jsonValuePreservesMetaRoundTrip() throws {
    // _meta is free-form and must survive encode/decode untouched.
    let fixture = """
        {
          "_meta": {
            "vendor.tool/trace": {"id": "abc-123", "hops": [1, 2, 3]},
            "flag": true,
            "nothing": null
          }
        }
        """
    let decoded = try decodeValue(fixture)
    guard case .object(let object) = decoded, case .object(let meta)? = object["_meta"] else {
        Issue.record("expected top-level object with an object _meta")
        return
    }
    #expect(meta["flag"] == .bool(true))
    #expect(meta["nothing"] == .null)
    #expect(try roundTrip(decoded) == decoded)
}

@Test func jsonValueRoundTripsEmptyContainers() throws {
    let decoded = try decodeValue("{\"emptyObject\": {}, \"emptyArray\": []}")
    #expect(
        decoded
            == .object([
                "emptyObject": .object([:]),
                "emptyArray": .array([]),
            ]))
    #expect(try roundTrip(decoded) == decoded)
}

@Test func jsonValueIsHashable() throws {
    let a = try decodeValue("{\"k\": [1, null, true]}")
    let b = try decodeValue("{\"k\": [1, null, true]}")
    #expect(a.hashValue == b.hashValue)
    #expect(Set([a, b]).count == 1)
}
