import Foundation
import Testing

@testable import FoundationModelsACP

// MARK: - Fixtures

/// A first interleaved session id.
private let sessionOne = SessionId(rawValue: "session-stream-1")

/// A second interleaved session id.
private let sessionTwo = SessionId(rawValue: "session-stream-2")

/// A client whose handlers all ignore or refuse what they serve — tests
/// observe delivery through `ClientSideConnection.subscribe(to:)` instead.
private struct MinimalClient: Client {
    func sessionUpdate(_ notification: UpdateSessionNotification) async {}

    func requestPermission(
        _ params: RequestPermissionRequest
    ) async throws -> RequestPermissionResponse {
        throw RequestError.methodNotFound("requestPermission")
    }

    func createElicitation(
        _ params: CreateElicitationRequest
    ) async throws -> CreateElicitationResponse {
        throw RequestError.methodNotFound("createElicitation")
    }

    func elicitationComplete(_ notification: CompleteElicitationNotification) async {}
}

/// Builds a `session/update` notification model for one session.
///
/// - Parameters:
///   - session: The session the update pertains to.
///   - update: The update payload to carry.
/// - Returns: The assembled notification.
private func notification(
    for session: SessionId,
    _ update: SessionUpdate
) -> UpdateSessionNotification {
    UpdateSessionNotification(sessionId: session, update: update)
}

/// An agent-message-chunk update carrying one text fragment.
///
/// - Parameter text: The chunk's text.
/// - Returns: The update payload.
private func messageChunk(_ text: String) -> SessionUpdate {
    .agentMessageChunk(ContentChunk(content: .text(TextContent(text: text)), messageId: MessageId(rawValue: "m1")))
}

/// A tool-call-update straggler naming one tool call.
///
/// - Parameter id: The tool call's identifier.
/// - Returns: The update payload.
private func toolCallUpdate(_ id: String) -> SessionUpdate {
    .toolCallUpdate(ToolCallUpdate(toolCallId: ToolCallId(rawValue: id)))
}

/// An `idle` `state_update`, optionally reporting why foreground work stopped.
///
/// - Parameter stopReason: The reported stop reason, or `nil` to omit it.
/// - Returns: The update payload.
private func idleState(stopReason: StopReason?) -> SessionUpdate {
    .stateUpdate(.idle(IdleStateUpdate(stopReason: stopReason)))
}

/// Frames a `session/update` notification as a JSON-RPC envelope for the wire.
///
/// - Parameter notification: The notification to send.
/// - Returns: The envelope value ready to write over a transport.
/// - Throws: Rethrows any encoding failure.
private func sessionUpdateEnvelope(_ notification: UpdateSessionNotification) throws -> JSONValue {
    sessionUpdateEnvelope(params: try JSONValue.encode(result: notification))
}

/// Frames raw `session/update` params as a JSON-RPC envelope for the wire.
///
/// Use this to send params that the notification model cannot encode, for
/// example a payload with a field of the wrong type.
///
/// - Parameter params: The raw notification params.
/// - Returns: The envelope value ready to write over a transport.
private func sessionUpdateEnvelope(params: JSONValue) -> JSONValue {
    .object([
        "jsonrpc": .string("2.0"),
        "method": .string("session/update"),
        "params": params,
    ])
}

/// The `sessionUpdate` discriminator of a tool-call update on the wire.
private let toolCallUpdateDiscriminator = "tool_call_update"

/// The wire name of the tool call ID field of a tool-call update.
private let toolCallIdField = "toolCallId"

/// A tool call ID of the wrong type: the schema requires a string.
private let malformedToolCallId = JSONValue.number(42)

/// The params of a `tool_call_update` for `sessionOne` whose tool call ID is a
/// number. The client knows the variant, but the payload does not decode.
private let malformedToolCallUpdateParams = JSONValue.object([
    "sessionId": .string(sessionOne.rawValue),
    "update": .object([
        "sessionUpdate": .string(toolCallUpdateDiscriminator),
        toolCallIdField: malformedToolCallId,
    ]),
])

/// Frames a JSON-RPC success response keyed to a request id.
///
/// - Parameters:
///   - id: The request's wire id, echoed on the response.
///   - result: The response model to send as the result.
/// - Returns: The response envelope ready to write over a transport.
/// - Throws: Rethrows any encoding failure.
private func responseEnvelope(id: JSONValue, result: some Encodable) throws -> JSONValue {
    .object([
        "jsonrpc": .string("2.0"),
        "id": id,
        "result": try JSONValue.encode(result: result),
    ])
}

/// Frames a `session/prompt` acknowledgement keyed to a request id.
///
/// - Parameters:
///   - id: The prompt request's wire id, echoed on the response.
///   - messageId: The id of the user message that the agent inserted for the
///     prompt. The response names this id.
/// - Returns: The response envelope ready to write over a transport.
/// - Throws: Rethrows any encoding failure.
private func promptAckEnvelope(id: JSONValue, messageId: MessageId) throws -> JSONValue {
    try responseEnvelope(id: id, result: PromptResponse(messageId: messageId))
}

/// Creates `sessionOne` over the wire, and sends updates for it before the
/// `session/new` response, as an agent can do.
///
/// - Parameters:
///   - client: The connection that sends `session/new`.
///   - reader: The raw agent-end reader that observes the outbound request.
///   - agentEnd: The raw agent end that writes the updates and the response.
///   - earlyUpdates: The updates to send before the response, in order.
/// - Returns: The session ID that the response gives.
/// - Throws: Rethrows any transport or request failure.
private func createSession(
    on client: ClientSideConnection,
    reader: WireReader,
    agentEnd: some ACPTransport,
    sendingFirst earlyUpdates: [SessionUpdate]
) async throws -> SessionId {
    let task = Task {
        try await client.newSession(NewSessionRequest(cwd: AbsolutePath(rawValue: "/work")))
    }
    let id = try #require(requestID(of: try await reader.next()))
    for update in earlyUpdates {
        try await send(sessionUpdateEnvelope(notification(for: sessionOne, update)), over: agentEnd)
    }
    try await send(responseEnvelope(id: id, result: NewSessionResponse(sessionId: sessionOne)), over: agentEnd)
    return try await task.value.sessionId
}

/// Closes `sessionOne` over the wire and answers the request as the agent.
///
/// - Parameters:
///   - client: The connection that sends `session/close`.
///   - reader: The raw agent-end reader that observes the outbound request.
///   - agentEnd: The raw agent end that writes the response.
/// - Throws: Rethrows any transport or request failure.
private func closeSessionOne(
    on client: ClientSideConnection,
    reader: WireReader,
    agentEnd: some ACPTransport
) async throws {
    let task = Task {
        try await client.closeSession(CloseSessionRequest(sessionId: sessionOne))
    }
    let id = try #require(requestID(of: try await reader.next()))
    try await send(responseEnvelope(id: id, result: CloseSessionResponse()), over: agentEnd)
    _ = try await task.value
}

/// Limits that keep one update for one session, so a second update overflows.
private let oneUpdateLimits = SessionUpdateBufferLimits(maximumUpdatesPerSession: 1, maximumSessions: 1)

/// Drives a prompt request over the client and returns its wire id, so a test
/// can script the agent's trailing updates and acknowledgement by hand.
///
/// - Parameters:
///   - client: The connection to prompt.
///   - session: The session to prompt in.
///   - reader: The raw agent-end reader that observes the outbound request.
/// - Returns: The prompt task awaiting the acknowledgement, and the request's
///   wire id.
/// - Throws: Rethrows any transport read failure.
private func startPrompt(
    on client: ClientSideConnection,
    session: SessionId,
    reader: WireReader
) async throws -> (task: Task<PromptResponse, any Error>, id: JSONValue) {
    let task = Task {
        try await client.prompt(PromptRequest(prompt: [.text(TextContent(text: "go"))], sessionId: session))
    }
    let request = try await reader.next()
    let id = try #require(requestID(of: request))
    return (task, id)
}

// MARK: - Demux

@Test(.timeLimit(.minutes(1)))
func updatesDemuxAcrossInterleavedSessions() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await ClientSideConnection(stream: clientEnd) { _ in MinimalClient() }

    var firstUpdates = client.subscribe(to: sessionOne).updates.makeAsyncIterator()
    var secondUpdates = client.subscribe(to: sessionTwo).updates.makeAsyncIterator()

    try await send(sessionUpdateEnvelope(notification(for: sessionOne, messageChunk("a1"))), over: agentEnd)
    try await send(sessionUpdateEnvelope(notification(for: sessionTwo, messageChunk("b1"))), over: agentEnd)
    try await send(sessionUpdateEnvelope(notification(for: sessionOne, messageChunk("a2"))), over: agentEnd)

    let firstA = await firstUpdates.nextUpdate()
    let firstB = await firstUpdates.nextUpdate()
    let secondA = await secondUpdates.nextUpdate()

    #expect(firstA == messageChunk("a1"))
    #expect(firstB == messageChunk("a2"))
    #expect(secondA == messageChunk("b1"))

    await client.close()
}

// MARK: - Straggler after the idle state_update

@Test(.timeLimit(.minutes(1)))
func lateToolCallUpdateAfterIdleStateUpdateIsDelivered() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await ClientSideConnection(stream: clientEnd) { _ in MinimalClient() }
    let reader = WireReader(agentEnd)

    var updates = client.subscribe(to: sessionOne).updates.makeAsyncIterator()
    let (prompt, id) = try await startPrompt(on: client, session: sessionOne, reader: reader)

    // v2's prompt acknowledges immediately — the turn's actual progress and
    // completion arrive as `state_update` notifications, not as this response.
    // The client must give back the user-message id that the agent sent.
    let promptMessage = MessageId(rawValue: "user-msg-straggler")
    try await send(promptAckEnvelope(id: id, messageId: promptMessage), over: agentEnd)
    #expect(try await prompt.value.messageId == promptMessage)

    try await send(sessionUpdateEnvelope(notification(for: sessionOne, messageChunk("mid-turn"))), over: agentEnd)
    try await send(sessionUpdateEnvelope(notification(for: sessionOne, idleState(stopReason: .endTurn))), over: agentEnd)

    // A tool_call_update straggler that arrives AFTER the idle state_update is
    // still delivered on the session's stream.
    try await send(sessionUpdateEnvelope(notification(for: sessionOne, toolCallUpdate("call-late"))), over: agentEnd)

    #expect(await updates.nextUpdate() == messageChunk("mid-turn"))
    #expect(await updates.nextUpdate() == idleState(stopReason: .endTurn))
    #expect(await updates.nextUpdate() == toolCallUpdate("call-late"))

    await client.close()
}

// MARK: - Post-cancel stragglers then the cancelled stop reason

@Test(.timeLimit(.minutes(1)))
func postCancelTrailingUpdatesThenCancelledStopReasonInOrder() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await ClientSideConnection(stream: clientEnd) { _ in MinimalClient() }
    let reader = WireReader(agentEnd)

    var updates = client.subscribe(to: sessionOne).updates.makeAsyncIterator()
    let (prompt, id) = try await startPrompt(on: client, session: sessionOne, reader: reader)
    let promptMessage = MessageId(rawValue: "user-msg-cancelled")
    try await send(promptAckEnvelope(id: id, messageId: promptMessage), over: agentEnd)
    #expect(try await prompt.value.messageId == promptMessage)

    // The client cancels; cancel is a notification, so nothing here waits.
    try await client.sessionCancel(CancelSessionNotification(sessionId: sessionOne))

    // Trailing updates land after the cancel, then an idle state_update
    // confirms the cancellation with `stopReason: cancelled`.
    try await send(
        sessionUpdateEnvelope(notification(for: sessionOne, toolCallUpdate("call-trailing"))), over: agentEnd
    )
    try await send(
        sessionUpdateEnvelope(notification(for: sessionOne, messageChunk("winding down"))), over: agentEnd
    )
    try await send(
        sessionUpdateEnvelope(notification(for: sessionOne, idleState(stopReason: .cancelled))), over: agentEnd
    )

    // The updates are observed on the stream, in wire order.
    #expect(await updates.nextUpdate() == toolCallUpdate("call-trailing"))
    #expect(await updates.nextUpdate() == messageChunk("winding down"))
    #expect(await updates.nextUpdate() == idleState(stopReason: .cancelled))

    await client.close()
}

// MARK: - An update for a session with no subscriber

@Test(.timeLimit(.minutes(1)))
func anUpdateForASessionWithNoSubscriberDoesNotStopOtherSessions() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await ClientSideConnection(stream: clientEnd) { _ in MinimalClient() }

    // Nobody subscribes to sessionTwo, so the connection keeps its update.
    // sessionOne's subscriber proves that the read loop continues after it
    // keeps the update.
    var firstUpdates = client.subscribe(to: sessionOne).updates.makeAsyncIterator()

    try await send(sessionUpdateEnvelope(notification(for: sessionTwo, messageChunk("nobody-listens"))), over: agentEnd)
    try await send(sessionUpdateEnvelope(notification(for: sessionOne, messageChunk("still-here"))), over: agentEnd)

    #expect(await firstUpdates.nextUpdate() == messageChunk("still-here"))

    await client.close()
}

// MARK: - A known update whose payload does not decode

@Test(.timeLimit(.minutes(1)))
func aKnownUpdateWithABadFieldTypeLogsOneWarningAndLaterUpdatesStillArrive() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let log = LogCapture()
    let client = await ClientSideConnection(stream: clientEnd, logger: log.logger) { _ in MinimalClient() }
    var updates = client.subscribe(to: sessionOne).updates.makeAsyncIterator()

    try await send(sessionUpdateEnvelope(params: malformedToolCallUpdateParams), over: agentEnd)
    try await send(sessionUpdateEnvelope(notification(for: sessionOne, messageChunk("after-bad"))), over: agentEnd)

    // The connection reads the notifications in wire order, so the warning
    // for the bad update is in the log when the later update arrives.
    #expect(await updates.nextUpdate() == messageChunk("after-bad"))
    let warnings = log.messages
    #expect(warnings.count == 1)
    let warning = try #require(warnings.first)
    #expect(warning.contains(sessionOne.rawValue))
    #expect(warning.contains(toolCallUpdateDiscriminator))
    #expect(warning.contains(toolCallIdField))

    await client.close()
}

// MARK: - Stream finish on disconnect

@Test(.timeLimit(.minutes(1)))
func connectionEOFFinishesAllSessionStreams() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await ClientSideConnection(stream: clientEnd) { _ in MinimalClient() }

    let firstStream = client.subscribe(to: sessionOne).updates
    let secondStream = client.subscribe(to: sessionTwo).updates

    // Each collector drains its stream to completion, so it returns only once
    // the stream finishes. It counts the updates, and skips each
    // request-finished marker.
    let firstCollector = Task { var count = 0; for await case .update in firstStream { count += 1 }; return count }
    let secondCollector = Task { var count = 0; for await case .update in secondStream { count += 1 }; return count }

    // One update reaches the first session, then the peer closes: EOF must
    // finish both streams so neither collector hangs past the buffered update.
    try await send(sessionUpdateEnvelope(notification(for: sessionOne, messageChunk("last"))), over: agentEnd)
    agentEnd.close()

    #expect(await firstCollector.value == 1)
    #expect(await secondCollector.value == 0)

    await client.close()
}

// MARK: - Router buffer before the first subscription

/// Builds a router whose warnings go to a capture.
///
/// - Parameter limits: The buffer limits for the router.
/// - Returns: The router and the capture that receives its warnings.
private func makeRouter(
    limits: SessionUpdateBufferLimits = .default
) -> (router: SessionUpdateRouter, log: LogCapture) {
    let log = LogCapture()
    return (SessionUpdateRouter(limits: limits, logger: log.logger), log)
}

/// Reads every event of a subscription until its stream finishes.
///
/// - Parameter subscription: The subscription to drain.
/// - Returns: The events, in order.
private func drain(_ subscription: SessionUpdateSubscription) async -> [SessionStreamEvent] {
    var received: [SessionStreamEvent] = []
    for await event in subscription.updates {
        received.append(event)
    }
    return received
}

@Test(.timeLimit(.minutes(1)))
func routerGivesBufferedUpdatesToTheFirstSubscriberInOrderBeforeLiveUpdates() async {
    let (router, log) = makeRouter()
    router.deliver(notification(for: sessionOne, messageChunk("early-1")))
    router.deliver(notification(for: sessionOne, messageChunk("early-2")))

    let subscription = router.subscribe(to: sessionOne)
    router.deliver(notification(for: sessionOne, messageChunk("live")))

    var updates = subscription.updates.makeAsyncIterator()
    #expect(await updates.nextUpdate() == messageChunk("early-1"))
    #expect(await updates.nextUpdate() == messageChunk("early-2"))
    #expect(await updates.nextUpdate() == messageChunk("live"))
    #expect(!subscription.hasMissedUpdates)
    #expect(log.messages.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func routerDoesNotGiveBufferedUpdatesToASecondSubscriber() async {
    let (router, _) = makeRouter()
    router.deliver(notification(for: sessionOne, messageChunk("early")))

    let first = router.subscribe(to: sessionOne)
    let second = router.subscribe(to: sessionOne)
    router.deliver(notification(for: sessionOne, messageChunk("live")))

    var secondUpdates = second.updates.makeAsyncIterator()
    #expect(await secondUpdates.nextUpdate() == messageChunk("live"))
    var firstUpdates = first.updates.makeAsyncIterator()
    #expect(await firstUpdates.nextUpdate() == messageChunk("early"))
    #expect(await firstUpdates.nextUpdate() == messageChunk("live"))
}

@Test(.timeLimit(.minutes(1)))
func routerDiscardsAFullSessionBufferMarksTheSessionAndLogsAWarning() async {
    let (router, log) = makeRouter(limits: oneUpdateLimits)
    router.deliver(notification(for: sessionOne, messageChunk("kept")))
    router.deliver(notification(for: sessionOne, messageChunk("too-many")))

    let subscription = router.subscribe(to: sessionOne)
    router.deliver(notification(for: sessionOne, messageChunk("live")))

    var updates = subscription.updates.makeAsyncIterator()
    #expect(await updates.nextUpdate() == messageChunk("live"))
    #expect(subscription.hasMissedUpdates)
    #expect(log.messages.count == 1)
    #expect(log.messages.first?.contains(sessionOne.rawValue) == true)
}

@Test(.timeLimit(.minutes(1)))
func routerGivesTheOverflowMarkToTheFirstSubscriberOnly() {
    let (router, _) = makeRouter(limits: oneUpdateLimits)
    router.deliver(notification(for: sessionOne, messageChunk("kept")))
    router.deliver(notification(for: sessionOne, messageChunk("too-many")))

    let first = router.subscribe(to: sessionOne)
    let second = router.subscribe(to: sessionOne)

    #expect(first.hasMissedUpdates)
    #expect(!second.hasMissedUpdates)
}

@Test(.timeLimit(.minutes(1)))
func routerEvictsTheOldestBufferWhenOneSessionTooManyHasABuffer() async {
    let (router, log) = makeRouter()
    let sessionLimit = SessionUpdateBufferLimits.default.maximumSessions
    let sessions = (0...sessionLimit).map { SessionId(rawValue: "buffered-\($0)") }
    for session in sessions {
        router.deliver(notification(for: session, messageChunk(session.rawValue)))
    }

    let oldest = router.subscribe(to: sessions[0])
    router.deliver(notification(for: sessions[0], messageChunk("live")))
    var oldestUpdates = oldest.updates.makeAsyncIterator()
    #expect(await oldestUpdates.nextUpdate() == messageChunk("live"))
    #expect(oldest.hasMissedUpdates)

    let secondOldest = router.subscribe(to: sessions[1])
    var secondOldestUpdates = secondOldest.updates.makeAsyncIterator()
    #expect(await secondOldestUpdates.nextUpdate() == messageChunk(sessions[1].rawValue))
    #expect(!secondOldest.hasMissedUpdates)

    let newest = router.subscribe(to: sessions[sessionLimit])
    var newestUpdates = newest.updates.makeAsyncIterator()
    #expect(await newestUpdates.nextUpdate() == messageChunk(sessions[sessionLimit].rawValue))
    #expect(!newest.hasMissedUpdates)

    #expect(log.messages.count == 1)
    #expect(log.messages.first?.contains(sessions[0].rawValue) == true)
}

@Test(.timeLimit(.minutes(1)))
func routerDiscardsTheBufferAndTheMarkOfAClosedSession() async {
    let (router, _) = makeRouter(limits: oneUpdateLimits)
    router.deliver(notification(for: sessionOne, messageChunk("kept")))
    router.deliver(notification(for: sessionOne, messageChunk("too-many")))
    router.deliver(notification(for: sessionOne, messageChunk("after-overflow")))

    router.discardPendingUpdates(for: sessionOne)
    let subscription = router.subscribe(to: sessionOne)
    router.deliver(notification(for: sessionOne, messageChunk("live")))

    var updates = subscription.updates.makeAsyncIterator()
    #expect(await updates.nextUpdate() == messageChunk("live"))
    #expect(!subscription.hasMissedUpdates)
}

@Test(.timeLimit(.minutes(1)))
func routerDiscardsEveryBufferAndMarkWhenItFinishes() async {
    let (router, _) = makeRouter(limits: oneUpdateLimits)
    router.deliver(notification(for: sessionOne, messageChunk("kept")))
    router.deliver(notification(for: sessionOne, messageChunk("too-many")))
    router.deliver(notification(for: sessionOne, messageChunk("after-overflow")))

    router.finishAll()
    let subscription = router.subscribe(to: sessionOne)

    #expect(await drain(subscription).isEmpty)
    #expect(!subscription.hasMissedUpdates)
}

// MARK: - Connection buffer before the session/new response

@Test(.timeLimit(.minutes(1)))
func anUpdateSentBeforeTheNewSessionResponseReachesTheFirstSubscriber() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await ClientSideConnection(stream: clientEnd) { _ in MinimalClient() }
    let reader = WireReader(agentEnd)

    let session = try await createSession(
        on: client, reader: reader, agentEnd: agentEnd, sendingFirst: [messageChunk("before-response")]
    )
    let subscription = client.subscribe(to: session)
    try await send(sessionUpdateEnvelope(notification(for: session, messageChunk("after-subscribe"))), over: agentEnd)

    var updates = subscription.updates.makeAsyncIterator()
    #expect(await updates.nextUpdate() == messageChunk("before-response"))
    #expect(await updates.nextUpdate() == messageChunk("after-subscribe"))
    #expect(!subscription.hasMissedUpdates)

    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func bufferLimitsSetOnTheConnectionMarkAnOverflowBeforeTheNewSessionResponse() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let log = LogCapture()
    let client = await ClientSideConnection(
        stream: clientEnd, logger: log.logger, bufferLimits: oneUpdateLimits
    ) { _ in MinimalClient() }
    let reader = WireReader(agentEnd)

    let session = try await createSession(
        on: client, reader: reader, agentEnd: agentEnd, sendingFirst: [messageChunk("kept"), messageChunk("too-many")]
    )
    let subscription = client.subscribe(to: session)

    #expect(subscription.hasMissedUpdates)
    #expect(log.messages.count == 1)

    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func closingASessionDiscardsItsBufferAndItsMark() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await ClientSideConnection(stream: clientEnd, bufferLimits: oneUpdateLimits) { _ in MinimalClient() }
    let reader = WireReader(agentEnd)

    let session = try await createSession(
        on: client,
        reader: reader,
        agentEnd: agentEnd,
        sendingFirst: [messageChunk("kept"), messageChunk("too-many"), messageChunk("after-overflow")]
    )
    try await closeSessionOne(on: client, reader: reader, agentEnd: agentEnd)
    let subscription = client.subscribe(to: session)
    try await send(sessionUpdateEnvelope(notification(for: session, messageChunk("live"))), over: agentEnd)

    var updates = subscription.updates.makeAsyncIterator()
    #expect(await updates.nextUpdate() == messageChunk("live"))
    #expect(!subscription.hasMissedUpdates)

    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func closingTheConnectionDiscardsEveryBufferAndMark() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await ClientSideConnection(stream: clientEnd, bufferLimits: oneUpdateLimits) { _ in MinimalClient() }
    let reader = WireReader(agentEnd)

    let session = try await createSession(
        on: client,
        reader: reader,
        agentEnd: agentEnd,
        sendingFirst: [messageChunk("kept"), messageChunk("too-many"), messageChunk("after-overflow")]
    )
    await client.close()
    let subscription = client.subscribe(to: session)

    #expect(await drain(subscription).isEmpty)
    #expect(!subscription.hasMissedUpdates)
}

// MARK: - Request-finished markers

/// The wire method of `session/resume`, from the routing table.
private let resumeWireMethod = RoleRouting.wireMethod(for: "resumeSession", on: .agent)

/// The wire method of `session/prompt`, from the routing table.
private let promptWireMethod = RoleRouting.wireMethod(for: "prompt", on: .agent)

/// The timeout, in milliseconds, of the request in the timeout test.
private let shortRequestTimeoutMilliseconds = 50

/// The timeout of the request in the timeout test. The raw agent end never
/// answers that request.
private let shortRequestTimeout: Duration = .milliseconds(shortRequestTimeoutMilliseconds)

/// Frames a JSON-RPC error response keyed to a request id.
///
/// - Parameters:
///   - id: The request's wire id, echoed on the response.
///   - error: The error to send.
/// - Returns: The response envelope ready to write over a transport.
private func errorEnvelope(id: JSONValue, error: RequestError) -> JSONValue {
    .object([
        "jsonrpc": .string("2.0"),
        "id": id,
        "error": error.wireValue,
    ])
}

/// Starts `session/resume` of `sessionOne` and returns its wire id, so a test
/// can script the replay and the response by hand.
///
/// - Parameters:
///   - client: The connection that sends `session/resume`.
///   - reader: The raw agent-end reader that observes the outbound request.
/// - Returns: The resume task, and the request's wire id.
/// - Throws: Rethrows any transport read failure.
private func startResume(
    on client: ClientSideConnection,
    reader: WireReader
) async throws -> (task: Task<ResumeSessionResponse, any Error>, id: JSONValue) {
    let task = Task {
        try await client.resumeSession(ResumeSessionRequest(cwd: AbsolutePath(rawValue: "/work"), sessionId: sessionOne))
    }
    let id = try #require(requestID(of: try await reader.next()))
    return (task, id)
}

/// The marker of one failed `session/prompt` request.
///
/// - Parameter id: The wire id of the request.
/// - Returns: The marker event.
private func failedPromptMarker(id: JSONValue) -> SessionStreamEvent {
    .requestFinished(id: id, method: promptWireMethod, outcome: .failed)
}

@Test(.timeLimit(.minutes(1)))
func theResumeMarkerComesAfterEveryEarlierUpdateAndBeforeEveryLaterUpdate() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await ClientSideConnection(stream: clientEnd) { _ in MinimalClient() }
    let reader = WireReader(agentEnd)

    var events = client.subscribe(to: sessionOne).updates.makeAsyncIterator()
    let (resume, id) = try await startResume(on: client, reader: reader)
    try await send(sessionUpdateEnvelope(notification(for: sessionOne, messageChunk("replay-1"))), over: agentEnd)
    try await send(sessionUpdateEnvelope(notification(for: sessionOne, messageChunk("replay-2"))), over: agentEnd)
    try await send(responseEnvelope(id: id, result: ResumeSessionResponse()), over: agentEnd)
    _ = try await resume.value
    try await send(sessionUpdateEnvelope(notification(for: sessionOne, messageChunk("live"))), over: agentEnd)

    #expect(await events.next() == .update(messageChunk("replay-1")))
    #expect(await events.next() == .update(messageChunk("replay-2")))
    #expect(await events.next() == .requestFinished(id: id, method: resumeWireMethod, outcome: .succeeded))
    #expect(await events.next() == .update(messageChunk("live")))

    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func anErrorResponseYieldsAFailedMarker() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await ClientSideConnection(stream: clientEnd) { _ in MinimalClient() }
    let reader = WireReader(agentEnd)

    var events = client.subscribe(to: sessionOne).updates.makeAsyncIterator()
    let (prompt, id) = try await startPrompt(on: client, session: sessionOne, reader: reader)
    try await send(errorEnvelope(id: id, error: .invalidParams), over: agentEnd)

    await #expect(throws: RequestError.invalidParams) { try await prompt.value }
    #expect(await events.next() == failedPromptMarker(id: id))

    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func aTimedOutRequestYieldsAFailedMarker() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await ClientSideConnection(stream: clientEnd, requestTimeout: shortRequestTimeout) { _ in
        MinimalClient()
    }
    let reader = WireReader(agentEnd)

    var events = client.subscribe(to: sessionOne).updates.makeAsyncIterator()
    let (prompt, id) = try await startPrompt(on: client, session: sessionOne, reader: reader)

    await #expect(throws: ConnectionError.timedOut) { try await prompt.value }
    #expect(await events.next() == failedPromptMarker(id: id))

    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func aCancelledRequestYieldsAFailedMarker() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await ClientSideConnection(stream: clientEnd) { _ in MinimalClient() }
    let reader = WireReader(agentEnd)

    var events = client.subscribe(to: sessionOne).updates.makeAsyncIterator()
    let (prompt, id) = try await startPrompt(on: client, session: sessionOne, reader: reader)
    prompt.cancel()

    await #expect(throws: CancellationError.self) { try await prompt.value }
    #expect(await events.next() == failedPromptMarker(id: id))

    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func connectionCloseYieldsAFailedMarkerBeforeTheStreamFinishes() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await ClientSideConnection(stream: clientEnd) { _ in MinimalClient() }
    let reader = WireReader(agentEnd)

    var events = client.subscribe(to: sessionOne).updates.makeAsyncIterator()
    let (prompt, id) = try await startPrompt(on: client, session: sessionOne, reader: reader)
    await client.close()

    await #expect(throws: ConnectionError.closed) { try await prompt.value }
    #expect(await events.next() == failedPromptMarker(id: id))
    #expect(await events.next() == nil)
}

@Test(.timeLimit(.minutes(1)))
func aRequestWithoutASessionIdYieldsNoMarker() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await ClientSideConnection(stream: clientEnd) { _ in MinimalClient() }
    let reader = WireReader(agentEnd)

    var events = client.subscribe(to: sessionOne).updates.makeAsyncIterator()
    let initialize = Task {
        try await client.initialize(
            InitializeRequest(info: Implementation(name: "marker-client", version: "0.0.0"), protocolVersion: .v2)
        )
    }
    let id = try #require(requestID(of: try await reader.next()))
    let response = InitializeResponse(
        info: Implementation(name: "marker-agent", version: "0.0.0"),
        protocolVersion: .v2,
        capabilities: AgentCapabilities(session: SessionCapabilities())
    )
    try await send(responseEnvelope(id: id, result: response), over: agentEnd)
    _ = try await initialize.value
    try await send(sessionUpdateEnvelope(notification(for: sessionOne, messageChunk("after-initialize"))), over: agentEnd)

    #expect(await events.next() == .update(messageChunk("after-initialize")))

    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func keptUpdatesAndAMarkerReachTheFirstSubscriberInOrder() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await ClientSideConnection(stream: clientEnd) { _ in MinimalClient() }
    let reader = WireReader(agentEnd)

    let (resume, id) = try await startResume(on: client, reader: reader)
    try await send(sessionUpdateEnvelope(notification(for: sessionOne, messageChunk("kept"))), over: agentEnd)
    try await send(responseEnvelope(id: id, result: ResumeSessionResponse()), over: agentEnd)
    _ = try await resume.value
    let subscription = client.subscribe(to: sessionOne)
    try await send(sessionUpdateEnvelope(notification(for: sessionOne, messageChunk("live"))), over: agentEnd)

    var events = subscription.updates.makeAsyncIterator()
    #expect(await events.next() == .update(messageChunk("kept")))
    #expect(await events.next() == .requestFinished(id: id, method: resumeWireMethod, outcome: .succeeded))
    #expect(await events.next() == .update(messageChunk("live")))
    #expect(!subscription.hasMissedUpdates)

    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func routerCountsAKeptMarkerTowardTheSessionLimit() {
    let (router, log) = makeRouter(limits: oneUpdateLimits)
    router.deliver(notification(for: sessionOne, messageChunk("kept")))
    router.deliver(
        FinishedSessionRequest(id: .number(1), method: promptWireMethod, sessionId: sessionOne, outcome: .succeeded)
    )

    let subscription = router.subscribe(to: sessionOne)

    #expect(subscription.hasMissedUpdates)
    #expect(log.messages.count == 1)
}
