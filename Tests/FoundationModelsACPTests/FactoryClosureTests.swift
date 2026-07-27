import Foundation
import Synchronization
import Testing

import FoundationModelsACP

// MARK: - Helpers

/// Re-encodes a typed value to its wire form, for comparing recorded calls.
///
/// - Parameter value: The model to encode.
/// - Returns: The value's structural wire representation.
/// - Throws: Rethrows any encoding failure.
private func encodedValue<Value: Encodable>(_ value: Value) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}

/// Records each role handler's re-encoded parameters and signals delivery.
///
/// Requests are confirmed by their response, but notifications are
/// fire-and-forget, so tests await `waitForCall(_:)` to observe delivery
/// deterministically instead of sleeping.
private final class RoleRecorder: Sendable {
    /// The re-encoded parameters seen for each handler, keyed by handler name.
    private let calls = Mutex<[String: JSONValue]>([:])

    /// A stream of handler names, one per invocation, for delivery waits.
    private let events: AsyncStream<String>

    /// Feeds `events` as handlers are invoked.
    private let emit: AsyncStream<String>.Continuation

    /// Creates an empty recorder.
    init() {
        (events, emit) = AsyncStream<String>.makeStream()
    }

    /// Records one handler invocation, re-encoding its parameters to a value.
    ///
    /// - Parameters:
    ///   - handler: The handler name that was invoked.
    ///   - value: The parameters the handler received.
    func record<Value: Encodable>(_ handler: String, _ value: Value) {
        let encoded = (try? encodedValue(value)) ?? .null
        calls.withLock { $0[handler] = encoded }
        emit.yield(handler)
    }

    /// The re-encoded parameters recorded for a handler, if it was invoked.
    ///
    /// - Parameter handler: The handler name to look up.
    /// - Returns: The recorded parameters, or `nil` when not yet invoked.
    func recorded(_ handler: String) -> JSONValue? {
        calls.withLock { $0[handler] }
    }

    /// Waits until the named handler has been invoked at least once.
    ///
    /// - Parameter handler: The handler name to wait for.
    func waitForCall(_ handler: String) async {
        for await event in events where event == handler {
            return
        }
    }
}

/// A fixed session id shared by the tests in this file.
private let testSessionId = SessionId(rawValue: "session-1")

// MARK: - Roles that exercise the reverse direction (Agent → Client)

/// An agent whose `prompt` uses its captured connection to issue a reverse
/// `requestPermission` and fire a `sessionUpdate` before acknowledging.
///
/// This proves the factory closure hands the agent its own connection:
/// without it, the agent would have no handle to call back into the client
/// mid-turn — exactly how `session/request_permission` and `session/update`
/// are meant to be driven.
private final class ReversePromptAgent: Agent {
    /// The connection handed to the agent by the factory closure.
    let connection: AgentSideConnection

    /// The shared recorder capturing the reverse call's response.
    let recorder: RoleRecorder

    /// Creates an agent bound to its own connection.
    ///
    /// - Parameters:
    ///   - connection: The connection the factory handed this agent.
    ///   - recorder: The recorder to report the reverse response to.
    init(connection: AgentSideConnection, recorder: RoleRecorder) {
        self.connection = connection
        self.recorder = recorder
    }

    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(
            info: Implementation(name: "reverse-prompt-agent", version: "0.0.0"),
            protocolVersion: .v2,
            capabilities: AgentCapabilities(session: SessionCapabilities())
        )
    }

    func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: testSessionId)
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
        let permission = RequestPermissionRequest(
            options: [PermissionOption(kind: .allowOnce, name: "Allow", optionId: PermissionOptionId(rawValue: "allow"))],
            sessionId: testSessionId,
            title: "Allow this tool call?"
        )
        let outcome = try await connection.requestPermission(permission)
        recorder.record("promptReversePermission", outcome)

        let update = UpdateSessionNotification(
            sessionId: testSessionId,
            update: .agentMessageChunk(
                ContentChunk(content: .text(TextContent(text: "working")), messageId: MessageId(rawValue: "m1"))
            )
        )
        try await connection.sessionUpdate(update)
        return PromptResponse()
    }

    func sessionCancel(_ params: CancelSessionNotification) async {}
}

/// A client that grants permission with a distinctive selected outcome, so the
/// agent can prove it received the client's real response.
private final class PermittingClient: Client {
    /// The shared recorder capturing each reverse call.
    let recorder: RoleRecorder

    /// The option id this client always selects.
    static let grantedOption = PermissionOptionId(rawValue: "allow")

    /// Creates a client backed by the given recorder.
    ///
    /// - Parameter recorder: The recorder to report calls to.
    init(recorder: RoleRecorder) {
        self.recorder = recorder
    }

    func sessionUpdate(_ notification: UpdateSessionNotification) async {
        recorder.record("sessionUpdate", notification)
    }

    func requestPermission(
        _ params: RequestPermissionRequest
    ) async throws -> RequestPermissionResponse {
        recorder.record("requestPermission", params)
        return RequestPermissionResponse(
            outcome: .selected(SelectedPermissionOutcome(optionId: Self.grantedOption))
        )
    }
}

// MARK: - Roles that exercise the reverse direction (Client → Agent)

/// A client whose `sessionUpdate` uses its captured connection to cancel the
/// session it just heard from — a stand-in for a SwiftUI host reacting to a
/// `state_update` by driving the agent back, from inside the very handler the
/// agent's notification dispatched to.
private final class ReactiveClient: Client {
    /// The connection handed to the client by the factory closure.
    let connection: ClientSideConnection

    /// The shared recorder capturing the reverse call.
    let recorder: RoleRecorder

    /// Creates a client bound to its own connection.
    ///
    /// - Parameters:
    ///   - connection: The connection the factory handed this client.
    ///   - recorder: The recorder to report the reverse call to.
    init(connection: ClientSideConnection, recorder: RoleRecorder) {
        self.connection = connection
        self.recorder = recorder
    }

    func sessionUpdate(_ notification: UpdateSessionNotification) async {
        try? await connection.sessionCancel(CancelSessionNotification(sessionId: notification.sessionId))
        recorder.record("reactiveSessionCancel", notification)
    }

    func requestPermission(
        _ params: RequestPermissionRequest
    ) async throws -> RequestPermissionResponse {
        throw RequestError.methodNotFound("requestPermission")
    }
}

/// An agent that records the notifications it serves, for the reactive-client
/// test to confirm the reverse `session/cancel` actually arrived.
private final class RecordingAgent: Agent {
    /// The shared recorder capturing each served call.
    let recorder: RoleRecorder

    /// Creates an agent backed by the given recorder.
    ///
    /// - Parameter recorder: The recorder to report calls to.
    init(recorder: RoleRecorder) {
        self.recorder = recorder
    }

    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(
            info: Implementation(name: "recording-agent", version: "0.0.0"),
            protocolVersion: .v2,
            capabilities: AgentCapabilities(session: SessionCapabilities())
        )
    }

    func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: testSessionId)
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

    func sessionCancel(_ params: CancelSessionNotification) async {
        recorder.record("sessionCancel", params)
    }
}

// MARK: - Tests

@Test(.timeLimit(.minutes(1)))
func agentFactoryCapturesConnectionAndIssuesReversePermissionDuringPrompt() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let recorder = RoleRecorder()
    let agentConn = await AgentSideConnection(stream: agentEnd) { conn in
        ReversePromptAgent(connection: conn, recorder: recorder)
    }
    let client = await ClientSideConnection(stream: clientEnd) { _ in PermittingClient(recorder: recorder) }

    let prompt = PromptRequest(prompt: [.text(TextContent(text: "go"))], sessionId: testSessionId)
    _ = try await client.prompt(prompt)

    // The reverse permission request reached the client during the prompt, and
    // the client's actual selected outcome was delivered back to the agent.
    #expect(recorder.recorded("requestPermission") != nil)
    let expected = RequestPermissionResponse(
        outcome: .selected(SelectedPermissionOutcome(optionId: PermittingClient.grantedOption))
    )
    #expect(recorder.recorded("promptReversePermission") == (try encodedValue(expected)))

    // The session update fired during the turn was delivered.
    await recorder.waitForCall("sessionUpdate")

    await agentConn.close()
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func clientFactoryCapturesConnectionAndDrivesAgentFromWithinSessionUpdate() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let recorder = RoleRecorder()
    let agentConn = await AgentSideConnection(stream: agentEnd) { _ in RecordingAgent(recorder: recorder) }
    let client = await ClientSideConnection(stream: clientEnd) { conn in
        ReactiveClient(connection: conn, recorder: recorder)
    }

    try await agentConn.sessionUpdate(
        UpdateSessionNotification(
            sessionId: testSessionId,
            update: .agentMessageChunk(
                ContentChunk(content: .text(TextContent(text: "hi")), messageId: MessageId(rawValue: "m1"))
            )
        )
    )

    // The client's own handler used its captured connection to drive the
    // agent back — the reverse call actually reached the agent's side.
    await recorder.waitForCall("sessionCancel")
    #expect(
        recorder.recorded("sessionCancel")
            == (try encodedValue(CancelSessionNotification(sessionId: testSessionId)))
    )

    await agentConn.close()
    await client.close()
}
