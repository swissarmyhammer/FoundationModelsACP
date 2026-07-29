import Foundation
import Testing

@testable import FoundationModelsACP

/// `SessionUpdateAggregator` — the upsert/append/replace rules ACP v2 states
/// only in prose on each `session/update` variant's own doc comment, folded
/// into materialized per-session state.
///
/// A decoded `ToolCallUpdate`, `TerminalUpdate`, or message upsert is only
/// ever one update in isolation; nothing about the generated wire types
/// enforces "first sighting creates, later sightings patch" or "a chunk
/// appends". These tests are the proof that the aggregator applies the wire
/// prose correctly.
@Suite struct SessionUpdateAggregatorTests {
    private static let messageId = MessageId(rawValue: "msg-1")
    private static let toolCallId = ToolCallId(rawValue: "call-1")
    private static let terminalId = TerminalId(rawValue: "term-1")
    private static let planId = PlanId(rawValue: "plan-1")

    private static func text(_ value: String) -> ContentBlock {
        .text(TextContent(text: value))
    }

    // MARK: - Messages: three-state content semantics

    @Test func omittedContentOnANewMessageStartsEmpty() {
        var aggregator = SessionUpdateAggregator()
        aggregator.apply(.userMessage(UserMessage(messageId: Self.messageId)))
        #expect(aggregator.messages[Self.messageId] == [])
    }

    @Test func omittedContentOnAnExistingMessageLeavesItUnchanged() {
        var aggregator = SessionUpdateAggregator()
        aggregator.apply(.userMessage(UserMessage(messageId: Self.messageId, content: .value([Self.text("hello")]))))
        aggregator.apply(.userMessage(UserMessage(messageId: Self.messageId)))
        #expect(aggregator.messages[Self.messageId] == [Self.text("hello")])
    }

    @Test func nullContentClearsAMessage() {
        var aggregator = SessionUpdateAggregator()
        aggregator.apply(.userMessage(UserMessage(messageId: Self.messageId, content: .value([Self.text("hello")]))))
        aggregator.apply(.userMessage(UserMessage(messageId: Self.messageId, content: .cleared)))
        #expect(aggregator.messages[Self.messageId] == [])
    }

    @Test func emptyArrayContentClearsAMessageTheSameAsNull() {
        // A distinct wire state from `.cleared` (a concrete empty array, not
        // an explicit `null`), but the same accumulated effect — "send `[]`
        // or `null` to clear it".
        var aggregator = SessionUpdateAggregator()
        aggregator.apply(.userMessage(UserMessage(messageId: Self.messageId, content: .value([Self.text("hello")]))))
        aggregator.apply(.userMessage(UserMessage(messageId: Self.messageId, content: .value([]))))
        #expect(aggregator.messages[Self.messageId] == [])
    }

    @Test func concreteArrayContentReplacesAMessageWholesale() {
        var aggregator = SessionUpdateAggregator()
        aggregator.apply(.userMessage(UserMessage(messageId: Self.messageId, content: .value([Self.text("first")]))))
        aggregator.apply(.userMessage(UserMessage(messageId: Self.messageId, content: .value([Self.text("second")]))))
        #expect(aggregator.messages[Self.messageId] == [Self.text("second")])
    }

    @Test func chunksAppendCreatingTheMessageOnFirstSighting() {
        var aggregator = SessionUpdateAggregator()
        aggregator.apply(.agentMessageChunk(ContentChunk(content: Self.text("a"), messageId: Self.messageId)))
        aggregator.apply(.agentMessageChunk(ContentChunk(content: Self.text("b"), messageId: Self.messageId)))
        #expect(aggregator.messages[Self.messageId] == [Self.text("a"), Self.text("b")])
    }

    @Test func laterChunksAppendToAContentReplacementFromAnUpsert() {
        // "When an update includes content, that array replaces any content
        // previously accumulated... Later chunks with the same messageId
        // append to the current content."
        var aggregator = SessionUpdateAggregator()
        aggregator.apply(.agentMessageChunk(ContentChunk(content: Self.text("streamed"), messageId: Self.messageId)))
        aggregator.apply(.agentMessage(AgentMessage(messageId: Self.messageId, content: .value([Self.text("final")]))))
        aggregator.apply(.agentMessageChunk(ContentChunk(content: Self.text("trailing"), messageId: Self.messageId)))
        #expect(aggregator.messages[Self.messageId] == [Self.text("final"), Self.text("trailing")])
    }

    @Test func agentThoughtFollowsTheSameUpsertRuleAsMessages() {
        var aggregator = SessionUpdateAggregator()
        aggregator.apply(.agentThought(AgentThought(messageId: Self.messageId, content: .value([Self.text("thinking")]))))
        aggregator.apply(.agentThought(AgentThought(messageId: Self.messageId, content: .cleared)))
        #expect(aggregator.messages[Self.messageId] == [])
    }

    // MARK: - Tool calls: upsert keyed by toolCallId

    @Test func firstToolCallUpdateCreatesTheToolCall() {
        var aggregator = SessionUpdateAggregator()
        aggregator.apply(.toolCallUpdate(ToolCallUpdate(toolCallId: Self.toolCallId, title: .value("Read a file"))))
        #expect(aggregator.toolCalls.count == 1)
        #expect(aggregator.toolCalls[Self.toolCallId]?.title == .value("Read a file"))
    }

    @Test func secondToolCallUpdatePatchesWithoutDuplicating() {
        var aggregator = SessionUpdateAggregator()
        aggregator.apply(
            .toolCallUpdate(
                ToolCallUpdate(toolCallId: Self.toolCallId, status: .value(.pending), title: .value("Read a file"))
            )
        )
        aggregator.apply(.toolCallUpdate(ToolCallUpdate(toolCallId: Self.toolCallId, status: .value(.completed))))

        #expect(aggregator.toolCalls.count == 1)
        let toolCall = try! #require(aggregator.toolCalls[Self.toolCallId])
        // The patch only named `status`; `title` is folded over from the
        // first sighting rather than reverting to unknown.
        #expect(toolCall.status == .value(.completed))
        #expect(toolCall.title == .value("Read a file"))
    }

    @Test func toolCallUpdateClearingAFieldOverridesAnEarlierValue() {
        var aggregator = SessionUpdateAggregator()
        aggregator.apply(.toolCallUpdate(ToolCallUpdate(toolCallId: Self.toolCallId, title: .value("Read a file"))))
        aggregator.apply(.toolCallUpdate(ToolCallUpdate(toolCallId: Self.toolCallId, title: .cleared)))
        #expect(aggregator.toolCalls[Self.toolCallId]?.title == .cleared)
    }

    @Test func unknownToolCallStatusSurvivesAccumulation() {
        var aggregator = SessionUpdateAggregator()
        aggregator.apply(
            .toolCallUpdate(ToolCallUpdate(toolCallId: Self.toolCallId, status: .value(.unknown("_vendor_stalled"))))
        )
        #expect(aggregator.toolCalls[Self.toolCallId]?.status == .value(.unknown("_vendor_stalled")))
    }

    @Test func toolCallContentChunkAppendsCreatingOnFirstSighting() {
        var aggregator = SessionUpdateAggregator()
        let first = ToolCallContent.content(Content(content: Self.text("partial output")))
        aggregator.apply(.toolCallContentChunk(ToolCallContentChunk(content: first, toolCallId: Self.toolCallId)))
        guard case .value(let content) = aggregator.toolCalls[Self.toolCallId]?.content else {
            Issue.record("expected accumulated content")
            return
        }
        #expect(content == [first])
    }

    @Test func toolCallUpdateContentFieldReplacesThenLaterChunksAppend() {
        var aggregator = SessionUpdateAggregator()
        let streamed = ToolCallContent.content(Content(content: Self.text("streamed")))
        let replacement = ToolCallContent.content(Content(content: Self.text("replacement")))
        let trailing = ToolCallContent.content(Content(content: Self.text("trailing")))

        aggregator.apply(.toolCallContentChunk(ToolCallContentChunk(content: streamed, toolCallId: Self.toolCallId)))
        aggregator.apply(
            .toolCallUpdate(ToolCallUpdate(toolCallId: Self.toolCallId, content: .value([replacement])))
        )
        aggregator.apply(.toolCallContentChunk(ToolCallContentChunk(content: trailing, toolCallId: Self.toolCallId)))

        guard case .value(let content) = aggregator.toolCalls[Self.toolCallId]?.content else {
            Issue.record("expected accumulated content")
            return
        }
        #expect(content == [replacement, trailing])
    }

    @Test func toolCallContentChunkAppendsAfterAPriorClear() {
        // The chunk-append branch must treat a `.cleared` prior content the
        // same as `.unchanged` — both mean "nothing accumulated yet" — not
        // fall through to some other default.
        var aggregator = SessionUpdateAggregator()
        aggregator.apply(.toolCallUpdate(ToolCallUpdate(toolCallId: Self.toolCallId, content: .cleared)))
        let chunkContent = ToolCallContent.content(Content(content: Self.text("after clear")))
        aggregator.apply(
            .toolCallContentChunk(ToolCallContentChunk(content: chunkContent, toolCallId: Self.toolCallId))
        )
        guard case .value(let content) = aggregator.toolCalls[Self.toolCallId]?.content else {
            Issue.record("expected accumulated content")
            return
        }
        #expect(content == [chunkContent])
    }

    // MARK: - Terminals: upsert keyed by terminalId

    @Test func aNeverBeforeSeenTerminalIdStartsWithEveryFieldUnknown() {
        var aggregator = SessionUpdateAggregator()
        aggregator.apply(.terminalUpdate(TerminalUpdate(terminalId: Self.terminalId, command: .value("ls"))))
        let terminal = try! #require(aggregator.terminals[Self.terminalId])
        #expect(terminal.command == .value("ls"))
        #expect(terminal.cwd == .unchanged)
        #expect(terminal.exitStatus == .unchanged)
        #expect(terminal.output.isEmpty)
    }

    @Test func terminalUpdateOmittedNullAndValueFoldOntoPriorState() {
        var aggregator = SessionUpdateAggregator()
        let cwd = try! #require(AbsolutePath(rawValue: "/work"))
        aggregator.apply(
            .terminalUpdate(TerminalUpdate(terminalId: Self.terminalId, command: .value("ls"), cwd: .value(cwd)))
        )
        // Omits `command`, clears `cwd`.
        aggregator.apply(.terminalUpdate(TerminalUpdate(terminalId: Self.terminalId, cwd: .cleared)))
        let terminal = try! #require(aggregator.terminals[Self.terminalId])
        #expect(terminal.command == .value("ls"))
        #expect(terminal.cwd == .cleared)
    }

    @Test func terminalOutputChunkDecodesExactBytesIncludingNonUTF8() {
        // 0xFF/0xFE is not valid UTF-8 on its own; base64 carries it intact
        // regardless.
        let firstBytes = Data([0xFF, 0xFE, 0x00, 0x01])
        let secondBytes = Data([0xD8, 0x00, 0xDC, 0x00])
        var aggregator = SessionUpdateAggregator()
        aggregator.apply(
            .terminalOutputChunk(
                TerminalOutputChunk(data: firstBytes.base64EncodedString(), terminalId: Self.terminalId)
            )
        )
        aggregator.apply(
            .terminalOutputChunk(
                TerminalOutputChunk(data: secondBytes.base64EncodedString(), terminalId: Self.terminalId)
            )
        )
        #expect(aggregator.terminals[Self.terminalId]?.output == firstBytes + secondBytes)
    }

    @Test func terminalUpdateSnapshotReplacesPriorAccumulatedOutputRatherThanAppending() {
        var aggregator = SessionUpdateAggregator()
        aggregator.apply(
            .terminalOutputChunk(
                TerminalOutputChunk(data: Data("stale\n".utf8).base64EncodedString(), terminalId: Self.terminalId)
            )
        )
        let snapshot = Data("resynced state\n".utf8)
        aggregator.apply(
            .terminalUpdate(
                TerminalUpdate(
                    terminalId: Self.terminalId,
                    output: .value(TerminalOutput(data: snapshot.base64EncodedString()))
                )
            )
        )
        #expect(aggregator.terminals[Self.terminalId]?.output == snapshot)
    }

    @Test func terminalUpdateClearingOneFieldAndReplacingOutputInTheSameMessageAppliesBoth() {
        // Per-field folding and the output-snapshot replace are independent
        // operations within one `TerminalUpdate`; one must not block the
        // other.
        var aggregator = SessionUpdateAggregator()
        aggregator.apply(.terminalUpdate(TerminalUpdate(terminalId: Self.terminalId, command: .value("ls"))))
        let snapshot = Data("resynced\n".utf8)
        aggregator.apply(
            .terminalUpdate(
                TerminalUpdate(
                    terminalId: Self.terminalId,
                    command: .cleared,
                    output: .value(TerminalOutput(data: snapshot.base64EncodedString()))
                )
            )
        )
        let terminal = try! #require(aggregator.terminals[Self.terminalId])
        #expect(terminal.command == .cleared)
        #expect(terminal.output == snapshot)
    }

    @Test func malformedBase64TerminalUpdateSnapshotIsDroppedRatherThanCorruptingTheBuffer() {
        var aggregator = SessionUpdateAggregator()
        aggregator.apply(
            .terminalOutputChunk(
                TerminalOutputChunk(data: Data("ok\n".utf8).base64EncodedString(), terminalId: Self.terminalId)
            )
        )
        aggregator.apply(
            .terminalUpdate(
                TerminalUpdate(terminalId: Self.terminalId, output: .value(TerminalOutput(data: "not valid base64!!")))
            )
        )
        #expect(aggregator.terminals[Self.terminalId]?.output == Data("ok\n".utf8))
    }

    @Test func malformedBase64TerminalChunkIsDroppedRatherThanCorruptingTheBuffer() {
        var aggregator = SessionUpdateAggregator()
        aggregator.apply(
            .terminalOutputChunk(
                TerminalOutputChunk(data: Data("ok\n".utf8).base64EncodedString(), terminalId: Self.terminalId)
            )
        )
        aggregator.apply(
            .terminalOutputChunk(TerminalOutputChunk(data: "not valid base64!!", terminalId: Self.terminalId))
        )
        #expect(aggregator.terminals[Self.terminalId]?.output == Data("ok\n".utf8))
    }

    // MARK: - Plans: replace entries per planId

    private static func entry(_ content: String, status: PlanEntryStatus = .pending) -> PlanEntry {
        PlanEntry(content: content, priority: .medium, status: status)
    }

    @Test func planUpdateReplacesEntriesForItsPlanId() {
        var aggregator = SessionUpdateAggregator()
        aggregator.apply(
            .planUpdate(PlanUpdate(plan: .items(PlanItems(entries: [Self.entry("step one")], planId: Self.planId))))
        )
        aggregator.apply(
            .planUpdate(
                PlanUpdate(
                    plan: .items(
                        PlanItems(
                            entries: [Self.entry("step one", status: .completed), Self.entry("step two")],
                            planId: Self.planId
                        )
                    )
                )
            )
        )
        #expect(aggregator.plans[Self.planId] == [Self.entry("step one", status: .completed), Self.entry("step two")])
    }

    @Test func planUpdatesForDifferentPlanIdsDoNotInterfere() {
        let otherPlanId = PlanId(rawValue: "plan-2")
        var aggregator = SessionUpdateAggregator()
        aggregator.apply(
            .planUpdate(PlanUpdate(plan: .items(PlanItems(entries: [Self.entry("a")], planId: Self.planId))))
        )
        aggregator.apply(
            .planUpdate(PlanUpdate(plan: .items(PlanItems(entries: [Self.entry("b")], planId: otherPlanId))))
        )
        #expect(aggregator.plans[Self.planId] == [Self.entry("a")])
        #expect(aggregator.plans[otherPlanId] == [Self.entry("b")])
    }

    @Test func anUnrecognizedPlanUpdateContentVariantLeavesPlansUntouched() {
        // The wire payload itself is already preserved intact by the
        // generated `.unknown` fallback; there is simply no known `entries`
        // shape here for the aggregator to materialize.
        var aggregator = SessionUpdateAggregator()
        aggregator.apply(
            .planUpdate(PlanUpdate(plan: .unknown("_vendor_outline", .object(["planId": .string(Self.planId.rawValue)]))))
        )
        #expect(aggregator.plans.isEmpty)
    }

    // MARK: - Update kinds with no per-item identity are no-ops

    @Test func updateKindsWithNoPerItemIdentityLeaveAccumulatedStateUntouched() {
        var aggregator = SessionUpdateAggregator()
        aggregator.apply(.stateUpdate(.idle(IdleStateUpdate())))
        aggregator.apply(.usageUpdate(UsageUpdate(size: 1000, used: 10)))
        #expect(aggregator.messages.isEmpty)
        #expect(aggregator.toolCalls.isEmpty)
        #expect(aggregator.terminals.isEmpty)
        #expect(aggregator.plans.isEmpty)
    }
}

// MARK: - Terminal is a ToolCallContent variant, not a ContentBlock variant

@Suite struct TerminalContentPlacementTests {
    @Test func terminalToolCallContentRoundTrips() throws {
        let content = try WireRoundTrip.expectLossless(ToolCallContent.self, """
            {"type":"terminal","terminalId":"term-1"}
            """)
        guard case .terminal(let terminal) = content else {
            Issue.record("expected .terminal, got \(content)")
            return
        }
        #expect(terminal.terminalId == TerminalId(rawValue: "term-1"))
    }

    @Test func aTerminalPayloadOfferedAsAContentBlockDoesNotDecodeAsAKnownVariant() throws {
        let block = try WireRoundTrip.expectLossless(ContentBlock.self, """
            {"type":"terminal","terminalId":"term-1"}
            """)
        guard case .unknown(let tag, _) = block else {
            Issue.record("expected the unknown fallback since ContentBlock has no terminal case, got \(block)")
            return
        }
        #expect(tag == "terminal")
    }
}
