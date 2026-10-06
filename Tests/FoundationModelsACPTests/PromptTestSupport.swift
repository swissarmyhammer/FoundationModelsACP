@testable import FoundationModelsACP

/// The `session/prompt` acknowledgement that the stub agents in these suites
/// return.
///
/// The schema requires each prompt response to name the user message that the
/// agent inserted. A stub agent does not echo the prompt, and no test that
/// uses this value reads the id. Thus all stubs name the same fixed message.
/// A suite that tests message identity makes its own id instead.
extension PromptResponse {
    /// The acknowledgement of a stub agent, which names one fixed user message.
    static let stubAcknowledgement = PromptResponse(messageId: MessageId(rawValue: "stub-user-message"))
}

/// An agent that answers each request at once and sends nothing of its own.
///
/// Use it when a test drives the agent side through the connection (for
/// example `requestPermission(_:)`), or needs only the response to a client
/// request (for example `session/prompt`).
struct StubAgent: Agent {
    /// The one session that `newSession(_:)` makes.
    static let sessionId = SessionId(rawValue: "stub-session")

    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(
            info: Implementation(name: "stub-agent", version: "0.0.0"),
            protocolVersion: .v2,
            capabilities: AgentCapabilities(session: SessionCapabilities())
        )
    }

    func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: Self.sessionId)
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
