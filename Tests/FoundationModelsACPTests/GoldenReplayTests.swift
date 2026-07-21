import Foundation
import Testing

@testable import FoundationModelsACP

// MARK: - Golden session replay

/// Replays a recorded client→agent session and asserts the agent's emitted
/// byte stream matches the committed golden fixture, frame for frame (spec §8).
///
/// The turn is scripted so the capture is deterministic with no live model: a
/// reasoning chunk, a message chunk, a tool call, and its completing update,
/// then the `session/prompt` response. Framing, ordering, tool-call pairing,
/// and the ``StopReason`` are all pinned by the golden bytes; a drift fails
/// loudly with the first differing line.
@Test("a recorded session replays to the golden agent byte stream", .timeLimit(.minutes(1)))
func goldenSessionReplayMatchesFixture() async throws {
    let sessionId = SessionId(rawValue: "golden-session")
    let updates: [SessionUpdate] = [
        thoughtChunkUpdate("planning the reply"),
        messageChunkUpdate("Hello from the agent."),
        .toolCall(
            ToolCall(
                title: "reader",
                toolCallId: ToolCallId(rawValue: "call-1"),
                rawInput: .object(["path": .string("/tmp/notes.txt")]),
                status: .pending
            )
        ),
        .toolCallUpdate(
            ToolCallUpdate(
                toolCallId: ToolCallId(rawValue: "call-1"),
                content: [.content(Content(content: .text(TextContent(text: "file body"))))],
                status: .completed
            )
        ),
    ]

    let (driver, connection) = await makeGoldenDriver(sessionId: sessionId) { context in
        for update in updates {
            try await context.update(update)
        }
        return .endTurn
    }

    let initFrames = try await driver.request(
        id: "req-init",
        method: "initialize",
        params: endToEndInitializeRequest()
    )
    let newFrames = try await driver.request(
        id: "req-new",
        method: "session/new",
        params: newSessionRequest()
    )
    let promptFrames = try await driver.request(
        id: "req-prompt",
        method: "session/prompt",
        params: endToEndPromptRequest(text: "hello", sessionId: sessionId)
    )

    #expect(initFrames.count == 1)
    #expect(isResponse(initFrames[0], forId: .string("req-init")))
    #expect(newFrames.count == 1)
    #expect(isResponse(newFrames[0], forId: .string("req-new")))
    #expect(promptFrames.count == 5)
    #expect(promptFrames.prefix(4).allSatisfy { method(of: $0) == "session/update" })
    #expect(isResponse(promptFrames[4], forId: .string("req-prompt")))
    #expect(result(of: promptFrames[4]) == .object(["stopReason": .string("end_turn")]))

    try expectGolden(driver.scriptBytes, matchesFixture: "golden-session-script.ndjson")
    try expectGolden(driver.agentBytes, matchesFixture: "golden-session-agent.ndjson")

    await connection.close()
}

// MARK: - Adversarial wire input

/// Drives an adversarial client→agent stream and asserts the agent tolerates
/// every hazard the wire can throw at it (spec §8): a garbage line is skipped,
/// interleaved concurrent requests each correlate to their id, a cancel
/// mid-turn yields ``StopReason/cancelled``, and a `tool_call_update` emitted
/// after the prompt response is still delivered.
@Test("the agent tolerates garbage, interleaving, cancel, and stragglers", .timeLimit(.minutes(1)))
func adversarialWireInputIsTolerated() async throws {
    let sessionId = SessionId(rawValue: "adversarial-session")
    let (driver, connection) = await makeGoldenDriver(sessionId: sessionId) { context in
        try await context.update(thoughtChunkUpdate("thinking"))
        while !Task.isCancelled {
            await Task.yield()
        }
        try await context.update(messageChunkUpdate("stopped"))
        return .endTurn
    }

    // A garbage line is skipped by the codec and produces no frame.
    try await driver.sendRaw("this is not a json-rpc envelope")

    // Interleaved concurrent requests: sent back-to-back, each response
    // correlates to its own id regardless of completion order.
    try await driver.send(requestEnvelope(id: "req-init", method: "initialize", params: endToEndInitializeRequest()))
    try await driver.send(requestEnvelope(id: "req-new", method: "session/new", params: newSessionRequest()))
    let handshake = try await driver.collectResponses(ids: ["req-init", "req-new"])
    #expect(handshake["req-init"].map { isResponse($0, forId: .string("req-init")) } == true)
    #expect(handshake["req-new"].map { isResponse($0, forId: .string("req-new")) } == true)

    // A cancel mid-turn: the prompt is opened, its first update observed to
    // prove the turn is running, then cancelled — the response is cancelled.
    try await driver.send(
        requestEnvelope(
            id: "req-prompt",
            method: "session/prompt",
            params: endToEndPromptRequest(text: "go", sessionId: sessionId)
        )
    )
    let firstUpdate = try await driver.nextFrame()
    #expect(method(of: firstUpdate ?? .null) == "session/update")
    try await driver.send(
        notificationEnvelope(method: "session/cancel", params: CancelNotification(sessionId: sessionId))
    )
    let promptFrames = try await driver.collectThroughResponse(id: "req-prompt")
    let promptResponse = try #require(promptFrames.last)
    #expect(result(of: promptResponse) == .object(["stopReason": .string("cancelled")]))

    // A straggler emitted after the prompt response is still delivered.
    let straggler = SessionUpdate.toolCallUpdate(
        ToolCallUpdate(toolCallId: ToolCallId(rawValue: "late-call"), status: .completed)
    )
    try await connection.sessionUpdate(SessionNotification(sessionId: sessionId, update: straggler))
    let stragglerFrame = try await driver.nextFrame()
    #expect(method(of: stragglerFrame ?? .null) == "session/update")

    await connection.close()
}
