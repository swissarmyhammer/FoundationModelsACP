import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsACP

// MARK: - Update builders

/// Builds a `tool_call` update naming a pending tool invocation.
///
/// - Parameters:
///   - id: The tool call's identifier.
///   - name: The tool's human-readable title.
///   - argumentsJSON: The call's raw input as a JSON string.
/// - Returns: The `tool_call` update.
/// - Throws: Rethrows any failure parsing `argumentsJSON`.
private func toolCallUpdate(id: String, name: String, argumentsJSON: String) throws -> SessionUpdate {
    .toolCall(
        ToolCall(
            title: name,
            toolCallId: ToolCallId(rawValue: id),
            rawInput: try jsonValue(argumentsJSON),
            status: .pending
        )
    )
}

/// Builds a completed `tool_call_update` carrying one text content block.
///
/// - Parameters:
///   - id: The answered tool call's identifier.
///   - text: The output text.
/// - Returns: The `tool_call_update` update.
private func toolOutputUpdate(id: String, text: String) -> SessionUpdate {
    .toolCallUpdate(
        ToolCallUpdate(
            toolCallId: ToolCallId(rawValue: id),
            content: [.content(Content(content: .text(TextContent(text: text))))],
            status: .completed
        )
    )
}

// MARK: - Entry inspection

/// Reads the text of every text segment in a segment list, in order.
///
/// - Parameter segments: The segments to read.
/// - Returns: Each text segment's content, skipping non-text segments.
private func texts(of segments: [Transcript.Segment]) -> [String] {
    segments.compactMap { segment in
        guard case .text(let text) = segment else {
            return nil
        }
        return text.content
    }
}

/// Folds updates into a fresh builder and returns the transcript's entries.
///
/// - Parameter updates: The updates to fold, in order.
/// - Returns: The folded transcript's entries.
private func fold(_ updates: [SessionUpdate]) -> [Transcript.Entry] {
    var builder = TranscriptBuilder()
    for update in updates {
        builder.fold(update)
    }
    return Array(builder.transcript)
}

// MARK: - Message and reasoning chunks

@Test("an agent message chunk folds into a response text entry")
func messageChunkFoldsIntoResponse() {
    let entries = fold([messageChunkUpdate("hello")])

    #expect(entries.count == 1)
    guard case .response(let response) = entries.first else {
        Issue.record("expected a response entry")
        return
    }
    #expect(texts(of: response.segments) == ["hello"])
}

@Test("consecutive message chunks accumulate into one response entry")
func consecutiveMessageChunksAccumulate() {
    let entries = fold([messageChunkUpdate("one "), messageChunkUpdate("two")])

    #expect(entries.count == 1)
    guard case .response(let response) = entries.first else {
        Issue.record("expected a single response entry")
        return
    }
    #expect(texts(of: response.segments) == ["one ", "two"])
}

@Test("an agent thought chunk folds into a reasoning entry")
func thoughtChunkFoldsIntoReasoning() {
    let entries = fold([thoughtChunkUpdate("let me think")])

    #expect(entries.count == 1)
    guard case .reasoning(let reasoning) = entries.first else {
        Issue.record("expected a reasoning entry")
        return
    }
    #expect(texts(of: reasoning.segments) == ["let me think"])
}

@Test("a role change flushes the open entry and starts a new one")
func roleChangeFlushesOpenEntry() {
    let entries = fold([thoughtChunkUpdate("thinking"), messageChunkUpdate("answer")])

    #expect(entries.count == 2)
    guard case .reasoning(let reasoning) = entries.first,
        case .response(let response) = entries.last
    else {
        Issue.record("expected a reasoning entry then a response entry")
        return
    }
    #expect(texts(of: reasoning.segments) == ["thinking"])
    #expect(texts(of: response.segments) == ["answer"])
}

// MARK: - Tool calls

@Test("a tool call folds into a tool-calls entry with id, name, and arguments")
func toolCallFoldsIntoToolCallsEntry() throws {
    let entries = fold([try toolCallUpdate(id: "c1", name: "search", argumentsJSON: #"{"query":"swift"}"#)])

    #expect(entries.count == 1)
    guard case .toolCalls(let calls) = entries.first, let call = Array(calls).first else {
        Issue.record("expected a tool-calls entry carrying one call")
        return
    }
    #expect(call.id == "c1")
    #expect(call.toolName == "search")
    #expect(try jsonValue(call.arguments.jsonString) == jsonValue(#"{"query":"swift"}"#))
}

@Test("a tool call then its update correlate: the output recovers the call's name")
func toolCallAndUpdateCorrelateAndRecoverName() throws {
    let entries = fold([
        try toolCallUpdate(id: "c1", name: "search", argumentsJSON: "{}"),
        toolOutputUpdate(id: "c1", text: "found it"),
    ])

    #expect(entries.count == 2)
    guard case .toolOutput(let output) = entries.last else {
        Issue.record("expected a tool-output entry after the tool-calls entry")
        return
    }
    #expect(output.id == "c1")
    #expect(output.toolName == "search")
    #expect(texts(of: output.segments) == ["found it"])
}

// MARK: - Straggler policy

@Test("a tool-call update after the final message still folds into a tool output")
func stragglerToolCallUpdateAfterFinalMessageFoldsIn() {
    let entries = fold([
        messageChunkUpdate("all done"),
        toolOutputUpdate(id: "late", text: "trailing result"),
    ])

    #expect(entries.count == 2)
    guard case .response(let response) = entries.first,
        case .toolOutput(let output) = entries.last
    else {
        Issue.record("expected a response entry then a tool-output entry")
        return
    }
    #expect(texts(of: response.segments) == ["all done"])
    #expect(output.id == "late")
    #expect(texts(of: output.segments) == ["trailing result"])
}

// MARK: - Plan

@Test("a plan update folds into a response carrying a plan structured segment")
func planFoldsIntoStructuredSegment() throws {
    let plan = Plan(entries: [PlanEntry(content: "Investigate", priority: .high, status: .pending)])
    let entries = fold([.plan(plan)])

    #expect(entries.count == 1)
    guard case .response(let response) = entries.first,
        case .structure(let structure) = response.segments.first
    else {
        Issue.record("expected a response entry with a structured segment")
        return
    }
    #expect(structure.schemaName == "plan")
    let decoded = try JSONDecoder().decode(Plan.self, from: Data(structure.content.jsonString.utf8))
    #expect(decoded == plan)
}

// MARK: - Session-level updates

@Test("updates with no transcript form are skipped")
func sessionLevelUpdatesAreSkipped() {
    let entries = fold([
        .userMessageChunk(ContentChunk(content: .text(TextContent(text: "user")))),
        .usageUpdate(UsageUpdate(size: 100, used: 10)),
        .unknown("something-new"),
    ])

    #expect(entries.isEmpty)
}

// MARK: - Stream folding

@Test(.timeLimit(.minutes(1)))
func foldingAStreamDrainsEveryUpdate() async {
    let updates = [thoughtChunkUpdate("thinking"), messageChunkUpdate("answer")]
    let stream = AsyncStream<SessionUpdate> { continuation in
        for update in updates {
            continuation.yield(update)
        }
        continuation.finish()
    }

    let transcript = await TranscriptBuilder.transcript(folding: stream)

    #expect(Array(transcript).count == 2)
}
