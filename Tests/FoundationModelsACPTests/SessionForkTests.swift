import Foundation
import Testing

@testable import FoundationModelsACP

/// The unstable `session/fork` method: its wire types, the `fork` session
/// capability, the cut in `_meta.sah.forkCut`, and its route on the two
/// sides.
@Suite struct SessionForkWireTests {
    @Test func aForkRequestWithNoCutRoundTrips() throws {
        let request = try WireRoundTrip.expectLossless(
            ForkSessionRequest.self,
            #"{"sessionId":"sess-1","cwd":"/work","mcpServers":[],"additionalDirectories":["/other"]}"#
        )
        #expect(request.sessionId == SessionId(rawValue: "sess-1"))
        #expect(request.cwd == AbsolutePath(rawValue: "/work"))
        #expect(SAH.ForkCut.extract(from: request.meta) == nil)
    }

    @Test func aForkRequestWithACutRoundTrips() throws {
        let request = try WireRoundTrip.expectLossless(
            ForkSessionRequest.self,
            #"{"sessionId":"sess-1","cwd":"/work","_meta":{"sah":{"forkCut":{"messageId":"msg-2","side":"after"}},"other":1}}"#
        )
        #expect(SAH.ForkCut.extract(from: request.meta) == SAH.ForkCut(messageId: MessageId(rawValue: "msg-2"), side: .after))
    }

    @Test func aForkResponseRoundTrips() throws {
        let response = try WireRoundTrip.expectLossless(
            ForkSessionResponse.self,
            #"{"sessionId":"sess-2","availableCommands":[],"_meta":{"x":true}}"#
        )
        #expect(response.sessionId == SessionId(rawValue: "sess-2"))
    }

    @Test func theCutIsWrittenAndReadBack() throws {
        let cut = SAH.ForkCut(messageId: MessageId(rawValue: "msg-1"), side: .before)
        let meta = try cut.inject(into: .object(["keep": .string("me")]))
        #expect(meta["keep"] == .string("me"))
        #expect(meta["sah"]?["forkCut"]?["side"] == .string("before"))
        let request = ForkSessionRequest(cwd: AbsolutePath(rawValue: "/w"), sessionId: SessionId(rawValue: "s"), meta: meta)
        let decoded = try WireRoundTrip.decode(ForkSessionRequest.self, from: String(decoding: JSONEncoder().encode(request), as: UTF8.self))
        #expect(SAH.ForkCut.extract(from: decoded.meta) == cut)
    }

    @Test func anUnknownSideDecodesWithItsRawText() throws {
        let meta = try WireRoundTrip.parse(#"{"sah":{"forkCut":{"messageId":"m","side":"middle"}}}"#)
        #expect(SAH.ForkCut.extract(from: meta)?.side == SAH.ForkCut.Side(rawValue: "middle"))
    }

    @Test func aCutWithNoMessageIsNotACut() throws {
        let meta = try WireRoundTrip.parse(#"{"sah":{"forkCut":{"side":"after"}}}"#)
        #expect(SAH.ForkCut.extract(from: meta) == nil)
    }

    // MARK: - The capability

    @Test func anOldCapabilityValueHasNoFork() throws {
        let capabilities = try WireRoundTrip.expectLossless(SessionCapabilities.self, #"{}"#)
        #expect(capabilities.fork == nil)
        #expect(!SAH.ForkCut.isAdvertised(by: capabilities.fork))
    }

    @Test func anEmptyForkObjectAdvertisesForkButNotTheCut() throws {
        let capabilities = try WireRoundTrip.expectLossless(SessionCapabilities.self, #"{"fork":{}}"#)
        #expect(capabilities.fork == SessionForkCapabilities())
        #expect(!SAH.ForkCut.isAdvertised(by: capabilities.fork))
    }

    @Test func theCutFlagIsAdvertised() throws {
        let capabilities = try WireRoundTrip.expectLossless(
            SessionCapabilities.self,
            #"{"fork":{"_meta":{"sah":{"forkCut":true}}}}"#
        )
        #expect(SAH.ForkCut.isAdvertised(by: capabilities.fork))
    }

    @Test func theCutFlagIsWritten() throws {
        let fork = SessionForkCapabilities(meta: try SAH.ForkCut.advertise(into: nil))
        #expect(SAH.ForkCut.isAdvertised(by: fork))
        #expect(try WireRoundTrip.encode(fork) == WireRoundTrip.parse(#"{"_meta":{"sah":{"forkCut":true}}}"#))
    }

    @Test func aFlagThatIsNotTrueDoesNotAdvertiseTheCut() throws {
        for json in [#"{"sah":{"forkCut":false}}"#, #"{"sah":{"forkCut":"yes"}}"#, #"{"sah":{}}"#] {
            #expect(!SAH.ForkCut.isAdvertised(in: try WireRoundTrip.parse(json)))
        }
    }
}

/// `session/fork` over a connection.
@Suite struct SessionForkRouteTests {
    @Test func anAgentWithAForkHandlerGetsTheRequest() async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agentConn = await AgentSideConnection(stream: agentEnd) { _ in ForkingAgent() }
        let client = await ClientSideConnection(stream: clientEnd) { _ in ForkTestClient() }
        defer {
            await agentConn.close()
            await client.close()
        }
        let cut = SAH.ForkCut(messageId: MessageId(rawValue: "msg-2"), side: .after)
        let response = try await client.forkSession(
            ForkSessionRequest(
                cwd: AbsolutePath(rawValue: "/work"),
                sessionId: SessionId(rawValue: "source"),
                meta: try cut.inject(into: nil)
            )
        )
        // The agent echoes the source and the cut in the new identifier.
        #expect(response.sessionId == SessionId(rawValue: "source-fork-msg-2-after"))
    }

    @Test func anAgentWithNoForkHandlerAnswersMethodNotFound() async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agentConn = await AgentSideConnection(stream: agentEnd) { _ in NonForkingAgent() }
        let client = await ClientSideConnection(stream: clientEnd) { _ in ForkTestClient() }
        defer {
            await agentConn.close()
            await client.close()
        }
        do {
            _ = try await client.forkSession(
                ForkSessionRequest(cwd: AbsolutePath(rawValue: "/work"), sessionId: SessionId(rawValue: "source"))
            )
            Issue.record("expected method-not-found")
        } catch let error as RequestError {
            #expect(error.code == .methodNotFound)
            #expect(error.data == .object(["method": .string("session/fork")]))
        }
    }
}

// MARK: - Test peers

/// The session baseline of the test agents, with no `forkSession`
/// override.
private protocol ForkTestBaseline: Agent {}

extension ForkTestBaseline {
    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(
            info: Implementation(name: "fork-agent", version: "0.0.0"),
            protocolVersion: .v2,
            capabilities: AgentCapabilities(session: SessionCapabilities())
        )
    }

    func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: SessionId(rawValue: "session-1"))
    }

    func listSessions(_ params: ListSessionsRequest) async throws -> ListSessionsResponse {
        ListSessionsResponse(sessions: [])
    }

    func resumeSession(_ params: ResumeSessionRequest) async throws -> ResumeSessionResponse {
        ResumeSessionResponse()
    }

    func closeSession(_ params: CloseSessionRequest) async throws -> CloseSessionResponse {
        CloseSessionResponse()
    }

    func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        PromptResponse.stubAcknowledgement
    }

    func sessionCancel(_ params: CancelSessionNotification) async {}
}

/// An agent that keeps the default `forkSession`, which answers
/// method-not-found.
private struct NonForkingAgent: ForkTestBaseline {}

/// An agent that forks. The new identifier names the source and the cut.
private struct ForkingAgent: ForkTestBaseline {
    func forkSession(_ params: ForkSessionRequest) async throws -> ForkSessionResponse {
        let cut = SAH.ForkCut.extract(from: params.meta)
        let suffix = cut.map { "-\($0.messageId.rawValue)-\($0.side.rawValue)" } ?? ""
        return ForkSessionResponse(sessionId: SessionId(rawValue: params.sessionId.rawValue + "-fork" + suffix))
    }
}

/// A client that only opens the connection.
private struct ForkTestClient: Client {
    func sessionUpdate(_ notification: UpdateSessionNotification) async {}

    func requestPermission(_ params: RequestPermissionRequest) async throws -> RequestPermissionResponse {
        throw RequestError.methodNotFound("requestPermission")
    }

    func createElicitation(_ params: CreateElicitationRequest) async throws -> CreateElicitationResponse {
        throw RequestError.methodNotFound("createElicitation")
    }

    func elicitationComplete(_ notification: CompleteElicitationNotification) async {}
}
