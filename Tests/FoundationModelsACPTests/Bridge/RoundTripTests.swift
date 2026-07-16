import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsACP

// MARK: - Round-trip harness

/// Round-trips a scripted turn: projects it to updates with ``TranscriptMapper``
/// (the FM → ACP bridge), streams those updates through ``TranscriptBuilder``,
/// then re-projects the rebuilt transcript.
///
/// Two transcripts are turn-equivalent when they project to the same
/// `session/update` sequence — the sequence is exactly what AgentViewKit
/// renders — so comparing the original projection to the re-projection asserts
/// a lossless round trip.
///
/// - Parameter entries: The scripted turn's transcript entries.
/// - Returns: The original projection and the projection of the rebuilt
///   transcript, expected to be equal.
private func roundTrip(
    _ entries: [Transcript.Entry]
) async -> (projected: [SessionUpdate], reprojected: [SessionUpdate]) {
    var forward = TranscriptMapper()
    let updates = forward.consume(entries)

    let stream = AsyncStream<SessionUpdate> { continuation in
        for update in updates {
            continuation.yield(update)
        }
        continuation.finish()
    }
    let rebuilt = await TranscriptBuilder.transcript(folding: stream)

    var reforward = TranscriptMapper()
    return (updates, reforward.consume(rebuilt))
}

// MARK: - Golden turns

@Test(.timeLimit(.minutes(1)))
func goldenTurnRoundTripsLosslessly() async throws {
    let entries: [Transcript.Entry] = [
        reasoningEntry("Let me look this up"),
        try toolCallEntry(id: "call-1", name: "search", argumentsJSON: #"{"query":"swift"}"#),
        toolOutputEntry(id: "call-1", name: "search", text: "found it"),
        try toolCallEntry(id: "call-2", name: "read", argumentsJSON: #"{"path":"/tmp/x"}"#),
        toolOutputEntry(id: "call-2", name: "read", text: "contents"),
        responseEntry("Here is the answer"),
    ]

    let (projected, reprojected) = await roundTrip(entries)

    #expect(!projected.isEmpty)
    #expect(reprojected == projected)
}

@Test(.timeLimit(.minutes(1)))
func reasoningThenResponseRoundTripsLosslessly() async {
    let entries: [Transcript.Entry] = [
        reasoningEntry("thinking"),
        responseEntry("answer"),
    ]

    let (projected, reprojected) = await roundTrip(entries)

    #expect(reprojected == projected)
}

@Test(.timeLimit(.minutes(1)))
func planTurnRoundTripsLosslessly() async throws {
    let entries = [
        try planResponseEntry(
            #"{"entries":[{"content":"Investigate","priority":"high","status":"pending"}]}"#
        )
    ]

    let (projected, reprojected) = await roundTrip(entries)

    #expect(projected == [.plan(Plan(entries: [PlanEntry(content: "Investigate", priority: .high, status: .pending)]))])
    #expect(reprojected == projected)
}

// MARK: - Straggler policy

@Test(.timeLimit(.minutes(1)))
func lateToolOutputAfterFinalMessageRoundTripsLosslessly() async throws {
    // The tool output settles AFTER the turn's final message — the straggler
    // case — and must still fold back into its tool output, correlated by id.
    let entries: [Transcript.Entry] = [
        try toolCallEntry(id: "call-late", name: "search", argumentsJSON: "{}"),
        responseEntry("done"),
        toolOutputEntry(id: "call-late", name: "search", text: "trailing"),
    ]

    let (projected, reprojected) = await roundTrip(entries)

    #expect(reprojected == projected)
}

// MARK: - Tool-name recovery

@Test(.timeLimit(.minutes(1)))
func toolNameIsRecoveredThroughTheRoundTrip() async throws {
    // `tool_call_update` carries no tool name; the rebuilt tool output recovers
    // it from the correlated `tool_call`, so the round trip stays lossless.
    let entries: [Transcript.Entry] = [
        try toolCallEntry(id: "call-1", name: "search", argumentsJSON: "{}"),
        toolOutputEntry(id: "call-1", name: "search", text: "found it"),
    ]

    var forward = TranscriptMapper()
    let updates = forward.consume(entries)
    let stream = AsyncStream<SessionUpdate> { continuation in
        for update in updates {
            continuation.yield(update)
        }
        continuation.finish()
    }
    let rebuilt = await TranscriptBuilder.transcript(folding: stream)

    let output = Array(rebuilt).compactMap { entry -> Transcript.ToolOutput? in
        guard case .toolOutput(let output) = entry else {
            return nil
        }
        return output
    }.first
    #expect(output?.toolName == "search")
}

// MARK: - Multi-update tool calls (terminal-embed turns)

/// The in-progress `tool_call_update` `ClientEnvironment.runCommand` emits to
/// embed a live terminal in a tool call (spec §9); its only content is a
/// ``ToolCallContent/terminal(_:)``, which has no `Transcript.Segment` form.
///
/// - Parameters:
///   - toolCallId: The tool call the terminal is embedded into.
///   - terminalId: The live terminal to embed.
/// - Returns: The in-progress terminal-embed update.
private func terminalEmbedUpdate(toolCallId: ToolCallId, terminalId: TerminalId) -> SessionUpdate {
    .toolCallUpdate(
        ToolCallUpdate(
            toolCallId: toolCallId,
            content: [.terminal(Terminal(terminalId: terminalId))],
            status: .inProgress
        )
    )
}

@Test(.timeLimit(.minutes(1)))
func terminalEmbedTurnFoldsToOneToolOutput() throws {
    // The shipped command-tool composition emits, for one tool-call id, a
    // pending tool_call, then an in-progress tool_call_update embedding a live
    // terminal, then the completed tool_call_update carrying the output. The
    // terminal embed has no transcript segment, so folding must merge all three
    // into one tool output — not append a spurious empty entry.
    let toolCallId = ToolCallId(rawValue: "call-cmd")
    var builder = TranscriptBuilder()
    builder.fold(.toolCall(ToolCall(title: "run", toolCallId: toolCallId, rawInput: try jsonValue("{}"), status: .pending)))
    builder.fold(terminalEmbedUpdate(toolCallId: toolCallId, terminalId: TerminalId(rawValue: "term-1")))
    builder.fold(
        .toolCallUpdate(
            ToolCallUpdate(
                toolCallId: toolCallId,
                content: [.content(Content(content: .text(TextContent(text: "output"))))],
                status: .completed
            )
        )
    )

    let outputs = Array(builder.transcript).compactMap { entry -> Transcript.ToolOutput? in
        guard case .toolOutput(let output) = entry else {
            return nil
        }
        return output
    }
    #expect(outputs.count == 1)
    #expect(outputs.first?.id == "call-cmd")
    #expect(outputs.first?.toolName == "run")
    #expect(outputs.first?.segments.count == 1)
}

@Test(.timeLimit(.minutes(1)))
func terminalEmbedTurnRoundTripsLosslessly() async throws {
    // The canonical mapper projection of the equivalent turn — one tool call,
    // one tool output — is what TranscriptMapper alone produces.
    let entries: [Transcript.Entry] = [
        try toolCallEntry(id: "call-cmd", name: "run", argumentsJSON: "{}"),
        toolOutputEntry(id: "call-cmd", name: "run", text: "output"),
    ]
    var forward = TranscriptMapper()
    let canonical = forward.consume(entries)

    // The shipped bridge stream inserts the in-progress terminal embed between
    // the mapper's own pending and completed updates; folding then re-projecting
    // must reconstruct the canonical projection exactly.
    let composed = [
        canonical[0],
        terminalEmbedUpdate(toolCallId: ToolCallId(rawValue: "call-cmd"), terminalId: TerminalId(rawValue: "term-1")),
        canonical[1],
    ]
    let stream = AsyncStream<SessionUpdate> { continuation in
        for update in composed {
            continuation.yield(update)
        }
        continuation.finish()
    }
    let rebuilt = await TranscriptBuilder.transcript(folding: stream)

    var reforward = TranscriptMapper()
    #expect(reforward.consume(rebuilt) == canonical)
}
