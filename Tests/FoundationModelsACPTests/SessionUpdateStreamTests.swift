import Foundation
import Testing

import FoundationModelsACP

// MARK: - Fixtures

/// A first interleaved session id.
private let sessionOne = SessionId(rawValue: "session-stream-1")

/// A second interleaved session id.
private let sessionTwo = SessionId(rawValue: "session-stream-2")

/// Builds a `session/update` notification model for one session.
///
/// - Parameters:
///   - session: The session the update pertains to.
///   - update: The update payload to carry.
/// - Returns: The assembled notification.
private func notification(
    for session: SessionId,
    _ update: SessionUpdate
) -> SessionNotification {
    SessionNotification(sessionId: session, update: update)
}

/// An agent-message-chunk update carrying one text fragment.
///
/// - Parameter text: The chunk's text.
/// - Returns: The update payload.
private func messageChunk(_ text: String) -> SessionUpdate {
    .agentMessageChunk(ContentChunk(content: .text(TextContent(text: text))))
}

/// A tool-call-update straggler naming one tool call.
///
/// - Parameter id: The tool call's identifier.
/// - Returns: The update payload.
private func toolCallUpdate(_ id: String) -> SessionUpdate {
    .toolCallUpdate(ToolCallUpdate(toolCallId: ToolCallId(rawValue: id)))
}

/// Frames a `session/update` notification as a JSON-RPC envelope for the wire.
///
/// - Parameter notification: The notification to send.
/// - Returns: The envelope value ready to write over a transport.
/// - Throws: Rethrows any encoding failure.
private func sessionUpdateEnvelope(_ notification: SessionNotification) throws -> JSONValue {
    .object([
        "jsonrpc": .string("2.0"),
        "method": .string("session/update"),
        "params": try encodedValue(notification),
    ])
}

/// Frames a prompt response keyed to a request id.
///
/// - Parameters:
///   - id: The prompt request's wire id, echoed on the response.
///   - stopReason: The turn's stop reason.
/// - Returns: The response envelope ready to write over a transport.
/// - Throws: Rethrows any encoding failure.
private func promptResponseEnvelope(id: JSONValue, stopReason: StopReason) throws -> JSONValue {
    .object([
        "jsonrpc": .string("2.0"),
        "id": id,
        "result": try encodedValue(PromptResponse(stopReason: stopReason)),
    ])
}

/// Drives a prompt request over the client and returns its wire id, so a test
/// can script the agent's trailing updates and response by hand.
///
/// - Parameters:
///   - client: The connection to prompt.
///   - session: The session to prompt in.
///   - reader: The raw agent-end reader that observes the outbound request.
/// - Returns: The prompt task awaiting the turn, and the request's wire id.
/// - Throws: Rethrows any transport read failure.
private func startPrompt(
    on client: ClientSideConnection,
    session: SessionId,
    reader: WireReader
) async throws -> (task: Task<PromptResponse, any Error>, id: JSONValue) {
    let task = Task { try await client.prompt(PromptRequest(prompt: [.text(TextContent(text: "go"))], sessionId: session)) }
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

// MARK: - Straggler after the prompt response

@Test(.timeLimit(.minutes(1)))
func lateToolCallUpdateAfterPromptResponseIsDelivered() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await ClientSideConnection(stream: clientEnd) { _ in MinimalClient() }
    let reader = WireReader(agentEnd)

    var updates = client.updates(for: sessionOne).makeAsyncIterator()
    let (prompt, id) = try await startPrompt(on: client, session: sessionOne, reader: reader)

    // An in-turn update, then the response that ends the turn.
    try await send(sessionUpdateEnvelope(notification(for: sessionOne, messageChunk("mid-turn"))), over: agentEnd)
    try await send(promptResponseEnvelope(id: id, stopReason: .endTurn), over: agentEnd)
    #expect(try await prompt.value.stopReason == .endTurn)

    // A tool_call_update straggler that arrives AFTER the turn ended is still
    // delivered on the session's stream.
    try await send(sessionUpdateEnvelope(notification(for: sessionOne, toolCallUpdate("call-late"))), over: agentEnd)

    #expect(await updates.next() == messageChunk("mid-turn"))
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

    // The client cancels; cancel is a notification, so the turn is still open.
    try await client.cancel(CancelNotification(sessionId: sessionOne))

    // Trailing updates land after the cancel, then the prompt response confirms
    // the cancellation with StopReason.cancelled.
    try await send(sessionUpdateEnvelope(notification(for: sessionOne, toolCallUpdate("call-trailing"))), over: agentEnd)
    try await send(sessionUpdateEnvelope(notification(for: sessionOne, messageChunk("winding down"))), over: agentEnd)
    try await send(promptResponseEnvelope(id: id, stopReason: .cancelled), over: agentEnd)

    #expect(try await prompt.value.stopReason == .cancelled)

    // The trailing updates are observed on the stream, in wire order.
    #expect(await updates.next() == toolCallUpdate("call-trailing"))
    #expect(await updates.next() == messageChunk("winding down"))

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
