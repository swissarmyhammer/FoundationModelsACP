import Foundation
import Testing

@testable import FoundationModelsACP

// MARK: - Back-to-back full duplex

/// The number of times the full-duplex scenario is repeated to prove it is
/// free of timing flakiness (spec §8).
private let fullDuplexRepeatCount = 100

/// Drives a real client and a scripted wire agent back-to-back through an
/// in-memory transport: the full initialize handshake, `session/new`, and a
/// `session/prompt` turn whose scripted "tool" issues reverse
/// `fs/read_text_file` and `session/request_permission` calls mid-turn,
/// ending in a ``StopReason``.
///
/// This confirms the full bidirectional surface end-to-end: the turn's reverse
/// requests go out through the serving ``AgentSideConnection`` and land on the
/// real served client over the wire, while the `session/prompt` request is
/// still open. The scenario is fully awaited at every step — no sleeps, no
/// races — so repeating it proves determinism.
///
/// - Parameter sessionId: The session the scenario runs against.
private func runFullDuplexTurn(sessionId: SessionId) async throws {
    let recorder = RoleRecorder()
    let pair = await makeEndToEndPair(
        sessionId: sessionId,
        client: { _ in SpyClient(recorder: recorder) }
    )
    pair.agent.enqueueTurn(reverseCallScriptedTurn())

    let initialized = try await pair.client.initialize(endToEndInitializeRequest())
    #expect(initialized.agentCapabilities.promptCapabilities.embeddedContext)
    let created = try await pair.client.newSession(newSessionRequest())
    #expect(created.sessionId == sessionId)

    var updates = pair.client.updates(for: sessionId).makeAsyncIterator()
    let response = try await pair.client.prompt(endToEndPromptRequest(text: "hello", sessionId: sessionId))

    #expect(response.stopReason == .endTurn)
    #expect(recorder.recorded("readTextFile") != nil)
    #expect(recorder.recorded("requestPermission") != nil)
    #expect(await updates.next() == messageChunkUpdate("working"))
    #expect(await updates.next() == toolCallCompletedUpdate(id: "call-1", text: "done"))

    await pair.client.close()
    await pair.agentConnection.close()
}

/// A scripted turn that emits a message chunk, drives two reverse client calls
/// through the serving connection, then completes a tool call.
///
/// - Returns: The scripted turn.
private func reverseCallScriptedTurn() -> ScriptedTurn {
    { context in
        try await context.update(messageChunkUpdate("working"))
        _ = try await context.connection.readTextFile(
            ReadTextFileRequest(path: AbsolutePath(rawValue: "/tmp/input.txt")!, sessionId: context.sessionId)
        )
        _ = try await context.connection.requestPermission(
            RequestPermissionRequest(
                options: [allowOnceOption(optionId: "allow")],
                sessionId: context.sessionId,
                toolCall: ToolCallUpdate(toolCallId: ToolCallId(rawValue: "call-1"), status: .pending)
            )
        )
        try await context.update(toolCallCompletedUpdate(id: "call-1", text: "done"))
        return .endTurn
    }
}

/// The completed `tool_call_update` the scripted turn emits for a tool output,
/// for asserting the turn's second update.
///
/// - Parameters:
///   - id: The answered tool call's id.
///   - text: The output text.
/// - Returns: The completed tool-call-update.
private func toolCallCompletedUpdate(id: String, text: String) -> SessionUpdate {
    .toolCallUpdate(
        ToolCallUpdate(
            toolCallId: ToolCallId(rawValue: id),
            content: [.content(Content(content: .text(TextContent(text: text))))],
            status: .completed
        )
    )
}

@Test("back-to-back handshake, prompt, and mid-turn reverse calls run deterministically", .timeLimit(.minutes(5)))
func backToBackFullDuplexIsDeterministic() async throws {
    for iteration in 0..<fullDuplexRepeatCount {
        try await runFullDuplexTurn(sessionId: SessionId(rawValue: "e2e-session-\(iteration)"))
    }
}

// MARK: - Cancel during an open prompt

@Test("a cancel during an open prompt turn yields cancelled over the wire", .timeLimit(.minutes(1)))
func cancelDuringOpenPromptYieldsCancelled() async throws {
    let sessionId = SessionId(rawValue: "e2e-cancel")
    let pair = await makeEndToEndPair(
        sessionId: sessionId,
        client: { _ in MinimalClient() }
    )
    let progress = TurnRecorder()
    pair.agent.enqueueTurn { context in
        try await context.update(thoughtChunkUpdate("thinking"))
        await progress.record("delivered")
        while !Task.isCancelled {
            await Task.yield()
        }
        try await context.update(messageChunkUpdate("stopped"))
        return .endTurn
    }

    _ = try await pair.client.initialize(endToEndInitializeRequest())
    _ = try await pair.client.newSession(newSessionRequest())
    var updates = pair.client.updates(for: sessionId).makeAsyncIterator()

    let turn = Task {
        try await pair.client.prompt(endToEndPromptRequest(text: "go", sessionId: sessionId))
    }
    #expect(await updates.next() == thoughtChunkUpdate("thinking"))
    await waitUntil(progress, records: "delivered")
    try await pair.client.cancel(CancelNotification(sessionId: sessionId))

    let response = try await turn.value
    #expect(response.stopReason == .cancelled)
    #expect(await updates.next() == messageChunkUpdate("stopped"))

    await pair.client.close()
    await pair.agentConnection.close()
}

// MARK: - Late straggler after the response

@Test("a session/update after the prompt response still reaches the client", .timeLimit(.minutes(1)))
func lateUpdateAfterResponseReachesClient() async throws {
    let sessionId = SessionId(rawValue: "e2e-straggler")
    let pair = await makeEndToEndPair(
        sessionId: sessionId,
        client: { _ in MinimalClient() }
    )

    _ = try await pair.client.initialize(endToEndInitializeRequest())
    _ = try await pair.client.newSession(newSessionRequest())
    var updates = pair.client.updates(for: sessionId).makeAsyncIterator()
    let response = try await pair.client.prompt(endToEndPromptRequest(text: "hi", sessionId: sessionId))
    #expect(response.stopReason == .endTurn)

    let straggler = SessionUpdate.toolCallUpdate(
        ToolCallUpdate(toolCallId: ToolCallId(rawValue: "late-call"), status: .completed)
    )
    try await pair.agentConnection.sessionUpdate(
        SessionNotification(sessionId: sessionId, update: straggler)
    )
    #expect(await updates.next() == straggler)

    await pair.client.close()
    await pair.agentConnection.close()
}
