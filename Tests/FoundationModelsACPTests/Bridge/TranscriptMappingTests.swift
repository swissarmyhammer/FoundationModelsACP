import FoundationModels
import Testing

@testable import FoundationModelsACP

// MARK: - Golden update sequence

@Test("a text + reasoning + two-tool-call turn maps to the exact update sequence")
func goldenTurnMapsToExpectedUpdateSequence() throws {
    let entries: [Transcript.Entry] = [
        reasoningEntry("Let me look this up"),
        try toolCallEntry(id: "call-1", name: "search", argumentsJSON: #"{"query":"swift"}"#),
        toolOutputEntry(id: "call-1", name: "search", text: "found it"),
        try toolCallEntry(id: "call-2", name: "read", argumentsJSON: #"{"path":"/tmp/x"}"#),
        toolOutputEntry(id: "call-2", name: "read", text: "contents"),
        responseEntry("Here is the answer"),
    ]

    var mapper = TranscriptMapper()
    let updates = mapper.consume(entries)

    let expected: [SessionUpdate] = [
        thoughtChunkUpdate("Let me look this up"),
        .toolCall(
            ToolCall(
                title: "search",
                toolCallId: ToolCallId(rawValue: "call-1"),
                rawInput: try jsonValue(#"{"query":"swift"}"#),
                status: .pending
            )
        ),
        .toolCallUpdate(
            ToolCallUpdate(
                toolCallId: ToolCallId(rawValue: "call-1"),
                content: [.content(Content(content: .text(TextContent(text: "found it"))))],
                status: .completed
            )
        ),
        .toolCall(
            ToolCall(
                title: "read",
                toolCallId: ToolCallId(rawValue: "call-2"),
                rawInput: try jsonValue(#"{"path":"/tmp/x"}"#),
                status: .pending
            )
        ),
        .toolCallUpdate(
            ToolCallUpdate(
                toolCallId: ToolCallId(rawValue: "call-2"),
                content: [.content(Content(content: .text(TextContent(text: "contents"))))],
                status: .completed
            )
        ),
        messageChunkUpdate("Here is the answer"),
    ]

    #expect(updates == expected)
}

// MARK: - Tool-call correlation

@Test("a tool call and its output share the tool-call id across the two updates")
func toolCallAndOutputCorrelateById() throws {
    let entries: [Transcript.Entry] = [
        try toolCallEntry(id: "abc", name: "fetch", argumentsJSON: "{}"),
        toolOutputEntry(id: "abc", name: "fetch", text: "done"),
    ]

    var mapper = TranscriptMapper()
    let updates = mapper.consume(entries)

    guard case .toolCall(let call) = updates.first,
        case .toolCallUpdate(let update) = updates.last
    else {
        Issue.record("expected a tool_call followed by a tool_call_update")
        return
    }
    #expect(call.toolCallId == ToolCallId(rawValue: "abc"))
    #expect(update.toolCallId == call.toolCallId)
    #expect(call.status == .pending)
    #expect(update.status == .completed)
}

// MARK: - Input entries

@Test("prompt and instruction entries are input, not output, and map to nothing")
func promptAndInstructionEntriesMapToNothing() {
    let entries: [Transcript.Entry] = [
        .instructions(Transcript.Instructions(segments: [.text(Transcript.TextSegment(content: "sys"))], toolDefinitions: [])),
        .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "hello"))])),
    ]

    var mapper = TranscriptMapper()
    #expect(mapper.consume(entries).isEmpty)
}

// MARK: - Plan

@Test("a plan structured segment in a response maps to a plan update")
func planStructuredSegmentMapsToPlan() throws {
    let entry = try planResponseEntry(
        #"{"entries":[{"content":"Investigate","priority":"high","status":"pending"}]}"#
    )

    var mapper = TranscriptMapper()
    let updates = mapper.consume([entry])

    let expected: [SessionUpdate] = [
        .plan(Plan(entries: [PlanEntry(content: "Investigate", priority: .high, status: .pending)]))
    ]
    #expect(updates == expected)
}

// MARK: - Incremental consumption

@Test("re-feeding a growing transcript emits only the entries not seen before")
func growingTranscriptEmitsOnlyNewEntries() throws {
    var mapper = TranscriptMapper()

    let first = mapper.consume([reasoningEntry("thinking")])
    #expect(first == [thoughtChunkUpdate("thinking")])

    // The same prefix plus one new entry: only the new entry maps.
    let second = mapper.consume([reasoningEntry("thinking"), responseEntry("answer")])
    #expect(second == [messageChunkUpdate("answer")])

    // No growth: nothing new.
    #expect(mapper.consume([reasoningEntry("thinking"), responseEntry("answer")]).isEmpty)
}
