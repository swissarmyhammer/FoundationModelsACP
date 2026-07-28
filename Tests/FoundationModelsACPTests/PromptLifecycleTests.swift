import Foundation
import Synchronization
import Testing

@testable import FoundationModelsACP

// MARK: - Turn registry

/// The one script a `PromptLifecycleAgent` follows for every prompt it
/// accepts, injected at construction — the same "configure behavior through
/// the constructor" idiom `SessionManagingAgent` uses for its config options,
/// rather than parallel agent types per scenario.
private enum TurnScript: Sendable {
    /// Runs straight from `running` to `idle` with no pause.
    case completesImmediately

    /// Pauses on `requiresAction` for a `session/request_permission` answer
    /// before resuming to `running` and then completing.
    case requiresPermissionThenCompletes

    /// Never completes on its own; only `session/cancel` ends the turn.
    case runsUntilCancelled
}

/// Tracks the state `PromptLifecycleAgent` needs: which sessions exist, and
/// each session's in-flight turn, if any, so `session/cancel` can stop it.
///
/// A `Mutex`-guarded value type, not an actor: registration happens from
/// inside the closure `prompt(_:)` hands to
/// `AgentSideConnection.afterRespondingToCurrentRequest(_:)` — see that
/// method's doc comment for why the turn's `Task` is created there rather
/// than directly in `prompt(_:)` — and a synchronous lock keeps that closure
/// free of its own extra `await`s. `SessionUpdateRouter` guards its own
/// subscriber registry the same way, for the same reason.
private final class TurnRegistry: Sendable {
    private struct State {
        var sessions: Set<SessionId> = []
        var activeWork: [SessionId: Task<Void, Never>] = [:]
    }

    private let state = Mutex(State())

    /// Creates a session with a fresh id.
    ///
    /// - Returns: The new session's id.
    func createSession() -> SessionId {
        let id = SessionId(rawValue: UUID().uuidString)
        state.withLock { s in
            _ = s.sessions.insert(id)
        }
        return id
    }

    /// Whether a session id is tracked.
    ///
    /// - Parameter id: The session id to check.
    func exists(_ id: SessionId) -> Bool {
        state.withLock { $0.sessions.contains(id) }
    }

    /// Registers a session's in-flight turn, so a later cancel can stop it.
    ///
    /// - Parameters:
    ///   - id: The session the turn belongs to.
    ///   - task: The turn's task.
    func beginWork(_ id: SessionId, _ task: Task<Void, Never>) {
        state.withLock { $0.activeWork[id] = task }
    }

    /// Removes and returns a session's in-flight turn, if any — freeing the
    /// slot regardless of whether the caller goes on to cancel the task.
    ///
    /// - Parameter id: The session whose turn to take.
    /// - Returns: The turn's task, or `nil` when nothing was in flight.
    func takeActiveWork(_ id: SessionId) -> Task<Void, Never>? {
        state.withLock { s in
            guard let task = s.activeWork[id] else { return nil }
            s.activeWork[id] = nil
            return task
        }
    }
}

// MARK: - The M6 agent

/// An `Agent` implementing the v2 prompt lifecycle: `prompt(_:)` acknowledges
/// at once, and everything else — `running`, the user's message echoed back
/// with an agent-generated `messageId`, an optional `requiresAction` pause,
/// and the closing `idle` with a stop reason — arrives afterward as
/// `session/update` notifications, per `TurnScript`.
private final class PromptLifecycleAgent: Agent {
    /// The connection the factory handed this agent, captured so the turn can
    /// call back into the client with `session/update` notifications and
    /// `session/request_permission`.
    let connection: AgentSideConnection

    /// Session bookkeeping and in-flight turn tracking.
    let registry = TurnRegistry()

    /// The script every prompt on this agent follows.
    let script: TurnScript

    /// The stop reason a completed (non-cancelled) turn reports.
    let stopReason: StopReason

    /// Creates an agent bound to its own connection, script, and stop reason.
    ///
    /// - Parameters:
    ///   - connection: The connection the factory handed this agent.
    ///   - script: The script every prompt on this agent follows.
    ///   - stopReason: The stop reason a completed turn reports.
    init(connection: AgentSideConnection, script: TurnScript, stopReason: StopReason = .endTurn) {
        self.connection = connection
        self.script = script
        self.stopReason = stopReason
    }

    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(
            info: Implementation(name: "prompt-lifecycle-agent", version: "0.0.0"),
            protocolVersion: .v2,
            capabilities: AgentCapabilities(session: SessionCapabilities())
        )
    }

    func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: registry.createSession())
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

    /// Acknowledges at once. The turn itself — `running`, the echoed
    /// message, and eventually `idle` — starts only once `connection`
    /// confirms this response has been written, via
    /// `afterRespondingToCurrentRequest(_:)`: see that method's doc comment
    /// for why spawning the turn's `Task` directly here, before returning,
    /// would not be safe.
    func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        guard registry.exists(params.sessionId) else {
            throw RequestError.resourceNotFound(uri: params.sessionId.rawValue)
        }
        let messageId = MessageId(rawValue: UUID().uuidString)
        connection.afterRespondingToCurrentRequest { [self] in
            let task = Task<Void, Never> {
                await self.runTurn(sessionId: params.sessionId, content: params.prompt, messageId: messageId)
            }
            registry.beginWork(params.sessionId, task)
        }
        return PromptResponse()
    }

    func sessionCancel(_ params: CancelSessionNotification) async {
        guard let task = registry.takeActiveWork(params.sessionId) else { return }
        task.cancel()
        await task.value
        await send(sessionId: params.sessionId, .stateUpdate(.idle(IdleStateUpdate(stopReason: .cancelled))))
    }

    /// Runs one simulated turn: reports `running`, echoes the user's content
    /// as `user_message_chunk` updates sharing one agent-generated
    /// `messageId`, follows this agent's `script`, then reports `idle` with
    /// `stopReason` — unless cancelled first, in which case `sessionCancel`
    /// sends the `idle`/`cancelled` confirmation instead of this function.
    ///
    /// - Parameters:
    ///   - sessionId: The session the turn belongs to.
    ///   - content: The prompt's content blocks, echoed one chunk per block.
    ///   - messageId: The agent-generated id shared by every chunk.
    private func runTurn(sessionId: SessionId, content: [ContentBlock], messageId: MessageId) async {
        await send(sessionId: sessionId, .stateUpdate(.running(RunningStateUpdate())))
        for block in content {
            await send(sessionId: sessionId, .userMessageChunk(ContentChunk(content: block, messageId: messageId)))
        }

        switch script {
        case .completesImmediately:
            break

        case .requiresPermissionThenCompletes:
            await send(sessionId: sessionId, .stateUpdate(.requiresAction(RequiresActionStateUpdate())))
            _ = try? await connection.requestPermission(
                RequestPermissionRequest(
                    options: [
                        PermissionOption(kind: .allowOnce, name: "Allow", optionId: PermissionOptionId(rawValue: "allow"))
                    ],
                    sessionId: sessionId,
                    title: "Permission needed"
                )
            )
            await send(sessionId: sessionId, .stateUpdate(.running(RunningStateUpdate())))

        case .runsUntilCancelled:
            do {
                try await Task.sleep(for: indefiniteForegroundWorkDuration)
            } catch {
                return  // Cancelled; `sessionCancel` sends the idle/cancelled confirmation.
            }
        }

        _ = registry.takeActiveWork(sessionId)
        await send(sessionId: sessionId, .stateUpdate(.idle(IdleStateUpdate(stopReason: stopReason))))
    }

    /// Sends one `session/update` notification, swallowing a closed
    /// connection — every test here closes both ends once it finishes
    /// observing, and a late send racing that teardown is not a test
    /// failure.
    ///
    /// - Parameters:
    ///   - sessionId: The session the update pertains to.
    ///   - update: The update payload to send.
    private func send(sessionId: SessionId, _ update: SessionUpdate) async {
        try? await connection.sessionUpdate(UpdateSessionNotification(sessionId: sessionId, update: update))
    }
}

// MARK: - Clients

/// A client used only to open the connection; every test observes updates
/// through `ClientSideConnection.updates(for:)` instead of this handler, and
/// answers no permission request.
private struct PassiveClient: Client {
    func sessionUpdate(_ notification: UpdateSessionNotification) async {}

    func requestPermission(
        _ params: RequestPermissionRequest
    ) async throws -> RequestPermissionResponse {
        throw RequestError.methodNotFound("requestPermission")
    }
}

/// A client that answers every `session/request_permission` with one fixed
/// outcome, so a test can drive the `requiresAction` → answered → `running`
/// resumption.
private struct PermissionAnsweringClient: Client {
    let outcome: RequestPermissionOutcome

    func sessionUpdate(_ notification: UpdateSessionNotification) async {}

    func requestPermission(
        _ params: RequestPermissionRequest
    ) async throws -> RequestPermissionResponse {
        RequestPermissionResponse(outcome: outcome)
    }
}

// MARK: - A concurrency-safe ordered event log

/// Records events in the order they actually happen across concurrent tasks —
/// used by the ordering test to compare "the prompt response arrived" against
/// "the first `state_update` arrived" without either side's own scheduling
/// jitter deciding the outcome by accident: each event is appended only once
/// the real thing it names has actually occurred.
private actor EventLog {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    /// Discards everything recorded so far, so setup traffic (e.g. the
    /// `session/new` round trip) does not pollute a measurement window that
    /// starts later.
    func reset() {
        events.removeAll()
    }
}

/// Wraps an `ACPTransport`, classifying and recording every outgoing frame's
/// kind — before handing it to the real transport — so a test can read back
/// the literal order the wrapped side wrote frames onto the wire.
///
/// This measures the one thing `promptResponseArrivesBeforeTheFirstStateUpdate`
/// actually needs to know: not "which side's *continuation* got scheduled
/// first" — a client observing through `ClientSideConnection` is also racing
/// its own prompt-call continuation against the read loop's inline delivery
/// of an already-buffered next frame, which is a real but *separate*
/// scheduling question this milestone does not govern — but "did the agent
/// write the response frame before the first `state_update` frame."
private struct LoggingTransport: ACPTransport {
    let underlying: any ACPTransport
    let log: EventLog

    var bytes: AsyncThrowingStream<Data, any Error> { underlying.bytes }

    func write(_ data: Data) async throws {
        await log.record(Self.classify(data))
        try await underlying.write(data)
    }

    /// Classifies one outgoing frame as a `session/update` notification, a
    /// request response, or something else this suite does not care about.
    ///
    /// A response is distinguished from a request by the absence of
    /// `method` — the same test `Connection.owesResponse` applies on the
    /// production side — because an outbound *request* (e.g. this agent's
    /// own `session/request_permission`) also carries an `id`, and would
    /// otherwise be misclassified as the very response this test is
    /// measuring against.
    ///
    /// - Parameter data: The already-framed outgoing bytes.
    private static func classify(_ data: Data) -> String {
        guard
            let value = try? JSONDecoder().decode(JSONValue.self, from: data),
            case .object(let fields) = value
        else {
            return "other"
        }
        if fields["method"] == .string("session/update") { return "update" }
        if fields["id"] != nil, fields["method"] == nil { return "response" }
        return "other"
    }
}

// MARK: - Fixtures

/// The working directory every test session is created under; its value
/// never matters to these tests, only that session creation succeeds.
private let workingDirectory = AbsolutePath(rawValue: "/work")!

/// How many fresh agent/client pairs `promptResponseArrivesBeforeTheFirstStateUpdate`
/// drives through the same race: a single pass could observe the correct
/// order by luck even from an implementation that races the two writes, so
/// this needs to be large enough to make that luck implausible.
private let repetitionsForOrderingRaceDetection = 500

/// The `.runsUntilCancelled` script's foreground-work stand-in: long enough
/// that a test never reaches its end naturally, only through cancellation —
/// mirrors `SessionManagingAgent.prompt`'s identical stand-in in
/// `SessionLifecycleTests.swift`.
private let indefiniteForegroundWorkDuration: Duration = .seconds(3600)

// MARK: - Tests

/// `session/prompt` acknowledges immediately and reports everything else —
/// `running`, the echoed user message, an optional `requires_action` pause,
/// and the closing `idle`/`stopReason` — through `state_update` and other
/// `session/update` notifications, per `plan.md` M6.
@Suite struct PromptLifecycleTests {
    // MARK: Fixture wiring

    /// Wires an agent/client pair over `InMemoryTransport` and creates one
    /// session on it, ready to prompt.
    ///
    /// - Parameters:
    ///   - script: The script the agent's turns follow.
    ///   - stopReason: The stop reason a completed turn reports.
    ///   - clientFactory: Builds the `Client` the connection serves;
    ///     defaults to one that only observes.
    /// - Returns: The agent connection, the client connection, and the new
    ///   session's id.
    private func makeSessionPair(
        script: TurnScript,
        stopReason: StopReason = .endTurn,
        clientFactory: @escaping @Sendable (ClientSideConnection) -> any Client = { _ in PassiveClient() }
    ) async throws -> (agentConn: AgentSideConnection, client: ClientSideConnection, session: SessionId) {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agentConn = await AgentSideConnection(stream: agentEnd) { conn in
            PromptLifecycleAgent(connection: conn, script: script, stopReason: stopReason)
        }
        let client = await ClientSideConnection(stream: clientEnd, clientFactory)
        let session = try await client.newSession(NewSessionRequest(cwd: workingDirectory)).sessionId
        return (agentConn, client, session)
    }

    // MARK: session/prompt acknowledges with {}

    @Test func promptResponseEncodesAsAnEmptyObject() throws {
        // "It returns `{}` immediately" — the literal wire shape of
        // acceptance, independent of any live agent/client scenario.
        #expect(try WireRoundTrip.encode(PromptResponse()) == .object([:]))
    }

    // MARK: Ordering — the entire semantic change

    @Test(.timeLimit(.minutes(2)))
    func promptResponseArrivesBeforeTheFirstStateUpdate() async throws {
        // Repeated many times: a single pass could observe the correct order
        // by luck even from an implementation that races the two writes, and
        // this is the one guarantee the whole milestone rests on.
        for _ in 0..<repetitionsForOrderingRaceDetection {
            let log = EventLog()
            let (clientEnd, rawAgentEnd) = InMemoryTransport.pair()
            let agentEnd = LoggingTransport(underlying: rawAgentEnd, log: log)
            let agentConn = await AgentSideConnection(stream: agentEnd) { conn in
                PromptLifecycleAgent(connection: conn, script: .completesImmediately)
            }
            let client = await ClientSideConnection(stream: clientEnd) { _ in PassiveClient() }
            let session = try await client.newSession(NewSessionRequest(cwd: workingDirectory)).sessionId

            // `session/new`'s own response wrote a frame too; clear it so the
            // measurement window below starts clean at the prompt itself.
            await log.reset()

            var updates = client.updates(for: session).makeAsyncIterator()
            _ = try await client.prompt(PromptRequest(prompt: [.text(TextContent(text: "go"))], sessionId: session))
            // Waiting for the first delivered update guarantees the agent has
            // by now written it — so the log below already holds both frames
            // in the literal order the agent wrote them to the wire.
            #expect(await updates.next() == .stateUpdate(.running(RunningStateUpdate())))

            let events = await log.events
            #expect(events.first == "response", "wire order was \(events), expected the response written first")
            #expect(events.dropFirst().first == "update", "wire order was \(events), expected the update written second")

            await agentConn.close()
            await client.close()
        }
    }

    // MARK: A full turn: running -> idle with a stopReason

    @Test(.timeLimit(.minutes(1)))
    func aFullTurnProducesRunningThenIdleWithAStopReason() async throws {
        let (agentConn, client, session) = try await makeSessionPair(script: .completesImmediately, stopReason: .maxTokens)
        var updates = client.updates(for: session).makeAsyncIterator()

        let response = try await client.prompt(PromptRequest(prompt: [.text(TextContent(text: "go"))], sessionId: session))
        #expect(response == PromptResponse())

        #expect(await updates.next() == .stateUpdate(.running(RunningStateUpdate())))
        let echoed = try #require(await updates.next())
        guard case .userMessageChunk = echoed else {
            Issue.record("expected a user_message_chunk, got \(echoed)")
            return
        }
        #expect(await updates.next() == .stateUpdate(.idle(IdleStateUpdate(stopReason: .maxTokens))))

        await agentConn.close()
        await client.close()
    }

    // MARK: The agent owns message identity

    @Test(.timeLimit(.minutes(1)))
    func acceptingAPromptEmitsUserMessageChunksSharingOneStableAgentGeneratedMessageId() async throws {
        let (agentConn, client, session) = try await makeSessionPair(script: .completesImmediately)
        var updates = client.updates(for: session).makeAsyncIterator()

        _ = try await client.prompt(
            PromptRequest(
                prompt: [.text(TextContent(text: "first")), .text(TextContent(text: "second"))],
                sessionId: session
            )
        )

        _ = try #require(await updates.next())  // running
        let firstUpdate = try #require(await updates.next())
        let secondUpdate = try #require(await updates.next())
        guard
            case .userMessageChunk(let first) = firstUpdate,
            case .userMessageChunk(let second) = secondUpdate
        else {
            Issue.record("expected two user_message_chunk updates, got \(firstUpdate) and \(secondUpdate)")
            return
        }

        #expect(!first.messageId.rawValue.isEmpty)
        // Stable across chunks: the second chunk carries the very same id the
        // first one did, not a fresh one per chunk.
        #expect(first.messageId == second.messageId)
        #expect(first.content == .text(TextContent(text: "first")))
        #expect(second.content == .text(TextContent(text: "second")))

        _ = try #require(await updates.next())  // idle

        await agentConn.close()
        await client.close()
    }

    // MARK: requires_action, then resumed to running once answered

    @Test(.timeLimit(.minutes(1)))
    func aBlockedTurnReportsRequiresActionThenResumesToRunningOnceAnswered() async throws {
        let selected = RequestPermissionOutcome.selected(
            SelectedPermissionOutcome(optionId: PermissionOptionId(rawValue: "allow"))
        )
        let (agentConn, client, session) = try await makeSessionPair(
            script: .requiresPermissionThenCompletes,
            clientFactory: { _ in PermissionAnsweringClient(outcome: selected) }
        )
        var updates = client.updates(for: session).makeAsyncIterator()

        _ = try await client.prompt(PromptRequest(prompt: [.text(TextContent(text: "go"))], sessionId: session))

        #expect(await updates.next() == .stateUpdate(.running(RunningStateUpdate())))
        let echoed = try #require(await updates.next())
        guard case .userMessageChunk = echoed else {
            Issue.record("expected a user_message_chunk, got \(echoed)")
            return
        }
        #expect(await updates.next() == .stateUpdate(.requiresAction(RequiresActionStateUpdate())))
        // Resumed to running only once the permission request was answered —
        // not before, since the agent awaits it in between.
        #expect(await updates.next() == .stateUpdate(.running(RunningStateUpdate())))
        #expect(await updates.next() == .stateUpdate(.idle(IdleStateUpdate(stopReason: .endTurn))))

        await agentConn.close()
        await client.close()
    }

    // MARK: session/cancel -> idle + cancelled

    @Test(.timeLimit(.minutes(1)))
    func sessionCancelMidTurnYieldsIdleAndCancelled() async throws {
        let (agentConn, client, session) = try await makeSessionPair(script: .runsUntilCancelled)
        var updates = client.updates(for: session).makeAsyncIterator()

        _ = try await client.prompt(PromptRequest(prompt: [.text(TextContent(text: "go"))], sessionId: session))

        #expect(await updates.next() == .stateUpdate(.running(RunningStateUpdate())))
        let echoed = try #require(await updates.next())
        guard case .userMessageChunk = echoed else {
            Issue.record("expected a user_message_chunk, got \(echoed)")
            return
        }

        // A notification, not a request: nothing here waits on the agent.
        try await client.sessionCancel(CancelSessionNotification(sessionId: session))
        #expect(await updates.next() == .stateUpdate(.idle(IdleStateUpdate(stopReason: .cancelled))))

        await agentConn.close()
        await client.close()
    }

    // MARK: stopReason round trips, unknown ones preserved

    @Test func everyKnownStopReasonRoundTripsThroughAnIdleStateUpdate() throws {
        let declaredTags = try Self.declaredStopReasonTags()
        #expect(!declaredTags.isEmpty, "StopReason declared no tags; the schema lookup below is pointed at the wrong path")
        for tag in declaredTags {
            let update = try WireRoundTrip.expectLossless(StateUpdate.self, #"{"state":"idle","stopReason":"\#(tag)"}"#)
            guard case .idle(let idle) = update, let stopReason = idle.stopReason else {
                Issue.record("expected an idle state_update carrying a stopReason for tag \"\(tag)\"")
                continue
            }
            #expect(stopReason.wireValue == tag)
            #expect(stopReason != .unknown(tag), "known tag \"\(tag)\" fell through to the unknown fallback")
        }
    }

    @Test func anUnrecognizedStopReasonSurvivesRoundTripThroughAnIdleStateUpdate() throws {
        // The bare-value half of this (`StopReason.unknown` on its own) is
        // already pinned by `UnknownFallbackRoundTripTests`; this is the
        // sibling path that half does not reach — the same value nested
        // inside the `idle` state_update a real agent actually sends.
        let update = try WireRoundTrip.expectLossless(StateUpdate.self, """
            {"state":"idle","stopReason":"_vendor_paused"}
            """)
        guard case .idle(let idle) = update else {
            Issue.record("expected .idle, got \(update)")
            return
        }
        #expect(idle.stopReason == .unknown("_vendor_paused"))
    }

    // MARK: - Schema access

    /// The package root, derived from this file's location so the suite does
    /// not depend on the test runner's working directory.
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // FoundationModelsACPTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // package root

    /// The vendored schema document, parsed once.
    private static let schema: JSONValue = {
        let url = packageRoot.appendingPathComponent("Schema/acp-v2.json")
        // A test fixture that cannot be read is a broken test, not a failure
        // to report per assertion.
        return try! JSONDecoder().decode(JSONValue.self, from: try! Data(contentsOf: url))
    }()

    /// Every `const`-pinned wire value `StopReason`'s schema union declares —
    /// derived from the vendored schema rather than hardcoded, so a revision
    /// that adds, removes, or renames a stop reason changes what this test
    /// covers instead of leaving it silently stale.
    ///
    /// - Returns: The declared wire values, in schema order.
    /// - Throws: A test failure when the definition declares no union.
    private static func declaredStopReasonTags() throws -> [String] {
        let variants = try #require(schema["$defs"]?["StopReason"]?["anyOf"])
        guard case .array(let entries) = variants else {
            Issue.record("StopReason has no anyOf array")
            return []
        }
        return entries.compactMap { entry -> String? in
            guard case .string(let tag)? = entry["const"] else { return nil }
            return tag
        }
    }
}
