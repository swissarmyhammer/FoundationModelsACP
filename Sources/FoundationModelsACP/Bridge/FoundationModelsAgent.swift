import Foundation
import FoundationModels

/// An ACP ``Agent`` that bridges a FoundationModels ``LanguageModelSession`` to
/// the Agent Client Protocol (spec §7).
///
/// The agent is an `actor`, so overlapping `session/prompt` requests to one
/// session serialize naturally: a ``LanguageModelSession`` runs one turn at a
/// time, and each pending request resolves at its own turn's end. Where sessions
/// come from is supplied by a ``SessionProvider``; there is deliberately no
/// engine protocol — the bridge always drives a real session.
///
/// This is the skeleton: `initialize` advertises capabilities and `newSession`
/// tracks provider-built sessions, but the full turn — driving
/// `streamResponse(to:)`, mapping the growing `Transcript` to `session/update`
/// notifications, deriving the `StopReason`, forwarding `cancel` to FM
/// cancellation, and invoking ``SessionProvider/onTurnEnded`` — lands in a
/// follow-on task. `prompt` here drives a minimal turn under the real
/// serialization so the turn chain is exercised end to end.
public actor FoundationModelsAgent: Agent {
    /// One tracked session: its live model session and the tail of its
    /// serialized turn chain.
    private final class SessionState {
        /// The live FoundationModels session driving this ACP session's turns.
        let session: LanguageModelSession

        /// Completion token for the most recently enqueued turn, or `nil` when
        /// the session is idle. A new turn awaits this before running and then
        /// publishes its own, giving strict per-session FIFO ordering.
        var turnTail: Task<Void, Never>?

        /// Wraps a live session with an idle turn chain.
        ///
        /// - Parameter session: The live model session for this ACP session.
        init(session: LanguageModelSession) {
            self.session = session
        }
    }

    /// Identifies this bridge to clients during initialization.
    private static let agentInfo = Implementation(name: "FoundationModelsACP", version: "0.1.0")

    /// The connection the factory handed this agent, for reverse Agent→Client
    /// calls (`session/update`, `session/request_permission`, `fs/*`,
    /// `terminal/*`) the turn will issue in a follow-on task.
    private let connection: AgentSideConnection

    /// Where this agent's sessions come from.
    private let provider: SessionProvider

    /// Live sessions, keyed by the identity the provider assigned.
    private var sessions: [SessionId: SessionState] = [:]

    /// Creates a bridge agent from a connection and a session provider.
    ///
    /// - Parameters:
    ///   - connection: The connection for reverse Agent→Client calls.
    ///   - provider: Supplies and, optionally, stores this agent's sessions.
    public init(connection: AgentSideConnection, provider: SessionProvider) {
        self.connection = connection
        self.provider = provider
    }

    /// Creates a single-session bridge: the flagship "Apple-native → ACP for
    /// free" one-liner (spec §7).
    ///
    /// Sugar for a ``SessionProvider`` whose factory always yields `session` and
    /// whose store hooks are all nil, so it behaves identically on the wire to
    /// an explicit single-session provider.
    ///
    /// - Parameters:
    ///   - connection: The connection for reverse Agent→Client calls.
    ///   - session: The single session every `session/new` yields.
    public init(connection: AgentSideConnection, session: LanguageModelSession) {
        self.init(connection: connection, provider: SessionProvider(session: session))
    }

    // MARK: - Agent

    /// Negotiates the protocol version and advertises capabilities.
    ///
    /// Session-management capabilities are advertised if and only if the
    /// corresponding provider hook is present; prompt capabilities stay at the
    /// baseline (text and resource links) the bridge maps today. Advertising a
    /// session-management capability here does not yet forward its method — that
    /// forwarding is a follow-on task — so an unadvertised method still answers
    /// method-not-found via the ``Agent`` protocol defaults.
    ///
    /// - Parameter params: The client's initialization request.
    /// - Returns: The negotiated protocol version and advertised capabilities.
    /// - Throws: Never; capability negotiation cannot fail. The `throws` is the
    ///   ``Agent`` protocol requirement.
    public func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(
            protocolVersion: .latest,
            agentCapabilities: AgentCapabilities(
                sessionCapabilities: SessionCapabilities(
                    delete: provider.deleteSession.map { _ in SessionDeleteCapabilities() },
                    list: provider.listSessions.map { _ in SessionListCapabilities() },
                    resume: provider.restoreSession.map { _ in SessionResumeCapabilities() }
                )
            ),
            agentInfo: Self.agentInfo
        )
    }

    /// Builds a new session through the provider and tracks it.
    ///
    /// - Parameter params: The new-session request carrying the cwd and MCP
    ///   configs handed to the provider verbatim.
    /// - Returns: The identity the provider assigned to the new session.
    /// - Throws: Any error the provider's factory throws.
    public func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        let (sessionId, session) = try await provider.makeSession(params.cwd, params.mcpServers)
        sessions[sessionId] = SessionState(session: session)
        return NewSessionResponse(sessionId: sessionId)
    }

    /// Runs one prompt turn, serialized against other turns on the same session.
    ///
    /// This drives a minimal turn so the per-session serialization is exercised;
    /// the full `Transcript` → `session/update` mapping and `StopReason`
    /// derivation land in a follow-on task.
    ///
    /// - Parameter params: The prompt request naming its session.
    /// - Returns: The turn's outcome.
    /// - Throws: ``RequestError/invalidParams`` when the session is unknown.
    public func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        try await serializeTurn(for: params.sessionId) {
            PromptResponse(stopReason: .endTurn)
        }
    }

    /// Handles a cancellation notification.
    ///
    /// Mapping cancellation onto FoundationModels session cancellation lands in a
    /// follow-on task; the minimal turn has nothing to interrupt.
    ///
    /// - Parameter params: The cancellation notification.
    public func cancel(_ params: CancelNotification) async {}

    // MARK: - Turn serialization

    /// Runs `body` as this session's next turn, strictly after every turn
    /// already enqueued for the session.
    ///
    /// Turns on one session never overlap — a `LanguageModelSession` traps the
    /// process if two turns run at once — while turns on distinct sessions run
    /// concurrently. The predecessor tail is read and the successor tail
    /// published with no suspension between them, so the FIFO ordering holds even
    /// under actor reentrancy (the real turn body suspends on the model). A
    /// failed turn still completes its token, so a throw never wedges the chain.
    ///
    /// - Parameters:
    ///   - sessionId: The session whose turn chain to append to.
    ///   - body: The turn's work, run once its predecessor completes.
    /// - Returns: The value `body` produced.
    /// - Throws: ``RequestError/invalidParams`` when the session is unknown, or
    ///   any error `body` throws.
    func serializeTurn<Value: Sendable>(
        for sessionId: SessionId,
        _ body: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        guard let state = sessions[sessionId] else {
            throw RequestError.invalidParams
        }
        let predecessor = state.turnTail
        let turn = Task {
            _ = await predecessor?.value
            return try await body()
        }
        state.turnTail = Task { _ = try? await turn.value }
        return try await turn.value
    }
}
