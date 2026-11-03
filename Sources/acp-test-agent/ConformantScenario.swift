import Foundation
import FoundationModelsACP

/// The behavior of a correct agent for the checks of `acp-conformance`
/// (`--scenario conformant`).
///
/// - A prompt turn sends `running`, a message, and a final `idle`. The prompt
///   response is not delayed by the turn. A prompt that asks the agent to
///   keep working "until cancelled" holds the turn. `session/cancel` ends it
///   with `idle` and the stop reason `cancelled`.
/// - A resume follows the order of ACP v2: the history when the request has
///   `replayFrom`, then one current `state_update`, then a
///   `session_info_update`, then the response.
enum ConformantScenario {
    /// The name that selects this scenario: `--scenario conformant`.
    static let name = "conformant"

    /// The text that holds a turn: the prompt contains "until cancelled".
    static let holdMarker = "until cancelled"

    /// The turns that wait for `session/cancel`, by session.
    actor HeldTurn {
        private var sessions: Set<SessionId> = []

        func hold(_ session: SessionId) { sessions.insert(session) }

        /// Ends the held turn of the session, if there is one.
        func cancel(_ session: SessionId, on connection: AgentSideConnection) async {
            guard sessions.remove(session) != nil else { return }
            try? await connection.sessionUpdate(
                UpdateSessionNotification(
                    sessionId: session, update: .stateUpdate(.idle(IdleStateUpdate(stopReason: .cancelled)))))
        }
    }

    private static func isHeld(_ params: PromptRequest) -> Bool {
        params.prompt.contains { block in
            if case .text(let text) = block { return text.text.contains(holdMarker) } else { return false }
        }
    }

    /// Sends `running` now, and the rest of the turn after the response.
    static func prompt(_ params: PromptRequest, on connection: AgentSideConnection, held: HeldTurn) async throws {
        let session = params.sessionId
        try await connection.sessionUpdate(
            UpdateSessionNotification(sessionId: session, update: .stateUpdate(.running(RunningStateUpdate()))))
        if isHeld(params) {
            await held.hold(session)
            return
        }
        connection.afterRespondingToCurrentRequest {
            try? await connection.sessionUpdate(
                UpdateSessionNotification(
                    sessionId: session,
                    update: .agentMessage(AgentMessage(
                        messageId: MessageId(rawValue: "conformant-reply"),
                        content: .value([.text(TextContent(text: "Hello"))])))))
            try? await connection.sessionUpdate(
                UpdateSessionNotification(
                    sessionId: session, update: .stateUpdate(.idle(IdleStateUpdate(stopReason: .endTurn)))))
        }
    }

    /// Plays a resume in the order of ACP v2.
    static func resume(_ params: ResumeSessionRequest, on connection: AgentSideConnection) async throws -> ResumeSessionResponse {
        let session = params.sessionId
        if params.replayFrom != nil {
            try await connection.sessionUpdate(
                UpdateSessionNotification(
                    sessionId: session,
                    update: .userMessage(UserMessage(
                        messageId: MessageId(rawValue: "history-user"),
                        content: .value([.text(TextContent(text: "Say hello."))])))))
            try await connection.sessionUpdate(
                UpdateSessionNotification(
                    sessionId: session,
                    update: .agentMessage(AgentMessage(
                        messageId: MessageId(rawValue: "history-agent"),
                        content: .value([.text(TextContent(text: "Hello"))])))))
        }
        try await connection.sessionUpdate(
            UpdateSessionNotification(
                sessionId: session, update: .stateUpdate(.idle(IdleStateUpdate(stopReason: .endTurn)))))
        try await connection.sessionUpdate(
            UpdateSessionNotification(
                sessionId: session, update: .sessionInfoUpdate(SessionInfoUpdate(title: .value("Conformance")))))
        return ResumeSessionResponse()
    }
}
