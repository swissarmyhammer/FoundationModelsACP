import Foundation
import Testing

@testable import FoundationModelsACP

/// Wire-level coverage for `MCPServer` — v2's two-variant union.
///
/// The v1 predecessor of this file covered a three-variant union (`stdio` /
/// `http` / `sse`) where `stdio` was the discriminator-less default. v2
/// reshapes the union rather than merely renaming it: `type` is a required
/// discriminator on every variant, `sse` is gone outright, and the unknown
/// fallback now carries a payload rather than just the bare tag — so this is
/// a fresh suite against the new shape, not a port of the old one.
@Suite struct McpServerWireTests {
    @Test func stdioVariantRequiresATypeDiscriminatorAndRoundTrips() throws {
        let fixture = """
            {"type":"stdio","name":"local","command":"/usr/bin/server","args":["--flag"],\
            "env":[{"name":"KEY","value":"1"}]}
            """
        let server = try WireRoundTrip.expectLossless(MCPServer.self, fixture)
        guard case .stdio(let payload) = server else {
            Issue.record("expected .stdio, got \(server)")
            return
        }
        #expect(payload.command == AbsolutePath(rawValue: "/usr/bin/server"))
        #expect(payload.args == ["--flag"])
        #expect(payload.env?.first?.name == "KEY")
        #expect(payload.env?.first?.value == "1")
    }

    @Test func httpVariantRequiresATypeDiscriminatorAndRoundTrips() throws {
        let fixture = """
            {"type":"http","name":"remote","url":"https://example.com/mcp",\
            "headers":[{"name":"Authorization","value":"Bearer x"}]}
            """
        let server = try WireRoundTrip.expectLossless(MCPServer.self, fixture)
        guard case .http(let payload) = server else {
            Issue.record("expected .http, got \(server)")
            return
        }
        #expect(payload.url == "https://example.com/mcp")
        #expect(payload.headers?.first?.name == "Authorization")
        #expect(payload.headers?.first?.value == "Bearer x")
    }

    @Test func stdioWithoutATypeFailsDecodingUnlikeV1sDiscriminatorLessDefault() throws {
        // v1's stdio transport was the discriminator-less default, so an
        // object naming no `type` decoded as stdio. v2 requires `type` on
        // every variant, so the same shaped payload must now fail rather
        // than silently resolve to a variant.
        #expect(throws: DecodingError.self) {
            try WireRoundTrip.decode(MCPServer.self, from: #"{"name":"local","command":"/usr/bin/server"}"#)
        }
    }

    @Test func sseIsRemovedInV2AndDecodesToUnknownRatherThanAKnownVariant() throws {
        // v1 had a third `sse` variant; v2 removes it outright. A peer that
        // still sends it must not be rejected — the wire convention is to
        // accept and preserve unknown values — but it must not resolve to
        // any modeled case either.
        let fixture = #"{"type":"sse","name":"legacy","url":"https://example.com/sse"}"#
        let server = try WireRoundTrip.expectLossless(MCPServer.self, fixture)
        guard case .unknown(let tag, let payload) = server else {
            Issue.record("expected .unknown, got \(server)")
            return
        }
        #expect(tag == "sse")
        #expect(payload == .object(["name": .string("legacy"), "url": .string("https://example.com/sse")]))
    }

    @Test func unknownVariantPreservesItsPayloadInsideAnMcpServersArray() throws {
        // The point of preserving `.unknown` rather than dropping it: a peer
        // relaying `session/new` onward must not silently lose a server
        // entry it does not itself understand.
        let request = try WireRoundTrip.expectLossless(
            NewSessionRequest.self,
            """
            {"cwd":"/work","mcpServers":[\
            {"type":"sse","name":"legacy","url":"https://example.com/sse"},\
            {"type":"stdio","name":"local","command":"/usr/bin/server"}]}
            """
        )
        #expect(request.mcpServers?.count == 2)
        guard case .unknown("sse", _) = request.mcpServers?[0] else {
            Issue.record("expected the first server to stay .unknown")
            return
        }
        guard case .stdio = request.mcpServers?[1] else {
            Issue.record("expected the second server to decode as .stdio")
            return
        }
    }

    @Test func stdioCommandMustBeAbsolute() throws {
        #expect(throws: DecodingError.self) {
            try WireRoundTrip.decode(MCPServer.self, from: #"{"type":"stdio","name":"local","command":"bin/server"}"#)
        }
    }

    @Test func resumeSessionRequestAcceptsMcpServersJustAsNewSessionDoes() throws {
        // `mcpServers` is optional on both `session/new` and `session/resume`
        // — the same union, the same requirement, on both request shapes.
        let request = try WireRoundTrip.expectLossless(
            ResumeSessionRequest.self,
            """
            {"cwd":"/work","sessionId":"s","mcpServers":[\
            {"type":"http","name":"remote","url":"https://example.com/mcp"}]}
            """
        )
        guard case .http(let payload) = request.mcpServers?.first else {
            Issue.record("expected .http, got \(String(describing: request.mcpServers))")
            return
        }
        #expect(payload.name == "remote")
    }
}
