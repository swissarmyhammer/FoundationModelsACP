import Foundation
import FoundationModelsACP

/// A minimal ACP agent used only by the transport tests.
///
/// It speaks ACP over stdio, logs to stderr while handling `initialize` — so a
/// test can prove stdout stays pure ndJSON while the agent logs internally —
/// and answers the handshake with the latest protocol version.
struct TestAgent: Agent {
    /// Whether the agent plays the conformant turn, cancel and resume
    /// behavior (`ConformantScenario`). The launch argument `--scenario
    /// conformant` turns it on.
    let isConformant: Bool

    /// The turn that waits for `session/cancel`.
    let heldTurn = ConformantScenario.HeldTurn()

    /// Whether the agent plays `NestedSubagentScenario` when the client
    /// resumes a session. The launch argument `--scenario nested-subagents`
    /// turns it on.
    let playsNestedSubagentScenario: Bool

    /// The connection that the factory gave this agent. The agent uses it to
    /// echo each prompt back to the client as a `user_message` update.
    let connection: AgentSideConnection

    /// Logs to stderr and answers with the latest protocol version.
    ///
    /// - Parameter params: The client's initialization request.
    /// - Returns: The agent's initialization response.
    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        FileHandle.standardError.write(Data("acp-test-agent: initialize received\n".utf8))
        return InitializeResponse(
            info: Implementation(name: "acp-test-agent", version: "0.0.0"),
            protocolVersion: .latest,
            capabilities: AgentCapabilities(session: SessionCapabilities())
        )
    }

    /// Returns a fixed session id.
    ///
    /// - Parameter params: The new-session request.
    /// - Returns: A response naming a single fixed session.
    func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: SessionId(rawValue: "test-session"))
    }

    /// Reports no sessions; this fixture keeps no state across calls.
    ///
    /// - Parameter params: The list-sessions request.
    /// - Returns: An empty listing.
    func listSessions(_ params: ListSessionsRequest) async throws -> ListSessionsResponse {
        ListSessionsResponse(sessions: [])
    }

    /// Resumes the fixed session with no history to replay.
    ///
    /// - Parameter params: The resume-session request.
    /// - Returns: An empty resume response.
    func resumeSession(_ params: ResumeSessionRequest) async throws -> ResumeSessionResponse {
        if playsNestedSubagentScenario { return try await NestedSubagentScenario.resume(on: connection) }
        if isConformant { return try await ConformantScenario.resume(params, on: connection) }
        return ResumeSessionResponse()
    }

    /// Closes the fixed session.
    ///
    /// - Parameter params: The close-session request.
    /// - Returns: An empty close response.
    func closeSession(_ params: CloseSessionRequest) async throws -> CloseSessionResponse {
        CloseSessionResponse()
    }

    /// Acknowledges the turn immediately, as v2's prompt lifecycle requires.
    ///
    /// `AgentSideConnection.insertUserMessage` gives the user message a new
    /// `MessageId`. After the response is on the wire, it echoes the prompt
    /// as a `user_message` update with that same id, because the response
    /// and the echo must name the same message.
    ///
    /// - Parameter params: The prompt request.
    /// - Returns: The immediate acknowledgement, which names the user message.
    func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        let messageId = connection.insertUserMessage(params)
        if isConformant { try await ConformantScenario.prompt(params, on: connection, held: heldTurn) }
        return PromptResponse(messageId: messageId)
    }

    /// Ends a held turn. Without `--scenario conformant`, the agent runs no
    /// long turns and ignores cancellation.
    ///
    /// - Parameter params: The cancellation notification.
    func sessionCancel(_ params: CancelSessionNotification) async {
        guard isConformant else { return }
        await heldTurn.cancel(params.sessionId, on: connection)
    }
}

/// Runs until the parent closes stdin and terminates this process, keeping the
/// connection's read loop alive to serve the handshake.
///
/// - Parameter connection: The live connection to hold open.
func runUntilTerminated(_ connection: AgentSideConnection) async {
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(3600))
    }
}

/// The scenario names of the `--scenario NAME` launch arguments. The flag can repeat.
let scenarioNames: Set<String> = {
    let arguments = Array(CommandLine.arguments.dropFirst())
    return Set(arguments.indices.dropLast().filter { arguments[$0] == "--scenario" }.map { arguments[$0 + 1] })
}()
let connection = await AgentSideConnection(stream: .stdio, logger: .standardError) { conn in
    TestAgent(
        isConformant: scenarioNames.contains(ConformantScenario.name),
        playsNestedSubagentScenario: scenarioNames.contains(NestedSubagentScenario.name), connection: conn)
}
await runUntilTerminated(connection)
