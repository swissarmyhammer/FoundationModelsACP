import Foundation
import Testing

import FoundationModelsACP

// MARK: - Roles that exercise the reverse direction

/// An agent whose `prompt` uses its captured connection to issue a reverse
/// `requestPermission` and fire a `sessionUpdate` before the turn stops.
///
/// This proves the factory closure hands the agent its own connection: without
/// it, the agent would have no handle to call back into the client mid-turn.
final class ReversePromptAgent: Agent {
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
        InitializeResponse(protocolVersion: .v1)
    }

    func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: testSessionId)
    }

    func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        let permission = RequestPermissionRequest(
            options: [],
            sessionId: testSessionId,
            toolCall: ToolCallUpdate(toolCallId: ToolCallId(rawValue: "call-1"))
        )
        let outcome = try await connection.requestPermission(permission)
        recorder.record("promptReversePermission", outcome)

        let update = SessionNotification(
            sessionId: testSessionId,
            update: .agentMessageChunk(ContentChunk(content: .text(TextContent(text: "working"))))
        )
        try await connection.sessionUpdate(update)
        return PromptResponse(stopReason: .refusal)
    }

    func cancel(_ params: CancelNotification) async {}
}

/// A client that grants permission with a distinctive selected outcome, so the
/// agent can prove it received the client's real response.
final class PermittingClient: Client {
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

    func sessionUpdate(_ notification: SessionNotification) async {
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
    let response = try await client.prompt(prompt)

    // The turn stopped with the agent's own stop reason.
    #expect(response.stopReason == .refusal)

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
