import Foundation
import Testing

@testable import FoundationModelsACP

// MARK: - Fixtures

/// A first interleaved session id.
private let sessionOne = SessionId(rawValue: "session-stream-1")

/// A second interleaved session id.
private let sessionTwo = SessionId(rawValue: "session-stream-2")

/// A client whose handlers all ignore or refuse what they serve — tests
/// observe delivery through `ClientSideConnection.updates(for:)` instead.
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
    .object([
        "jsonrpc": .string("2.0"),
        "method": .string("session/update"),
        "params": try JSONValue.encode(result: notification),
    ])
}

/// Frames a `session/prompt` acknowledgement keyed to a request id.
///
/// - Parameter id: The prompt request's wire id, echoed on the response.
/// - Returns: The response envelope ready to write over a transport.
/// - Throws: Rethrows any encoding failure.
private func promptAckEnvelope(id: JSONValue) throws -> JSONValue {
    .object([
        "jsonrpc": .string("2.0"),
        "id": id,
        "result": try JSONValue.encode(result: PromptResponse()),
    ])
}

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

    var firstUpdates = client.updates(for: sessionOne).makeAsyncIterator()
    var secondUpdates = client.updates(for: sessionTwo).makeAsyncIterator()

    try await send(sessionUpdateEnvelope(notification(for: sessionOne, messageChunk("a1"))), over: agentEnd)
    try await send(sessionUpdateEnvelope(notification(for: sessionTwo, messageChunk("b1"))), over: agentEnd)
    try await send(sessionUpdateEnvelope(notification(for: sessionOne, messageChunk("a2"))), over: agentEnd)

    let firstA = await firstUpdates.next()
    let firstB = await firstUpdates.next()
    let secondA = await secondUpdates.next()

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

    var updates = client.updates(for: sessionOne).makeAsyncIterator()
    let (prompt, id) = try await startPrompt(on: client, session: sessionOne, reader: reader)

    // v2's prompt acknowledges immediately — the turn's actual progress and
    // completion arrive as `state_update` notifications, not as this response.
    try await send(promptAckEnvelope(id: id), over: agentEnd)
    #expect(try await prompt.value == PromptResponse())

    try await send(sessionUpdateEnvelope(notification(for: sessionOne, messageChunk("mid-turn"))), over: agentEnd)
    try await send(sessionUpdateEnvelope(notification(for: sessionOne, idleState(stopReason: .endTurn))), over: agentEnd)

    // A tool_call_update straggler that arrives AFTER the idle state_update is
    // still delivered on the session's stream.
    try await send(sessionUpdateEnvelope(notification(for: sessionOne, toolCallUpdate("call-late"))), over: agentEnd)

    #expect(await updates.next() == messageChunk("mid-turn"))
    #expect(await updates.next() == idleState(stopReason: .endTurn))
    #expect(await updates.next() == toolCallUpdate("call-late"))

    await client.close()
}

// MARK: - Post-cancel stragglers then the cancelled stop reason

@Test(.timeLimit(.minutes(1)))
func postCancelTrailingUpdatesThenCancelledStopReasonInOrder() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await ClientSideConnection(stream: clientEnd) { _ in MinimalClient() }
    let reader = WireReader(agentEnd)

    var updates = client.updates(for: sessionOne).makeAsyncIterator()
    let (prompt, id) = try await startPrompt(on: client, session: sessionOne, reader: reader)
    try await send(promptAckEnvelope(id: id), over: agentEnd)
    #expect(try await prompt.value == PromptResponse())

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
    #expect(await updates.next() == toolCallUpdate("call-trailing"))
    #expect(await updates.next() == messageChunk("winding down"))
    #expect(await updates.next() == idleState(stopReason: .cancelled))

    await client.close()
}

// MARK: - Straggler policy: no subscriber at all

@Test(.timeLimit(.minutes(1)))
func updateForASessionWithNoSubscriberIsDroppedWithoutError() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await ClientSideConnection(stream: clientEnd) { _ in MinimalClient() }

    // Nobody ever subscribes to sessionTwo. sessionOne's subscriber proves
    // the read loop kept working past the drop instead of wedging on it.
    var firstUpdates = client.updates(for: sessionOne).makeAsyncIterator()

    try await send(sessionUpdateEnvelope(notification(for: sessionTwo, messageChunk("nobody-listens"))), over: agentEnd)
    try await send(sessionUpdateEnvelope(notification(for: sessionOne, messageChunk("still-here"))), over: agentEnd)

    #expect(await firstUpdates.next() == messageChunk("still-here"))

    await client.close()
}

// MARK: - Stream finish on disconnect

@Test(.timeLimit(.minutes(1)))
func connectionEOFFinishesAllSessionStreams() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await ClientSideConnection(stream: clientEnd) { _ in MinimalClient() }

    let firstStream = client.updates(for: sessionOne)
    let secondStream = client.updates(for: sessionTwo)

    // Each collector drains its stream to completion, so it returns only once
    // the stream finishes.
    let firstCollector = Task { var count = 0; for await _ in firstStream { count += 1 }; return count }
    let secondCollector = Task { var count = 0; for await _ in secondStream { count += 1 }; return count }

    // One update reaches the first session, then the peer closes: EOF must
    // finish both streams so neither collector hangs past the buffered update.
    try await send(sessionUpdateEnvelope(notification(for: sessionOne, messageChunk("last"))), over: agentEnd)
    agentEnd.close()

    #expect(await firstCollector.value == 1)
    #expect(await secondCollector.value == 0)

    await client.close()
}
