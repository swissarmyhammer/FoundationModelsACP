import Foundation
import Testing

@testable import FoundationModelsACP

/// A `Client` that records every elicitation call it serves and answers
/// `elicitation/create` with a caller-chosen response, so a test can assert
/// both what arrived and what went back.
private actor RecordingElicitationClient: Client {
    /// The `elicitation/create` requests this client received, in order.
    private(set) var createdElicitations: [CreateElicitationRequest] = []

    /// The `elicitation/complete` notifications this client received, in order.
    private(set) var completedElicitations: [CompleteElicitationNotification] = []

    /// The fixed response every `createElicitation` call answers with.
    private let response: CreateElicitationResponse

    /// Creates the client with the response it answers every elicitation with.
    ///
    /// - Parameter response: The raw response value to return.
    init(response: CreateElicitationResponse) {
        self.response = response
    }

    func sessionUpdate(_ notification: UpdateSessionNotification) async {}

    func requestPermission(
        _ params: RequestPermissionRequest
    ) async throws -> RequestPermissionResponse {
        RequestPermissionResponse(outcome: .cancelled)
    }

    func createElicitation(
        _ params: CreateElicitationRequest
    ) async throws -> CreateElicitationResponse {
        createdElicitations.append(params)
        return response
    }

    func elicitationComplete(_ notification: CompleteElicitationNotification) async {
        completedElicitations.append(notification)
    }
}

/// The stable elicitation lifecycle, end to end over a live transport pair:
/// `elicitation/create` round-trips from the agent to the client's typed
/// handler and back, `elicitation/complete` is delivered as a notification,
/// and the wire JSON flattens each mode's scope keys at the top level.
@Suite struct ElicitationLifecycleTests {
    // MARK: - Fixtures

    private static let sessionId = SessionId(rawValue: "session-1")

    /// A form-mode request scoped to a session, the shape an agent uses to
    /// gather structured input mid-turn.
    private static let formRequest = CreateElicitationRequest(
        message: "Name the deployment",
        mode: .form(
            ElicitationFormMode(
                requestedSchema: ElicitationSchema(
                    properties: .object(["name": .object(["type": .string("string")])]),
                    required: ["name"]
                ),
                scope: .session(ElicitationSessionScope(sessionId: sessionId))
            )
        )
    )

    /// A url-mode request scoped to a JSON-RPC request, the shape an agent
    /// uses before any session exists (for example during auth).
    private static let urlRequest = CreateElicitationRequest(
        message: "Finish sign-in in the browser",
        mode: .url(
            ElicitationUrlMode(
                elicitationId: ElicitationId(rawValue: "elicit-1"),
                url: "https://example.test/verify",
                scope: .request(ElicitationRequestScope(requestId: .string("req-1")))
            )
        )
    )

    /// Opens a connection pair serving the given client and runs `body`
    /// against both ends, closing the pair afterwards.
    ///
    /// - Parameters:
    ///   - client: The client to serve on the client side.
    ///   - body: The test body, given the agent's outbound surface.
    private static func withConnectedPair(
        serving client: RecordingElicitationClient,
        _ body: (AgentSideConnection) async throws -> Void
    ) async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agentConn = await AgentSideConnection(stream: agentEnd) { _ in PassiveElicitationAgent() }
        let clientConn = await ClientSideConnection(stream: clientEnd) { _ in client }

        try await body(agentConn)

        await agentConn.close()
        await clientConn.close()
    }

    // MARK: - elicitation/create round trips

    @Test func formModeWithSessionScopeReachesTheClientAndTheResponseRoundTripsBack() async throws {
        let acceptance: CreateElicitationResponse = .object([
            "action": .string("accept"),
            "content": .object(["name": .string("orion")]),
        ])
        let client = RecordingElicitationClient(response: acceptance)

        try await Self.withConnectedPair(serving: client) { agentConn in
            let response = try await agentConn.createElicitation(Self.formRequest)
            #expect(response == acceptance)
        }

        #expect(await client.createdElicitations == [Self.formRequest])
    }

    @Test func urlModeWithRequestScopeReachesTheClientAndTheResponseRoundTripsBack() async throws {
        let cancellation: CreateElicitationResponse = .object(["action": .string("cancel")])
        let client = RecordingElicitationClient(response: cancellation)

        try await Self.withConnectedPair(serving: client) { agentConn in
            let response = try await agentConn.createElicitation(Self.urlRequest)
            #expect(response == cancellation)
        }

        #expect(await client.createdElicitations == [Self.urlRequest])
    }

    // MARK: - elicitation/complete delivery

    @Test func completeNotificationIsDeliveredToTheClientWithNoResponseOnTheWire() async throws {
        let client = RecordingElicitationClient(response: .object(["action": .string("cancel")]))
        let completion = CompleteElicitationNotification(elicitationId: ElicitationId(rawValue: "elicit-1"))

        try await Self.withConnectedPair(serving: client) { agentConn in
            try await agentConn.elicitationComplete(completion)
            // A notification returns before dispatch; the read loop awaits
            // notifications inline in arrival order, so a later request's
            // response proves the notification in front of it was dispatched.
            _ = try await agentConn.createElicitation(Self.urlRequest)
        }

        #expect(await client.completedElicitations == [completion])
    }

    // MARK: - ClientCapabilities gates elicitation

    @Test func clientCapabilitiesDecodesOmittedAndNullElicitationAsNoSupport() throws {
        let omitted = try WireRoundTrip.decode(ClientCapabilities.self, from: "{}")
        #expect(omitted.elicitation == nil)

        let explicitNull = try WireRoundTrip.decode(ClientCapabilities.self, from: #"{"elicitation":null}"#)
        #expect(explicitNull.elicitation == nil)

        let supported = try WireRoundTrip.decode(ClientCapabilities.self, from: #"{"elicitation":{"form":{}}}"#)
        #expect(supported.elicitation?.form != nil)
    }

    // MARK: - The wire flattens scope keys at the top level

    @Test func formModeWireJSONFlattensSessionScopeKeysAtTheTopLevel() throws {
        let wire = try WireRoundTrip.encode(Self.formRequest)

        #expect(wire["mode"] == .string("form"))
        #expect(wire["sessionId"] == .string(Self.sessionId.rawValue))
        #expect(wire["requestedSchema"] != nil)
        #expect(wire["scope"] == nil, "the wire object must carry no nested scope key")
    }

    @Test func urlModeWireJSONFlattensRequestScopeKeysAtTheTopLevel() throws {
        let wire = try WireRoundTrip.encode(Self.urlRequest)

        #expect(wire["mode"] == .string("url"))
        #expect(wire["requestId"] == .string("req-1"))
        #expect(wire["elicitationId"] == .string("elicit-1"))
        #expect(wire["url"] == .string("https://example.test/verify"))
        #expect(wire["scope"] == nil, "the wire object must carry no nested scope key")
    }
}

/// An `Agent` this suite never calls: the connection factory requires one,
/// and every test here drives the reverse Agent → Client direction only.
private struct PassiveElicitationAgent: Agent {
    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(
            info: Implementation(name: "passive-agent", version: "0.0.0"),
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
        PromptResponse()
    }

    func sessionCancel(_ params: CancelSessionNotification) async {}
}
