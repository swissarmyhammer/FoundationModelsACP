import Foundation
import Testing

@testable import FoundationModelsACP

/// Values and helpers that the `SessionMergeEngine` test suites share.
enum SessionMergeEngineFixtures {
    static let messageId = MessageId(rawValue: "msg-1")
    static let otherMessageId = MessageId(rawValue: "msg-2")
    static let toolCallId = ToolCallId(rawValue: "call-1")
    static let terminalId = TerminalId(rawValue: "term-1")
    static let planId = PlanId(rawValue: "plan-1")
    static let traceMeta = JSONValue.object(["trace": .string("abc")])
    static let otherMeta = JSONValue.object(["trace": .string("def")])
    static let listCommand = AvailableCommand(description: "List files", name: "ls")
    static let configOption = SessionConfigOption(
        configId: SessionConfigId(rawValue: "fast"),
        name: "Fast mode",
        type: .boolean(SessionConfigBoolean(currentValue: true))
    )

    /// Makes a text content block.
    ///
    /// - Parameter value: The text.
    /// - Returns: The content block.
    static func text(_ value: String) -> ContentBlock {
        .text(TextContent(text: value))
    }

    /// Makes a plan entry with medium priority.
    ///
    /// - Parameters:
    ///   - content: The text of the plan entry.
    ///   - status: The status of the plan entry.
    /// - Returns: The plan entry.
    static func planEntry(_ content: String, status: PlanEntryStatus = .pending) -> PlanEntry {
        PlanEntry(content: content, priority: .medium, status: status)
    }

    /// Makes a plan update with known content.
    ///
    /// - Parameters:
    ///   - entries: The plan entries.
    ///   - planId: The plan identifier.
    /// - Returns: The session update.
    static func planUpdate(_ entries: [PlanEntry], planId: PlanId = planId) -> SessionUpdate {
        .planUpdate(PlanUpdate(plan: .items(PlanItems(entries: entries, planId: planId))))
    }

    /// Finds the entry with an identifier, and records a failure when it is
    /// not in the transcript.
    ///
    /// - Parameters:
    ///   - id: The entry identifier.
    ///   - engine: The engine to read.
    /// - Returns: The entry.
    /// - Throws: An error when the transcript has no entry with this
    ///   identifier.
    static func entry(_ id: SessionEntry.ID, in engine: SessionMergeEngine) throws -> SessionEntry {
        try #require(engine.entry(withID: id))
    }

    /// Reads the message of a message entry.
    ///
    /// - Parameters:
    ///   - id: The entry identifier.
    ///   - engine: The engine to read.
    /// - Returns: The message.
    /// - Throws: An error when the entry is missing or is not a message.
    static func message(_ id: SessionEntry.ID, in engine: SessionMergeEngine) throws -> SessionEntry.Message {
        try #require(try entry(id, in: engine).kind.message)
    }

    /// Reads the tool call of a tool-call entry.
    ///
    /// - Parameters:
    ///   - id: The tool call identifier.
    ///   - engine: The engine to read.
    /// - Returns: The tool call.
    /// - Throws: An error when the entry is missing or is not a tool call.
    static func toolCall(_ id: ToolCallId, in engine: SessionMergeEngine) throws -> ToolCallUpdate {
        try #require(try entry(.toolCall(id), in: engine).kind.toolCall)
    }

    /// Reads the terminal of a terminal entry.
    ///
    /// - Parameters:
    ///   - id: The terminal identifier.
    ///   - engine: The engine to read.
    /// - Returns: The terminal.
    /// - Throws: An error when the entry is missing or is not a terminal.
    static func terminal(_ id: TerminalId, in engine: SessionMergeEngine) throws -> AccumulatedTerminal {
        try #require(try entry(.terminal(id), in: engine).kind.terminal)
    }
}

/// The transcript of `SessionMergeEngine`: the order of entries, and the
/// merge rule for each entry kind.
@Suite struct SessionMergeEngineTranscriptTests {
    private typealias Fixtures = SessionMergeEngineFixtures

    // MARK: - Messages

    @Test func aFirstMessageUpdateAddsAnEntryAtTheEndOfTheTranscript() {
        var engine = SessionMergeEngine()
        let change = engine.apply(
            .userMessage(UserMessage(messageId: Fixtures.messageId, content: .value([Fixtures.text("hello")])))
        )
        let expected = SessionEntry(
            id: .userMessage(Fixtures.messageId),
            kind: .userMessage(SessionEntry.Message(messageId: Fixtures.messageId, content: [Fixtures.text("hello")]))
        )
        #expect(change == .entryAdded(index: 0, entry: expected))
        #expect(engine.entries == [expected])
    }

    @Test func aLaterUpdateForAKnownMessageReportsTheChangedEntryAtItsIndex() {
        var engine = SessionMergeEngine()
        engine.apply(.userMessage(UserMessage(messageId: Fixtures.messageId)))
        let first = engine.apply(
            .agentMessageChunk(ContentChunk(content: Fixtures.text("a"), messageId: Fixtures.otherMessageId))
        )
        let later = engine.apply(
            .agentMessageChunk(ContentChunk(content: Fixtures.text("b"), messageId: Fixtures.otherMessageId))
        )
        let entryId = SessionEntry.ID.agentMessage(Fixtures.otherMessageId)
        let added = SessionEntry(
            id: entryId,
            kind: .agentMessage(SessionEntry.Message(messageId: Fixtures.otherMessageId, content: [Fixtures.text("a")]))
        )
        let changed = SessionEntry(
            id: entryId,
            kind: .agentMessage(
                SessionEntry.Message(messageId: Fixtures.otherMessageId, content: [Fixtures.text("a"), Fixtures.text("b")])
            )
        )
        #expect(first == .entryAdded(index: 1, entry: added))
        #expect(later == .entryChanged(index: 1, entry: changed))
    }

    @Test func chunksAppendToTheMessageContent() throws {
        var engine = SessionMergeEngine()
        engine.apply(.agentMessageChunk(ContentChunk(content: Fixtures.text("a"), messageId: Fixtures.messageId)))
        engine.apply(.agentMessageChunk(ContentChunk(content: Fixtures.text("b"), messageId: Fixtures.messageId)))
        let message = try Fixtures.message(.agentMessage(Fixtures.messageId), in: engine)
        #expect(message.content == [Fixtures.text("a"), Fixtures.text("b")])
    }

    @Test func aWholeMessageUpdateReplacesTheContentAndLaterChunksAppend() throws {
        var engine = SessionMergeEngine()
        engine.apply(.agentMessageChunk(ContentChunk(content: Fixtures.text("streamed"), messageId: Fixtures.messageId)))
        engine.apply(.agentMessage(AgentMessage(messageId: Fixtures.messageId, content: .value([Fixtures.text("final")]))))
        engine.apply(.agentMessageChunk(ContentChunk(content: Fixtures.text("trailing"), messageId: Fixtures.messageId)))
        let message = try Fixtures.message(.agentMessage(Fixtures.messageId), in: engine)
        #expect(message.content == [Fixtures.text("final"), Fixtures.text("trailing")])
    }

    @Test func aMessageUpdateThatOmitsTheContentLeavesTheContentUnchanged() throws {
        var engine = SessionMergeEngine()
        engine.apply(.userMessage(UserMessage(messageId: Fixtures.messageId, content: .value([Fixtures.text("hello")]))))
        engine.apply(.userMessage(UserMessage(messageId: Fixtures.messageId)))
        let message = try Fixtures.message(.userMessage(Fixtures.messageId), in: engine)
        #expect(message.content == [Fixtures.text("hello")])
    }

    @Test func aNullContentClearsTheMessage() throws {
        var engine = SessionMergeEngine()
        engine.apply(.agentThought(AgentThought(messageId: Fixtures.messageId, content: .value([Fixtures.text("x")]))))
        engine.apply(.agentThought(AgentThought(messageId: Fixtures.messageId, content: .cleared)))
        let message = try Fixtures.message(.agentThought(Fixtures.messageId), in: engine)
        #expect(message.content.isEmpty)
    }

    @Test func aThoughtAndAnAgentMessageWithTheSameMessageIdAreTwoEntries() {
        var engine = SessionMergeEngine()
        engine.apply(.agentThoughtChunk(ContentChunk(content: Fixtures.text("plan"), messageId: Fixtures.messageId)))
        engine.apply(.agentMessageChunk(ContentChunk(content: Fixtures.text("do"), messageId: Fixtures.messageId)))
        #expect(engine.entries.map(\.id) == [.agentThought(Fixtures.messageId), .agentMessage(Fixtures.messageId)])
    }

    @Test func anUnknownContentBlockStaysInItsMessage() throws {
        let unknownBlock = ContentBlock.unknown("_vendor_widget", .object(["size": .string("large")]))
        var engine = SessionMergeEngine()
        engine.apply(.agentMessageChunk(ContentChunk(content: unknownBlock, messageId: Fixtures.messageId)))
        let message = try Fixtures.message(.agentMessage(Fixtures.messageId), in: engine)
        #expect(message.content == [unknownBlock])
    }

    @Test func messageMetaFoldsWithThePatchRules() throws {
        var engine = SessionMergeEngine()
        engine.apply(.userMessage(UserMessage(messageId: Fixtures.messageId, meta: .value(Fixtures.traceMeta))))
        engine.apply(.userMessage(UserMessage(messageId: Fixtures.messageId)))
        let kept = try Fixtures.message(.userMessage(Fixtures.messageId), in: engine)
        #expect(kept.meta == .value(Fixtures.traceMeta))

        engine.apply(.userMessage(UserMessage(messageId: Fixtures.messageId, meta: .cleared)))
        let cleared = try Fixtures.message(.userMessage(Fixtures.messageId), in: engine)
        #expect(cleared.meta == .cleared)
    }

    @Test func aChunkWithMetaReplacesTheMessageMetaAndAChunkWithoutMetaKeepsIt() throws {
        var engine = SessionMergeEngine()
        engine.apply(
            .userMessageChunk(
                ContentChunk(content: Fixtures.text("a"), messageId: Fixtures.messageId, meta: Fixtures.traceMeta)
            )
        )
        engine.apply(.userMessageChunk(ContentChunk(content: Fixtures.text("b"), messageId: Fixtures.messageId)))
        let message = try Fixtures.message(.userMessage(Fixtures.messageId), in: engine)
        #expect(message.meta == .value(Fixtures.traceMeta))
    }

    // MARK: - Order of entries

    @Test func entriesKeepThePositionWhereTheyFirstAppeared() {
        var engine = SessionMergeEngine()
        engine.apply(.userMessage(UserMessage(messageId: Fixtures.messageId)))
        engine.apply(.toolCallUpdate(ToolCallUpdate(toolCallId: Fixtures.toolCallId, title: .value("Read"))))
        engine.apply(.terminalUpdate(TerminalUpdate(terminalId: Fixtures.terminalId, command: .value("ls"))))
        // Later updates for the first two entries do not move them.
        engine.apply(.userMessage(UserMessage(messageId: Fixtures.messageId, content: .value([Fixtures.text("x")]))))
        engine.apply(.toolCallUpdate(ToolCallUpdate(toolCallId: Fixtures.toolCallId, status: .value(.completed))))
        #expect(
            engine.entries.map(\.id) == [
                .userMessage(Fixtures.messageId), .toolCall(Fixtures.toolCallId), .terminal(Fixtures.terminalId),
            ]
        )
    }

    // MARK: - Tool calls

    @Test func aFirstToolCallUpdateCreatesTheEntryWithTheUpdateAsItIs() throws {
        let first = ToolCallUpdate(toolCallId: Fixtures.toolCallId, kind: .value(.read), title: .value("Read a file"))
        var engine = SessionMergeEngine()
        engine.apply(.toolCallUpdate(first))
        #expect(try Fixtures.toolCall(Fixtures.toolCallId, in: engine) == first)
    }

    @Test func aLaterToolCallUpdateWithoutANameKeepsTheName() throws {
        var engine = SessionMergeEngine()
        engine.apply(.toolCallUpdate(ToolCallUpdate(toolCallId: Fixtures.toolCallId, name: .value("read_file"))))
        engine.apply(.toolCallUpdate(ToolCallUpdate(toolCallId: Fixtures.toolCallId, status: .value(.completed))))
        let toolCall = try Fixtures.toolCall(Fixtures.toolCallId, in: engine)
        #expect(toolCall.name == .value("read_file"))
        #expect(toolCall.status == .value(.completed))
    }

    @Test func aLaterToolCallUpdateWithANullNameClearsTheName() throws {
        var engine = SessionMergeEngine()
        engine.apply(.toolCallUpdate(ToolCallUpdate(toolCallId: Fixtures.toolCallId, name: .value("read_file"))))
        engine.apply(.toolCallUpdate(ToolCallUpdate(toolCallId: Fixtures.toolCallId, name: .cleared)))
        #expect(try Fixtures.toolCall(Fixtures.toolCallId, in: engine).name == .cleared)
    }

    @Test func aLaterToolCallUpdateThatOmitsEveryFieldKeepsEveryField() throws {
        // The first update sets every field. When the fold misses a field,
        // that field changes to `.unchanged` and the two values are not
        // equal.
        let lineNumber = 7
        let first = ToolCallUpdate(
            toolCallId: Fixtures.toolCallId,
            content: .value([.content(Content(content: Fixtures.text("out")))]),
            kind: .value(.edit),
            locations: .value([ToolCallLocation(path: AbsolutePath(rawValue: "/a"), line: lineNumber)]),
            name: .value("edit_file"),
            rawInput: .value(.object(["path": .string("/a")])),
            rawOutput: .value(.string("ok")),
            status: .value(.inProgress),
            title: .value("Edit /a"),
            meta: .value(Fixtures.traceMeta)
        )
        var engine = SessionMergeEngine()
        engine.apply(.toolCallUpdate(first))
        engine.apply(.toolCallUpdate(ToolCallUpdate(toolCallId: Fixtures.toolCallId)))
        #expect(try Fixtures.toolCall(Fixtures.toolCallId, in: engine) == first)
    }

    @Test func aToolCallContentChunkAppendsAndFoldsItsMeta() throws {
        let first = ToolCallContent.content(Content(content: Fixtures.text("one")))
        let second = ToolCallContent.content(Content(content: Fixtures.text("two")))
        var engine = SessionMergeEngine()
        engine.apply(.toolCallContentChunk(ToolCallContentChunk(content: first, toolCallId: Fixtures.toolCallId)))
        engine.apply(
            .toolCallContentChunk(
                ToolCallContentChunk(content: second, toolCallId: Fixtures.toolCallId, meta: Fixtures.traceMeta)
            )
        )
        let toolCall = try Fixtures.toolCall(Fixtures.toolCallId, in: engine)
        #expect(toolCall.content == .value([first, second]))
        #expect(toolCall.meta == .value(Fixtures.traceMeta))
    }

    // MARK: - Terminals

    @Test func terminalChunksAppendDecodedBytesAndASnapshotReplacesThem() throws {
        var engine = SessionMergeEngine()
        engine.apply(
            .terminalOutputChunk(
                TerminalOutputChunk(data: Data("stale\n".utf8).base64EncodedString(), terminalId: Fixtures.terminalId)
            )
        )
        let afterChunk = try Fixtures.terminal(Fixtures.terminalId, in: engine)
        #expect(afterChunk.output == Data("stale\n".utf8))

        let snapshot = Data("fresh\n".utf8)
        engine.apply(
            .terminalUpdate(
                TerminalUpdate(
                    terminalId: Fixtures.terminalId,
                    output: .value(TerminalOutput(data: snapshot.base64EncodedString()))
                )
            )
        )
        #expect(try Fixtures.terminal(Fixtures.terminalId, in: engine).output == snapshot)
    }

    @Test func terminalUpdateFieldsFoldWithThePatchRules() throws {
        var engine = SessionMergeEngine()
        engine.apply(.terminalUpdate(TerminalUpdate(terminalId: Fixtures.terminalId, command: .value("ls"))))
        engine.apply(.terminalUpdate(TerminalUpdate(terminalId: Fixtures.terminalId, cwd: .cleared)))
        let terminal = try Fixtures.terminal(Fixtures.terminalId, in: engine)
        #expect(terminal.command == .value("ls"))
        #expect(terminal.cwd == .cleared)
    }

    @Test func aTerminalOutputChunkWithMetaReplacesTheTerminalMeta() throws {
        var engine = SessionMergeEngine()
        engine.apply(.terminalUpdate(TerminalUpdate(terminalId: Fixtures.terminalId, meta: .value(Fixtures.traceMeta))))
        engine.apply(
            .terminalOutputChunk(
                TerminalOutputChunk(
                    data: Data("x".utf8).base64EncodedString(),
                    terminalId: Fixtures.terminalId,
                    meta: Fixtures.otherMeta
                )
            )
        )
        #expect(try Fixtures.terminal(Fixtures.terminalId, in: engine).meta == .value(Fixtures.otherMeta))
    }

    // MARK: - Plans

    @Test func aPlanUpdateReplacesThePlanAndKeepsItsFirstPosition() throws {
        var engine = SessionMergeEngine()
        engine.apply(Fixtures.planUpdate([Fixtures.planEntry("step one")]))
        engine.apply(.userMessage(UserMessage(messageId: Fixtures.messageId)))
        let replacement = [Fixtures.planEntry("step one", status: .completed), Fixtures.planEntry("step two")]
        let change = engine.apply(Fixtures.planUpdate(replacement))

        let entry = try Fixtures.entry(.plan(Fixtures.planId), in: engine)
        #expect(change == .entryChanged(index: 0, entry: entry))
        #expect(engine.entries.map(\.id) == [.plan(Fixtures.planId), .userMessage(Fixtures.messageId)])
        let plan = try #require(entry.kind.plan)
        #expect(plan.plan == .items(PlanItems(entries: replacement, planId: Fixtures.planId)))
    }

    @Test func aPlanUpdateWithUnknownContentIsKeptAndMatchedByItsPlanId() throws {
        let unknownContent = PlanUpdateContent.unknown(
            "_vendor_outline",
            .object(["planId": .string(Fixtures.planId.rawValue), "outline": .string("v1")])
        )
        var engine = SessionMergeEngine()
        engine.apply(.planUpdate(PlanUpdate(plan: unknownContent)))
        engine.apply(Fixtures.planUpdate([Fixtures.planEntry("step")]))
        #expect(engine.entries.map(\.id) == [.plan(Fixtures.planId)])
    }

    @Test func aPlanUpdateWithUnknownContentAndNoPlanIdIsKeptAsANewEntry() throws {
        let unknownContent = PlanUpdateContent.unknown("_vendor_outline", .object(["outline": .string("v1")]))
        var engine = SessionMergeEngine()
        engine.apply(.planUpdate(PlanUpdate(plan: unknownContent)))
        let plan = try #require(engine.entries.first?.kind.plan)
        #expect(plan.plan == unknownContent)
    }

    // MARK: - Unknown updates

    @Test func anUnknownSessionUpdateBecomesAnUnknownEntry() throws {
        let payload = JSONValue.object(["value": .string("x")])
        var engine = SessionMergeEngine()
        let change = engine.apply(.unknown("_vendor_event", payload))
        let entry = try #require(engine.entries.first)
        #expect(entry.kind == .unknown(type: "_vendor_event", payload: payload))
        #expect(change == .entryAdded(index: 0, entry: entry))
    }

    @Test func eachUnknownSessionUpdateIsAnotherEntry() {
        var engine = SessionMergeEngine()
        engine.apply(.unknown("_vendor_event", .object([:])))
        engine.apply(.unknown("_vendor_event", .object([:])))
        #expect(engine.entries.map(\.id) == [.unidentified(position: 0), .unidentified(position: 1)])
    }
}

/// The last-value state of `SessionMergeEngine`: commands, configuration
/// options, usage, agent state, and session information.
@Suite struct SessionMergeEngineStateTests {
    private typealias Fixtures = SessionMergeEngineFixtures

    @Test func availableCommandsAreNilBeforeAReport() {
        #expect(SessionMergeEngine().availableCommands == nil)
    }

    @Test func anEmptyAvailableCommandsUpdateReportsNoCommandsAndNotNil() {
        var engine = SessionMergeEngine()
        let change = engine.apply(.availableCommandsUpdate(AvailableCommandsUpdate(availableCommands: [])))
        #expect(engine.availableCommands == [])
        #expect(change == .availableCommandsChanged([]))
    }

    @Test func anAvailableCommandsUpdateReplacesTheSeed() {
        var engine = SessionMergeEngine()
        engine.seed(from: NewSessionResponse(sessionId: SessionId(rawValue: "s"), availableCommands: [Fixtures.listCommand]))
        engine.apply(.availableCommandsUpdate(AvailableCommandsUpdate(availableCommands: [])))
        #expect(engine.availableCommands == [])
    }

    @Test func aSeedWithOmittedOrEmptyCommandsLeavesNil() {
        var engine = SessionMergeEngine()
        let omitted = engine.seed(from: NewSessionResponse(sessionId: SessionId(rawValue: "s")))
        let empty = engine.seed(from: ResumeSessionResponse(availableCommands: []))
        #expect(engine.availableCommands == nil)
        #expect(omitted.isEmpty)
        #expect(empty.isEmpty)
    }

    @Test func aSeedFromANewSessionResponseSetsCommandsAndConfigOptions() {
        var engine = SessionMergeEngine()
        let changes = engine.seed(
            from: NewSessionResponse(
                sessionId: SessionId(rawValue: "s"),
                availableCommands: [Fixtures.listCommand],
                configOptions: [Fixtures.configOption]
            )
        )
        #expect(engine.availableCommands == [Fixtures.listCommand])
        #expect(engine.configOptions == [Fixtures.configOption])
        #expect(
            changes == [.availableCommandsChanged([Fixtures.listCommand]), .configOptionsChanged([Fixtures.configOption])]
        )
    }

    @Test func aSeedFromAResumeSessionResponseSetsCommandsAndConfigOptions() {
        var engine = SessionMergeEngine()
        engine.seed(
            from: ResumeSessionResponse(availableCommands: [Fixtures.listCommand], configOptions: [Fixtures.configOption])
        )
        #expect(engine.availableCommands == [Fixtures.listCommand])
        #expect(engine.configOptions == [Fixtures.configOption])
    }

    @Test func aConfigOptionUpdateReplacesTheConfigOptions() {
        var engine = SessionMergeEngine()
        engine.seed(from: ResumeSessionResponse(configOptions: [Fixtures.configOption]))
        let change = engine.apply(.configOptionUpdate(ConfigOptionUpdate(configOptions: [])))
        #expect(engine.configOptions == [])
        #expect(change == .configOptionsChanged([]))
    }

    @Test func aUsageUpdateReplacesTheUsage() {
        let windowSize = 1000
        let firstUsed = 10
        let laterUsed = 20
        var engine = SessionMergeEngine()
        engine.apply(.usageUpdate(UsageUpdate(size: windowSize, used: firstUsed)))
        let later = UsageUpdate(size: windowSize, used: laterUsed)
        let change = engine.apply(.usageUpdate(later))
        #expect(engine.usage == later)
        #expect(change == .usageChanged(later))
    }

    @Test func aStateUpdateReplacesTheAgentStateAndKeepsAnExtensionStopReason() {
        var engine = SessionMergeEngine()
        engine.apply(.stateUpdate(.running(RunningStateUpdate())))
        let idle = StateUpdate.idle(IdleStateUpdate(stopReason: .unknown("_truncated")))
        let change = engine.apply(.stateUpdate(idle))
        #expect(engine.agentState == idle)
        #expect(change == .agentStateChanged(idle))
    }

    @Test func aTitleOnlySessionInfoUpdateKeepsTheUpdatedAtValue() {
        var engine = SessionMergeEngine()
        engine.apply(.sessionInfoUpdate(SessionInfoUpdate(title: .value("First"), updatedAt: .value("2026-10-02T00:00:00Z"))))
        let change = engine.apply(.sessionInfoUpdate(SessionInfoUpdate(title: .value("Second"))))
        let expected = SessionInfoUpdate(title: .value("Second"), updatedAt: .value("2026-10-02T00:00:00Z"))
        #expect(engine.sessionInfo == expected)
        #expect(change == .sessionInfoChanged(expected))
    }

    @Test func aNullSessionInfoFieldClearsIt() {
        var engine = SessionMergeEngine()
        engine.apply(.sessionInfoUpdate(SessionInfoUpdate(title: .value("First"))))
        engine.apply(.sessionInfoUpdate(SessionInfoUpdate(title: .cleared)))
        #expect(engine.sessionInfo.title == .cleared)
    }
}

/// Replay and reset of `SessionMergeEngine`: an agent replays the transcript
/// on `session/resume`, and a client clears the transcript before a replay.
@Suite struct SessionMergeEngineReplayTests {
    private typealias Fixtures = SessionMergeEngineFixtures

    /// Makes an engine that holds one entry of each kind and a value for
    /// each state field.
    ///
    /// - Returns: The engine.
    private static func populatedEngine() -> SessionMergeEngine {
        let windowSize = 1000
        let tokensUsed = 10
        let updates: [SessionUpdate] = [
            .userMessage(UserMessage(messageId: Fixtures.messageId, content: .value([Fixtures.text("hi")]))),
            .agentThoughtChunk(ContentChunk(content: Fixtures.text("plan"), messageId: Fixtures.otherMessageId)),
            .agentMessageChunk(
                ContentChunk(content: Fixtures.text("ok"), messageId: Fixtures.otherMessageId, meta: Fixtures.traceMeta)
            ),
            .toolCallUpdate(ToolCallUpdate(toolCallId: Fixtures.toolCallId, name: .value("ls"), title: .value("List"))),
            .toolCallUpdate(ToolCallUpdate(toolCallId: Fixtures.toolCallId, status: .value(.completed))),
            .terminalUpdate(TerminalUpdate(terminalId: Fixtures.terminalId, command: .value("ls"), cwd: .cleared)),
            .terminalOutputChunk(
                TerminalOutputChunk(data: Data("a.txt\n".utf8).base64EncodedString(), terminalId: Fixtures.terminalId)
            ),
            Fixtures.planUpdate([Fixtures.planEntry("step")]),
            .planUpdate(PlanUpdate(plan: .unknown("_vendor_outline", .object([:])))),
            .unknown("_vendor_event", .object(["value": .string("x")])),
            .availableCommandsUpdate(AvailableCommandsUpdate(availableCommands: [Fixtures.listCommand])),
            .configOptionUpdate(ConfigOptionUpdate(configOptions: [Fixtures.configOption])),
            .usageUpdate(UsageUpdate(size: windowSize, used: tokensUsed)),
            .stateUpdate(.idle(IdleStateUpdate(stopReason: .endTurn))),
            .sessionInfoUpdate(SessionInfoUpdate(title: .value("Session"), updatedAt: .cleared)),
        ]
        var engine = SessionMergeEngine()
        for update in updates {
            engine.apply(update)
        }
        return engine
    }

    @Test func aReplayAppliedToANewEngineGivesTheSameState() throws {
        let original = Self.populatedEngine()
        let transcriptUpdates = original.transcriptUpdates
        let stateUpdates = original.stateUpdates
        var replayed = SessionMergeEngine()
        for update in transcriptUpdates + stateUpdates {
            replayed.apply(update)
        }
        // Each original field has a value. Thus, a replay that drops a field
        // cannot pass as `nil == nil` or as an empty transcript.
        let commands = try #require(original.availableCommands)
        let options = try #require(original.configOptions)
        let usage = try #require(original.usage)
        let agentState = try #require(original.agentState)
        #expect(!original.entries.isEmpty)
        #expect(original.sessionInfo != SessionInfoUpdate())
        #expect(replayed.entries == original.entries)
        #expect(replayed.availableCommands == commands)
        #expect(replayed.configOptions == options)
        #expect(replayed.usage == usage)
        #expect(replayed.agentState == agentState)
        #expect(replayed.sessionInfo == original.sessionInfo)
        #expect(replayed == original)
    }

    @Test func aReplayedEntryKeepsItsIdentifier() {
        let original = Self.populatedEngine()
        var replayed = SessionMergeEngine()
        for update in original.transcriptUpdates {
            replayed.apply(update)
        }
        #expect(replayed.entries.map(\.id) == original.entries.map(\.id))
    }

    @Test func theTranscriptUpdatesHoldNoStateUpdate() {
        let transcript = Self.populatedEngine().transcriptUpdates
        let hasStateUpdate = transcript.contains { update in
            if case .stateUpdate = update { return true }
            return false
        }
        #expect(!hasStateUpdate)
    }

    @Test func aNewEngineHasNoStateUpdatesToReplay() {
        #expect(SessionMergeEngine().stateUpdates.isEmpty)
    }

    @Test func resetBeforeAReplayStopsChunksFromAppendingAgain() throws {
        var engine = SessionMergeEngine()
        let chunk = SessionUpdate.agentMessageChunk(ContentChunk(content: Fixtures.text("a"), messageId: Fixtures.messageId))
        engine.apply(chunk)
        engine.reset()
        engine.apply(chunk)
        let message = try Fixtures.message(.agentMessage(Fixtures.messageId), in: engine)
        #expect(message.content == [Fixtures.text("a")])
    }

    @Test func resetReturnsTheEngineToItsInitialState() {
        var engine = Self.populatedEngine()
        engine.reset()
        #expect(engine == SessionMergeEngine())
    }
}
