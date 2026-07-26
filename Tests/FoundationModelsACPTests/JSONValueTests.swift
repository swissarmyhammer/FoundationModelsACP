import Foundation
import Testing

@testable import FoundationModelsACP

/// `JSONValue` is the protocol's lossless carrier — `_meta`, `rawInput`,
/// `rawOutput`, MCP environment values, and the payload of every unrecognized
/// union variant. Everything downstream of it assumes it never quietly
/// reshapes what it holds.
@Suite struct JSONValueTests {
    @Test func everyKindRoundTripsIncludingNestedContainers() throws {
        // All six cases in one document, with containers nested inside
        // containers: the decoder tries the scalar cases in order, so a
        // container reached through an array element or an object member is
        // where a mis-ordered attempt shows up.
        let json = """
            {"null":null,"bool":true,"number":1.5,"string":"s",\
            "array":[null,false,2,"t",[1],{"k":"v"}],\
            "object":{"nested":{"deep":[{"deeper":null}]}}}
            """
        let value = try WireRoundTrip.expectLossless(JSONValue.self, json)
        guard case .object(let members) = value else {
            Issue.record("expected an object, got \(value)")
            return
        }
        #expect(members["null"] == .null)
        #expect(members["bool"] == .bool(true))
        #expect(members["number"] == .number(1.5))
        #expect(members["string"] == .string("s"))
        #expect(members["array"] == .array([.null, .bool(false), .number(2), .string("t"), .array([.number(1)]), .object(["k": .string("v")])]))
        #expect(members["object"] == .object(["nested": .object(["deep": .array([.object(["deeper": .null])])])]))
    }

    @Test func aBareScalarIsAValidDocumentToo() throws {
        // Not every `JSONValue` sits inside an object: an unrecognized config
        // option value is whatever the peer sent, which may be a scalar.
        for json in ["null", "true", "-3", "1.25", "\"text\"", "[]", "{}"] {
            try WireRoundTrip.expectLossless(JSONValue.self, json)
        }
    }

    @Test func booleansDoNotCollapseIntoNumbers() throws {
        // The decoder tries `Bool` before `Double` for a reason: Foundation
        // will happily read `true` as `1`, and a `_meta` flag coming back as a
        // number is the kind of silent reshaping this type exists to prevent.
        #expect(try WireRoundTrip.decode(JSONValue.self, from: "true") == .bool(true))
        #expect(try WireRoundTrip.decode(JSONValue.self, from: "1") == .number(1))
    }

    @Test func flattenedMembersRoundTripThroughAKeyedContainer() throws {
        // `encodeMembers(to:)` is the inverse of `init(from:excludingMembers:)`
        // and the two are exercised together only through generated unions.
        // This is the direct test of the pair.
        struct Wrapper: Codable {
            var tag: String
            var rest: JSONValue

            private enum CodingKeys: String, CodingKey { case tag }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                tag = try container.decode(String.self, forKey: .tag)
                rest = try JSONValue(from: decoder, excludingMembers: ["tag"])
            }

            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(tag, forKey: .tag)
                try rest.encodeMembers(to: encoder, reserving: ["tag"])
            }
        }
        let wrapper = try WireRoundTrip.expectLossless(Wrapper.self, """
            {"tag":"t","a":1,"b":{"c":[true,null]}}
            """)
        #expect(wrapper.rest == .object(["a": .number(1), "b": .object(["c": .array([.bool(true), .null])])]))
    }

    @Test func excludingMembersRejectsANonObject() throws {
        struct Wrapper: Decodable {
            var rest: JSONValue

            init(from decoder: any Decoder) throws {
                rest = try JSONValue(from: decoder, excludingMembers: [])
            }
        }
        #expect(throws: DecodingError.self) {
            try WireRoundTrip.decode(Wrapper.self, from: "[1,2]")
        }
    }
}
