import Foundation
import FoundationModels
import Synchronization

/// An ACP ``Agent`` that bridges a FoundationModels ``LanguageModelSession`` to
/// the Agent Client Protocol (spec §7).
///
/// The agent is an `actor`, so overlapping `session/prompt` requests to one
/// session serialize naturally: a ``LanguageModelSession`` runs one turn at a
/// time, and each pending request resolves at its own turn's end. Where sessions
/// come from is supplied by a ``SessionProvider``; there is deliberately no
/// engine protocol — the bridge always drives a real session.
///
/// A `session/prompt` drives `streamResponse(to:)`; the request stays open for
/// the whole turn while the bridge fires `session/update` notifications off the
/// growing `Transcript` (via ``TranscriptMapper``). The turn answers with the
/// derived ``StopReason``, a `session/cancel` cancels the running generation,
/// and ``SessionProvider/onTurnEnded`` sees the final transcript. The mapping is
/// driven through a ``TurnGenerator`` seam so tests script transcript entries
/// deterministically without a live model (two concurrent turns on one session
/// trap the process).
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

        /// The running turn's generation task, or `nil` when no turn is
        /// generating. Cancelling it propagates cancellation into the response
        /// stream, which is how a `session/cancel` reaches FoundationModels
        /// (there is no explicit session-cancel API). Its value is the turn's
        /// final transcript.
        var activeGeneration: Task<Transcript, any Error>?

        /// Wraps a live session with an idle turn chain.
        ///
        /// - Parameter session: The live model session for this ACP session.
        init(session: LanguageModelSession) {
            self.session = session
        }
    }

    /// Identifies this bridge to clients during initialization.
    private static let agentInfo = Implementation(name: "FoundationModelsACP", version: "0.1.0")

    /// The prompt content the bridge can render into a FoundationModels turn.
    ///
    /// Text and resource links are the baseline; embedded resources render as
    /// inline context. Image and audio are not rendered into the text prompt, so
    /// they stay off and a prompt carrying one is rejected with `-32602`.
    static let promptCapabilities = PromptCapabilities(
        audio: false,
        embeddedContext: true,
        image: false
    )

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
    /// corresponding provider hook is present; prompt capabilities advertise the
    /// content the bridge renders (``promptCapabilities``), which `prompt` then
    /// enforces. Advertising a session-management capability here does not yet
    /// forward its method — that forwarding is a follow-on task — so an
    /// unadvertised method still answers method-not-found via the ``Agent``
    /// protocol defaults.
    ///
    /// - Parameter params: The client's initialization request.
    /// - Returns: The negotiated protocol version and advertised capabilities.
    /// - Throws: Never; capability negotiation cannot fail. The `throws` is the
    ///   ``Agent`` protocol requirement.
    public func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(
            protocolVersion: .latest,
            agentCapabilities: AgentCapabilities(
                promptCapabilities: Self.promptCapabilities,
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
    /// The prompt's content blocks are validated and rendered into the model
    /// prompt before the turn is enqueued, so an unadvertised block type fails
    /// with `-32602` without touching the model. The turn then streams the
    /// response, firing `session/update` notifications off the growing
    /// transcript, and answers with the derived ``StopReason``.
    ///
    /// - Parameter params: The prompt request naming its session and content.
    /// - Returns: The turn's outcome, carrying the stop reason.
    /// - Throws: ``RequestError`` with code `-32602` when the session is unknown
    ///   or a content block's type is not advertised, or any unexpected model
    ///   error.
    public func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        let renderedPrompt = try PromptInputMapper.render(
            blocks: params.prompt,
            capabilities: Self.promptCapabilities
        )
        let sessionId = params.sessionId
        return try await serializeTurn(for: sessionId) {
            try await self.runTurn(for: sessionId) { deliver in
                try await self.streamTurn(for: sessionId, prompt: renderedPrompt, deliver: deliver)
            }
        }
    }

    /// Cancels the running turn on a session, if any.
    ///
    /// FoundationModels has no explicit session-cancel API; cancelling the
    /// generation task propagates through the response-stream iteration, so the
    /// model stops and the turn terminates through its prompt response with
    /// ``StopReason/cancelled`` — possibly after final updates land (spec §5).
    /// An unknown session or an idle one is a no-op.
    ///
    /// - Parameter params: The cancellation notification naming the session.
    public func cancel(_ params: CancelNotification) async {
        sessions[params.sessionId]?.activeGeneration?.cancel()
    }

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

    // MARK: - Turn execution

    /// Runs one prompt turn against the ``TurnGenerator`` seam: streams its
    /// transcript entries into `session/update` notifications, derives the stop
    /// reason, and hands the final transcript to ``SessionProvider/onTurnEnded``.
    ///
    /// The generator runs as a registered task so ``cancel(_:)`` can cancel it
    /// mid-turn; trailing updates it delivers after cancellation still reach the
    /// client, and the turn resolves with ``StopReason/cancelled``. Production
    /// supplies the real streaming generator; tests supply scripted entries.
    ///
    /// - Parameters:
    ///   - sessionId: The session the turn belongs to.
    ///   - generate: The turn's generator, delivering settled transcript entries
    ///     and returning the session's final transcript.
    /// - Returns: The turn's outcome, carrying the derived stop reason.
    /// - Throws: Any unexpected error the generator raised that is not a
    ///   recognized stop-reason signal.
    func runTurn(
        for sessionId: SessionId,
        generate: @escaping TurnGenerator
    ) async throws -> PromptResponse {
        let connection = self.connection
        let mapper = Mutex(TranscriptMapper())
        let latestEntries = Mutex<[Transcript.Entry]>([])

        let deliver: @Sendable ([Transcript.Entry]) async -> Void = { entries in
            latestEntries.withLock { $0 = entries }
            let updates = mapper.withLock { $0.consume(entries) }
            for update in updates {
                try? await connection.sessionUpdate(
                    SessionNotification(sessionId: sessionId, update: update)
                )
            }
        }

        let generation = registerGeneration(for: sessionId) {
            try await generate(deliver)
        }
        var failure: (any Error)?
        var finalTranscript: Transcript?
        do {
            finalTranscript = try await generation.value
        } catch {
            failure = error
        }
        clearGeneration(for: sessionId)

        let stopReason = try Self.stopReason(error: failure, cancelled: generation.isCancelled)
        let transcript = finalTranscript ?? Transcript(entries: latestEntries.withLock { $0 })
        if let onTurnEnded = provider.onTurnEnded {
            await onTurnEnded(sessionId, transcript)
        }
        return PromptResponse(stopReason: stopReason)
    }

    /// Starts a turn's generation task and records it for cancellation, with no
    /// suspension between creation and recording so a concurrent ``cancel(_:)``
    /// cannot miss it.
    ///
    /// - Parameters:
    ///   - sessionId: The session whose generation to record.
    ///   - work: The generation body, yielding the turn's final transcript.
    /// - Returns: The started task.
    private func registerGeneration(
        for sessionId: SessionId,
        _ work: @escaping @Sendable () async throws -> Transcript
    ) -> Task<Transcript, any Error> {
        let generation = Task { try await work() }
        sessions[sessionId]?.activeGeneration = generation
        return generation
    }

    /// Clears a session's recorded generation task once its turn has finished.
    ///
    /// - Parameter sessionId: The session whose generation to clear.
    private func clearGeneration(for sessionId: SessionId) {
        sessions[sessionId]?.activeGeneration = nil
    }

    /// Drives the real model turn: streams the response, delivering the turn's
    /// settled transcript entries so the caller maps them, and returns the
    /// session's final transcript.
    ///
    /// Each streamed snapshot carries the turn's growing entries; all but the
    /// still-generating last entry are delivered as they settle, then the whole
    /// turn is delivered once the stream ends. Cancellation is checked each
    /// snapshot so a cancelled turn stops promptly.
    ///
    /// - Parameters:
    ///   - sessionId: The session to run the turn on.
    ///   - prompt: The rendered prompt string.
    ///   - deliver: Sink for the turn's settled transcript entries.
    /// - Returns: The session's final transcript, for the turn-ended hook.
    /// - Throws: ``RequestError/invalidParams`` when the session is unknown, or
    ///   any error the model raised.
    private func streamTurn(
        for sessionId: SessionId,
        prompt: String,
        deliver: @Sendable ([Transcript.Entry]) async -> Void
    ) async throws -> Transcript {
        guard let session = sessions[sessionId]?.session else {
            throw RequestError.invalidParams
        }
        var turnEntries: [Transcript.Entry] = []
        for try await snapshot in session.streamResponse(to: prompt) {
            try Task.checkCancellation()
            turnEntries = Array(snapshot.transcriptEntries)
            if turnEntries.count > 1 {
                await deliver(Array(turnEntries.dropLast()))
            }
        }
        await deliver(turnEntries)
        return session.transcript
    }

    /// Derives the prompt turn's stop reason from how its generation ended.
    ///
    /// Cancellation wins over any error, so a cancelled turn always reports
    /// ``StopReason/cancelled`` even when the interruption surfaced as a thrown
    /// error. A context-window overflow maps to ``StopReason/maxTokens`` and a
    /// refusal or guardrail violation to ``StopReason/refusal``; any other error
    /// is unexpected and propagates.
    ///
    /// - Parameters:
    ///   - error: The error the generation raised, or nil on success.
    ///   - cancelled: Whether the generation task was cancelled.
    /// - Returns: The turn's stop reason.
    /// - Throws: The original error when it is not a recognized stop-reason
    ///   signal.
    static func stopReason(error: (any Error)?, cancelled: Bool) throws -> StopReason {
        if cancelled {
            return .cancelled
        }
        guard let error else {
            return .endTurn
        }
        if error is CancellationError {
            return .cancelled
        }
        if let modelError = error as? LanguageModelError {
            switch modelError {
            case .contextSizeExceeded:
                return .maxTokens
            case .guardrailViolation, .refusal:
                return .refusal
            default:
                throw error
            }
        }
        throw error
    }
}

/// Drives one prompt turn's generation to completion (spec §7).
///
/// The implementation delivers the turn's transcript entries as they settle so
/// the bridge can map them into `session/update` notifications, and returns the
/// session's final transcript for the turn-ended hook. Production drives a real
/// ``LanguageModelSession``; tests drive scripted entries through the same seam
/// without a live model, since two concurrent real turns on one session trap the
/// process.
typealias TurnGenerator = @Sendable (
    _ deliver: @Sendable ([Transcript.Entry]) async -> Void
) async throws -> Transcript
