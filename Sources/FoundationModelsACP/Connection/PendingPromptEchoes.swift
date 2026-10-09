import Synchronization

/// The `promptWithEcho(_:)` calls of a `ClientSideConnection` that wait for
/// their `session/prompt` response or for the echo of their user message.
///
/// Each session has its own `PendingPromptCorrelator`, so an echo in one
/// session never completes a prompt of a different session. The correlator
/// keeps only the message identifier of an echo that arrives before its
/// response. This type also keeps the first echo update of that message, so
/// that the call can return the update.
///
/// The connection calls ``observe(_:)`` for each decoded `session/update`, in
/// wire order, and ``finishAll()`` one time when it closes.
final class PendingPromptEchoes: Sendable {
    /// One prompt that this type records.
    struct Ticket: Hashable, Sendable {
        /// The session of the prompt.
        let sessionId: SessionId

        /// The local identifier of the prompt in the correlator of its
        /// session.
        let localID: Int
    }

    /// The recorded prompts of each session, guarded for the read loop and the
    /// calling tasks.
    private let state = Mutex(PromptEchoState())

    /// Records a prompt that the client is about to send.
    ///
    /// Call this before the connection writes `session/prompt`. Then an echo
    /// that arrives before the response is kept for the prompt.
    ///
    /// - Parameter sessionId: The session of the prompt.
    /// - Returns: The ticket of the prompt.
    func register(in sessionId: SessionId) -> Ticket {
        state.withLock { $0.register(in: sessionId) }
    }

    /// Waits for the echo of the user message that a response names.
    ///
    /// The call returns at once when the echo arrived before the response.
    ///
    /// - Parameters:
    ///   - ticket: The ticket of the prompt.
    ///   - response: The `session/prompt` response of the prompt.
    /// - Returns: The first echo update of the user message.
    /// - Throws: `ConnectionError.closed` when the connection closes before
    ///   the echo arrives, or `CancellationError` when the task is cancelled
    ///   before the echo arrives.
    func echo(for ticket: Ticket, response: PromptResponse) async throws -> SessionUpdate {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { $0.resolve(ticket, with: response, resuming: continuation) }?.resume()
            }
        } onCancel: {
            remove(ticket)
        }
    }

    /// Forgets a prompt. Call it when the request of the prompt fails.
    ///
    /// When a call waits for the echo of the prompt, the call throws
    /// `CancellationError`.
    ///
    /// - Parameter ticket: The ticket of the prompt.
    func remove(_ ticket: Ticket) {
        state.withLock { $0.remove(ticket) }?.resume(throwing: CancellationError())
    }

    /// Gives one decoded `session/update` to the prompts of its session.
    ///
    /// When the update is the first echo of a message that a response named,
    /// the call that waits for it returns the update.
    ///
    /// - Parameter notification: The session update.
    func observe(_ notification: UpdateSessionNotification) {
        state.withLock { $0.observe(notification) }?.resume()
    }

    /// Forgets each prompt. Each call that waits for an echo throws
    /// `ConnectionError.closed`, and so does each later call.
    func finishAll() {
        let waiting = state.withLock { $0.finishAll() }
        for continuation in waiting {
            continuation.resume(throwing: ConnectionError.closed)
        }
    }
}

/// The continuation of a call that waits for its echo.
private typealias EchoContinuation = CheckedContinuation<SessionUpdate, any Error>

/// A call that waits, and the result to resume it with. Resume it outside the
/// lock.
private struct EchoResumption {
    /// The waiting call.
    let continuation: EchoContinuation

    /// The echo, or the error to throw.
    let result: Result<SessionUpdate, any Error>

    /// Resumes the call with the result.
    func resume() {
        continuation.resume(with: result)
    }
}

/// The phase of one recorded prompt.
private enum PromptPhase {
    /// The prompt waits for its `session/prompt` response.
    case awaitingResponse

    /// The response arrived, and the call waits for the echo.
    case awaitingEcho(EchoContinuation)

    /// The call that waits for the echo, or `nil` when the prompt waits for
    /// its response.
    var echoContinuation: EchoContinuation? {
        switch self {
        case .awaitingResponse:
            nil
        case .awaitingEcho(let continuation):
            continuation
        }
    }
}

/// The recorded prompts of each session, and the close state.
private struct PromptEchoState {
    /// The recorded prompts, by session. A session with no recorded prompt
    /// has no entry.
    private var sessions: [SessionId: SessionPromptEchoes] = [:]

    /// The local identifier of the next recorded prompt.
    private var nextLocalID = 0

    /// Tells if the connection closed.
    private var isClosed = false

    /// Records a prompt.
    ///
    /// - Parameter sessionId: The session of the prompt.
    /// - Returns: The ticket of the prompt.
    mutating func register(in sessionId: SessionId) -> PendingPromptEchoes.Ticket {
        let ticket = PendingPromptEchoes.Ticket(sessionId: sessionId, localID: nextLocalID)
        nextLocalID += 1
        sessions[sessionId, default: SessionPromptEchoes()].add(ticket.localID)
        return ticket
    }

    /// Gives the response of a prompt, and records the call that waits for
    /// its echo.
    ///
    /// - Parameters:
    ///   - ticket: The ticket of the prompt.
    ///   - response: The response of the prompt.
    ///   - continuation: The call that waits for the echo.
    /// - Returns: The resumption of the call when it does not wait, or `nil`
    ///   when it waits for the echo.
    mutating func resolve(
        _ ticket: PendingPromptEchoes.Ticket,
        with response: PromptResponse,
        resuming continuation: EchoContinuation
    ) -> EchoResumption? {
        guard !isClosed else {
            return EchoResumption(continuation: continuation, result: .failure(ConnectionError.closed))
        }
        guard var session = sessions[ticket.sessionId], session.records(ticket.localID) else {
            return EchoResumption(continuation: continuation, result: .failure(CancellationError()))
        }
        let resumption = session.resolve(ticket.localID, with: response, resuming: continuation)
        store(session, for: ticket.sessionId)
        return resumption
    }

    /// Forgets a prompt.
    ///
    /// - Parameter ticket: The ticket of the prompt.
    /// - Returns: The call that waits for the echo of the prompt, or `nil`
    ///   when no call waits.
    mutating func remove(_ ticket: PendingPromptEchoes.Ticket) -> EchoContinuation? {
        guard var session = sessions[ticket.sessionId] else {
            return nil
        }
        let continuation = session.remove(ticket.localID)
        store(session, for: ticket.sessionId)
        return continuation
    }

    /// Gives one session update to the prompts of its session.
    ///
    /// - Parameter notification: The session update.
    /// - Returns: The resumption of the call whose echo this update is, or
    ///   `nil`.
    mutating func observe(_ notification: UpdateSessionNotification) -> EchoResumption? {
        guard var session = sessions[notification.sessionId] else {
            return nil
        }
        let resumption = session.observe(notification.update)
        store(session, for: notification.sessionId)
        return resumption
    }

    /// Marks the connection closed, and forgets each prompt.
    ///
    /// - Returns: Each call that waits for an echo.
    mutating func finishAll() -> [EchoContinuation] {
        isClosed = true
        let waiting = sessions.values.flatMap(\.waitingCalls)
        sessions.removeAll()
        return waiting
    }

    /// Stores the prompts of a session, or removes the entry of the session
    /// when it has no recorded prompt.
    ///
    /// - Parameters:
    ///   - session: The prompts of the session.
    ///   - sessionId: The session.
    private mutating func store(_ session: SessionPromptEchoes, for sessionId: SessionId) {
        sessions[sessionId] = session.isEmpty ? nil : session
    }
}

/// The recorded prompts of one session.
private struct SessionPromptEchoes {
    /// Links the prompts of the session to their echoes.
    private var correlator = PendingPromptCorrelator<Int>()

    /// The phase of each recorded prompt, by local identifier.
    private var phases: [Int: PromptPhase] = [:]

    /// The first update of each echo that the correlator keeps because no
    /// response named its message yet, by message identifier.
    private var earlyEchoUpdates: [MessageId: SessionUpdate] = [:]

    /// Tells if the session has no recorded prompt.
    var isEmpty: Bool {
        phases.isEmpty
    }

    /// Each call that waits for an echo.
    var waitingCalls: [EchoContinuation] {
        phases.values.compactMap(\.echoContinuation)
    }

    /// Tells if a prompt is recorded.
    ///
    /// - Parameter localID: The local identifier of the prompt.
    /// - Returns: `true` when the prompt is recorded.
    func records(_ localID: Int) -> Bool {
        phases[localID] != nil
    }

    /// Records a prompt that waits for its response.
    ///
    /// - Parameter localID: The local identifier of the prompt.
    mutating func add(_ localID: Int) {
        correlator.addPendingPrompt(localID)
        phases[localID] = .awaitingResponse
    }

    /// Gives the response of a prompt.
    ///
    /// - Parameters:
    ///   - localID: The local identifier of the prompt.
    ///   - response: The response of the prompt.
    ///   - continuation: The call that waits for the echo.
    /// - Returns: The resumption of the call when the echo arrived before the
    ///   response, or `nil` when the call waits for the echo.
    mutating func resolve(
        _ localID: Int,
        with response: PromptResponse,
        resuming continuation: EchoContinuation
    ) -> EchoResumption? {
        defer { forgetEarlyEchoUpdatesWhenNoPromptWaits() }
        guard let link = correlator.resolve(localID, with: response) else {
            phases[localID] = .awaitingEcho(continuation)
            return nil
        }
        phases.removeValue(forKey: localID)
        return EchoResumption(continuation: continuation, result: .success(takeEarlyEcho(of: link.messageId)))
    }

    /// Gives one session update of the session.
    ///
    /// - Parameter update: The session update.
    /// - Returns: The resumption of the call whose echo this update is, or
    ///   `nil`.
    mutating func observe(_ update: SessionUpdate) -> EchoResumption? {
        guard let link = correlator.observe(update) else {
            keepEarlyEcho(update)
            return nil
        }
        guard let continuation = phases.removeValue(forKey: link.localID)?.echoContinuation else {
            return nil
        }
        return EchoResumption(continuation: continuation, result: .success(update))
    }

    /// Forgets a prompt.
    ///
    /// - Parameter localID: The local identifier of the prompt.
    /// - Returns: The call that waits for the echo of the prompt, or `nil`
    ///   when no call waits.
    mutating func remove(_ localID: Int) -> EchoContinuation? {
        defer { forgetEarlyEchoUpdatesWhenNoPromptWaits() }
        correlator.removePendingPrompt(localID)
        return phases.removeValue(forKey: localID)?.echoContinuation
    }

    /// Keeps the first update of an echo that the correlator keeps.
    ///
    /// The correlator keeps an echo that makes no link while a prompt waits
    /// for its response. This method keeps the update in the same case.
    ///
    /// - Parameter update: A session update that made no link.
    private mutating func keepEarlyEcho(_ update: SessionUpdate) {
        guard correlator.isAwaitingResponse, let messageId = update.userMessageId,
            earlyEchoUpdates[messageId] == nil
        else {
            return
        }
        earlyEchoUpdates[messageId] = update
    }

    /// Takes the kept update of an echo that the correlator linked to a
    /// response.
    ///
    /// - Parameter messageId: The message identifier of the link.
    /// - Returns: The first update of the echo.
    private mutating func takeEarlyEcho(of messageId: MessageId) -> SessionUpdate {
        guard let update = earlyEchoUpdates.removeValue(forKey: messageId) else {
            // `keepEarlyEcho(_:)` keeps an update for each echo that the
            // correlator keeps, so a link at resolve time always has one.
            preconditionFailure("The correlator linked an early echo whose update was not kept: \(messageId.rawValue)")
        }
        return update
    }

    /// Forgets the kept echo updates when no prompt waits for its response,
    /// as the correlator forgets their message identifiers.
    private mutating func forgetEarlyEchoUpdatesWhenNoPromptWaits() {
        guard !correlator.isAwaitingResponse else {
            return
        }
        earlyEchoUpdates.removeAll()
    }
}
