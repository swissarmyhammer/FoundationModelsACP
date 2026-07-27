import Foundation
import FoundationModelsACP

/// A minimal ACP agent used only by the transport tests.
///
/// It speaks ACP over stdio, logs to stderr while handling `initialize` — so a
/// test can prove stdout stays pure ndJSON while the agent logs internally —
/// and answers the handshake with the latest protocol version.
struct TestAgent: Agent {
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
        ResumeSessionResponse()
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
    /// - Parameter params: The prompt request.
    /// - Returns: The immediate acknowledgement.
    func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        PromptResponse()
    }

    /// Ignores cancellation; the test agent runs no long turns.
    ///
    /// - Parameter params: The cancellation notification.
    func sessionCancel(_ params: CancelSessionNotification) async {}
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

let connection = await AgentSideConnection(stream: .stdio, logger: .standardError) { _ in
    TestAgent()
}
await runUntilTerminated(connection)
