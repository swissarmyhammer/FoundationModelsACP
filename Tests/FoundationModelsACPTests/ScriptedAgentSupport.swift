import Synchronization

import FoundationModelsACP

// MARK: - Scripted turns

/// One scripted prompt turn: emits `session/update` notifications through the
/// turn's context, then resolves the turn's ``StopReason``.
///
/// The pure-wire counterpart of a live model turn — a test scripts exactly the
/// updates a turn streams and the reason it stops, with no model involved.
typealias ScriptedTurn = @Sendable (ScriptedTurnContext) async throws -> StopReason

/// The wire surface a ``ScriptedTurn`` runs against: the serving connection and
/// the session the turn belongs to.
///
/// Reverse Agent→Client calls (`fs/*`, `session/request_permission`, …) go
/// straight through ``connection``; streamed updates go through ``update(_:)``.
struct ScriptedTurnContext: Sendable {
    /// The agent's serving connection, for reverse Agent→Client calls.
    let connection: AgentSideConnection

    /// The session the running turn belongs to.
    let sessionId: SessionId

    /// Sends one `session/update` notification for the turn's session.
    ///
    /// - Parameter update: The update to stream.
    /// - Throws: `ConnectionError.closed` after disconnect.
    func update(_ update: SessionUpdate) async throws {
        try await connection.sessionUpdate(SessionNotification(sessionId: sessionId, update: update))
    }
}

// MARK: - Scripted wire agent

/// A pure-wire ``Agent`` test double whose prompt turns run scripted update
/// sequences instead of a model (spec §8).
///
/// `initialize` advertises the package's canonical capabilities, `session/new`
/// always yields the fixed session identity, and each `session/prompt` consumes
/// the next enqueued ``ScriptedTurn`` (an empty queue ends the turn immediately
/// with ``StopReason/endTurn``). The turn runs as a registered task so
/// `session/cancel` cancels it mid-turn and the prompt resolves with
/// ``StopReason/cancelled`` — trailing updates the script sends after
/// cancellation still reach the client (spec §5).
final class ScriptedAgent: Agent {
    /// The serving connection, for the turns' reverse Agent→Client calls.
    private let connection: AgentSideConnection

    /// The identity every `session/new` returns.
    private let sessionId: SessionId

    /// Scripted turns not yet consumed, in FIFO order.
    private let turns = Mutex<[ScriptedTurn]>([])

    /// The running turn's task, for `session/cancel`.
    private let activeTurn = Mutex<Task<StopReason, any Error>?>(nil)

    /// Creates a scripted agent serving one fixed session.
    ///
    /// - Parameters:
    ///   - connection: The serving connection, captured for reverse calls.
    ///   - sessionId: The identity every `session/new` returns.
    init(connection: AgentSideConnection, sessionId: SessionId) {
        self.connection = connection
        self.sessionId = sessionId
    }

    /// Queues a scripted turn for a later `session/prompt`, consumed FIFO.
    ///
    /// Safe to call from a connection factory — before the read loop can
    /// dispatch the first prompt — closing any race.
    ///
    /// - Parameter turn: The scripted turn the next unconsumed prompt runs.
    func enqueueTurn(_ turn: @escaping ScriptedTurn) {
        turns.withLock { $0.append(turn) }
    }

    /// Negotiates the protocol version and advertises the canonical
    /// capabilities the golden fixtures pin: embedded context only.
    ///
    /// - Parameter params: The client's initialization request.
    /// - Returns: The canonical initialize response.
    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(
            protocolVersion: .latest,
            agentCapabilities: AgentCapabilities(
                promptCapabilities: PromptCapabilities(audio: false, embeddedContext: true, image: false)
            ),
            agentInfo: Implementation(name: "FoundationModelsACP", version: "0.1.0")
        )
    }

    /// Answers every `session/new` with the fixed session identity.
    ///
    /// - Parameter params: The new-session request; its contents are ignored.
    /// - Returns: The fixed session identity.
    func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: sessionId)
    }

    /// Runs the next scripted turn as a cancellable task and resolves with its
    /// stop reason — ``StopReason/cancelled`` when the turn was cancelled,
    /// regardless of what the script returned (spec §5).
    ///
    /// - Parameter params: The prompt request naming the turn's session.
    /// - Returns: The turn's outcome, carrying the stop reason.
    /// - Throws: Any non-cancellation error the script raised.
    func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        let turn = takeTurn()
        let context = ScriptedTurnContext(connection: connection, sessionId: params.sessionId)
        let generation = Task { try await turn(context) }
        activeTurn.withLock { $0 = generation }
        defer { activeTurn.withLock { $0 = nil } }
        do {
            let stopReason = try await generation.value
            return PromptResponse(stopReason: generation.isCancelled ? .cancelled : stopReason)
        } catch is CancellationError {
            return PromptResponse(stopReason: .cancelled)
        }
    }

    /// Cancels the running turn, if any; an idle session is a no-op.
    ///
    /// - Parameter params: The cancellation notification.
    func cancel(_ params: CancelNotification) async {
        activeTurn.withLock { $0 }?.cancel()
    }

    /// Removes and returns the next queued scripted turn, defaulting to an
    /// immediate ``StopReason/endTurn`` when the queue is empty.
    ///
    /// - Returns: The turn the prompt should run.
    private func takeTurn() -> ScriptedTurn {
        turns.withLock { queue in
            queue.isEmpty ? { @Sendable _ in .endTurn } : queue.removeFirst()
        }
    }
}

// MARK: - Session-update builders

/// Wraps text as an agent-message-chunk update.
///
/// - Parameter text: The chunk text.
/// - Returns: The message-chunk update.
func messageChunkUpdate(_ text: String) -> SessionUpdate {
    .agentMessageChunk(ContentChunk(content: .text(TextContent(text: text))))
}

/// Wraps text as an agent-thought-chunk update.
///
/// - Parameter text: The chunk text.
/// - Returns: The thought-chunk update.
func thoughtChunkUpdate(_ text: String) -> SessionUpdate {
    .agentThoughtChunk(ContentChunk(content: .text(TextContent(text: text))))
}

// MARK: - Turn instrumentation

/// Records an ordered log of turn events so a test can assert the exact
/// interleaving of concurrent turns.
actor TurnRecorder {
    /// The events recorded so far, in order.
    private var log: [String] = []

    /// Appends one event to the log.
    ///
    /// - Parameter event: The event name to record.
    func record(_ event: String) {
        log.append(event)
    }

    /// The ordered events recorded so far.
    func events() -> [String] {
        log
    }

    /// Whether the given event has been recorded.
    ///
    /// - Parameter event: The event name to look for.
    /// - Returns: `true` once the event has been recorded.
    func contains(_ event: String) -> Bool {
        log.contains(event)
    }
}

/// A one-shot gate a test opens to release turns it is holding mid-body,
/// letting the test control exactly when a turn completes.
actor TurnGate {
    /// Whether the gate has been opened.
    private var isOpen = false

    /// Continuations parked in ``wait()`` until the gate opens.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Opens the gate, resuming every parked waiter.
    func open() {
        isOpen = true
        let parked = waiters
        waiters.removeAll()
        for waiter in parked {
            waiter.resume()
        }
    }

    /// Suspends until the gate is open.
    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Spins until the recorder has seen `event`, yielding between checks.
///
/// Deterministic because the awaited event is one a turn body always records;
/// bounded by the test's time limit.
///
/// - Parameters:
///   - recorder: The recorder to poll.
///   - event: The event to wait for.
func waitUntil(_ recorder: TurnRecorder, records event: String) async {
    while await !recorder.contains(event) {
        await Task.yield()
    }
}
