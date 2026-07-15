import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsACP

// MARK: - Back-to-back full duplex

/// The number of times the full-duplex scenario is repeated to prove it is
/// free of timing flakiness (spec §8).
private let fullDuplexRepeatCount = 100

/// Drives a real client and the bridge agent back-to-back through an in-memory
/// transport: the full initialize handshake, `session/new`, and a
/// `session/prompt` turn whose scripted "tool" reaches `ClientEnvironment.current`
/// to issue reverse `fs/read_text_file` and `session/request_permission` calls
/// mid-turn, ending in a ``StopReason``.
///
/// This confirms the ambient ``ClientEnvironment/current`` injection end-to-end:
/// code the turn generator runs reaches the handle bound for the turn and its
/// reverse requests land on the real served client over the wire, while the
/// `session/prompt` request is still open. The scenario is fully awaited at
/// every step — no sleeps, no races — so repeating it proves determinism.
///
/// - Parameter sessionId: The session the scenario runs against.
private func runFullDuplexTurn(sessionId: SessionId) async throws {
    let recording = RecordingEnvironmentClient(
        configuration: RecordingEnvironmentClient.Configuration(
            fileContent: "file body",
            permissionOutcome: grantedPermissionOutcome(optionId: "allow")
        )
    )
    let pair = await makeEndToEndPair(
        provider: singleSessionProvider(sessionId: sessionId),
        client: { _ in recording }
    )
    pair.agent.enqueueScriptedTurn(for: sessionId, reverseCallScriptedTurn())

    let initialized = try await pair.client.initialize(endToEndInitializeRequest())
    #expect(initialized.agentCapabilities.promptCapabilities.embeddedContext)
    let created = try await pair.client.newSession(bridgeNewSessionRequest())
    #expect(created.sessionId == sessionId)

    var updates = pair.client.updates(for: sessionId).makeAsyncIterator()
    let response = try await pair.client.prompt(endToEndPromptRequest(text: "hello", sessionId: sessionId))

    #expect(response.stopReason == .endTurn)
    #expect(recording.recordedCalls.contains("readTextFile"))
    #expect(recording.recordedCalls.contains("requestPermission"))
    #expect(await updates.next() == messageChunkUpdate("working"))
    #expect(await updates.next() == toolCallCompletedUpdate(id: "call-1", text: "done"))

    await pair.client.close()
    await pair.agentConnection.close()
}

/// A scripted turn that emits a message chunk, drives two reverse client calls
/// through the ambient environment, then completes a tool call.
///
/// - Returns: The scripted turn generator.
private func reverseCallScriptedTurn() -> TurnGenerator {
    { deliver in
        await deliver([responseEntry("working")])
        let environment = ClientEnvironment.current!
        _ = try await environment.readTextFile(path: AbsolutePath(rawValue: "/tmp/input.txt")!)
        _ = try await environment.requestPermission(
            toolCall: ToolCallUpdate(toolCallId: ToolCallId(rawValue: "call-1"), status: .pending),
            options: [allowOnceOption(optionId: "allow")]
        )
        let entries = [responseEntry("working"), toolOutputEntry(id: "call-1", name: "reader", text: "done")]
        await deliver(entries)
        return Transcript(entries: entries)
    }
}

/// The completed `tool_call_update` the mapper emits for a tool output, for
/// asserting the turn's second update.
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
        provider: singleSessionProvider(sessionId: sessionId),
        client: { _ in RecordingEnvironmentClient() }
    )
    let progress = TurnRecorder()
    pair.agent.enqueueScriptedTurn(for: sessionId) { deliver in
        await deliver([reasoningEntry("thinking")])
        await progress.record("delivered")
        while !Task.isCancelled {
            await Task.yield()
        }
        let entries = [reasoningEntry("thinking"), responseEntry("stopped")]
        await deliver(entries)
        return Transcript(entries: entries)
    }

    _ = try await pair.client.initialize(endToEndInitializeRequest())
    _ = try await pair.client.newSession(bridgeNewSessionRequest())
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
        provider: singleSessionProvider(sessionId: sessionId),
        client: { _ in RecordingEnvironmentClient() }
    )
    pair.agent.enqueueScriptedTurn(for: sessionId) { _ in Transcript(entries: []) }

    _ = try await pair.client.initialize(endToEndInitializeRequest())
    _ = try await pair.client.newSession(bridgeNewSessionRequest())
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
