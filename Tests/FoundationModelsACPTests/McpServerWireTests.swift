import Foundation
import Testing

import FoundationModelsACP

/// Wire-conformance tests for the two `anyOf` seams resolved into typed models:
/// the `McpServer` discriminated union and the `SetSessionConfigOptionRequest`
/// value-union struct.
@Suite struct McpServerWireTests {
    @Test func httpVariantRoundTripsAndDecodesTyped() throws {
        let fixture = #"{"type":"http","headers":[],"name":"srv","url":"https://example.com"}"#
        try expectExactRoundTrip(McpServer.self, fixture: fixture)
        guard case .http(let payload) = try decoded(McpServer.self, fixture: fixture) else {
            Issue.record("expected .http")
            return
        }
        #expect(payload.url == "https://example.com")
    }

    @Test func sseVariantRoundTripsAndDecodesTyped() throws {
        let fixture = #"{"type":"sse","headers":[],"name":"srv","url":"https://example.com"}"#
        try expectExactRoundTrip(McpServer.self, fixture: fixture)
        guard case .sse = try decoded(McpServer.self, fixture: fixture) else {
            Issue.record("expected .sse")
            return
        }
    }

    @Test func stdioVariantWithoutTypeDecodesAsDefaultAndRoundTrips() throws {
        // The stdio transport is the discriminator-less default: it carries no
        // `type` on the wire, and re-encoding must not add one.
        let fixture = #"{"args":[],"command":"/usr/bin/srv","env":[],"name":"srv"}"#
        try expectExactRoundTrip(McpServer.self, fixture: fixture)
        guard case .stdio(let payload) = try decoded(McpServer.self, fixture: fixture) else {
            Issue.record("expected .stdio")
            return
        }
        #expect(payload.command == AbsolutePath(rawValue: "/usr/bin/srv"))
        #expect(try field("type", of: encodedValue(McpServer.stdio(payload))) == nil)
    }

    @Test func unknownDiscriminatorDecodesToUnknownAndPreservesIt() throws {
        // An unrecognized transport tag decodes without error and re-encodes
        // just the discriminator; the unrecognized payload is not preserved.
        let server = try decoded(McpServer.self, fixture: #"{"type":"websocket","name":"srv"}"#)
        #expect(server == .unknown("websocket"))
        #expect(try encodedValue(server) == jsonValue(fixture: #"{"type":"websocket"}"#))
    }

    @Test func setSessionConfigOptionBooleanFormRoundTrips() throws {
        let fixture = #"{"configId":"theme","sessionId":"s","type":"boolean","value":true}"#
        try expectExactRoundTrip(SetSessionConfigOptionRequest.self, fixture: fixture)
        let request = try decoded(SetSessionConfigOptionRequest.self, fixture: fixture)
        #expect(request.value == .boolean(true))
    }

    @Test func setSessionConfigOptionValueIdFormRoundTrips() throws {
        // The `value_id` variant is the default: no `type` on the wire.
        let fixture = #"{"configId":"theme","sessionId":"s","value":"dark"}"#
        try expectExactRoundTrip(SetSessionConfigOptionRequest.self, fixture: fixture)
        let request = try decoded(SetSessionConfigOptionRequest.self, fixture: fixture)
        #expect(request.value == .valueId(SessionConfigValueId(rawValue: "dark")))
    }

    @Test func setSessionConfigOptionUnknownTypeWithStringFallsBackToValueId() throws {
        // An unknown `type` with a string payload gracefully deserializes into
        // the `value_id` default, which re-encodes without the discriminator.
        let request = try decoded(
            SetSessionConfigOptionRequest.self,
            fixture: #"{"configId":"theme","sessionId":"s","type":"mystery","value":"dark"}"#
        )
        #expect(request.value == .valueId(SessionConfigValueId(rawValue: "dark")))
        let encoded = try encodedValue(request)
        #expect(field("type", of: encoded) == nil)
        #expect(field("value", of: encoded) == .string("dark"))
    }
}
