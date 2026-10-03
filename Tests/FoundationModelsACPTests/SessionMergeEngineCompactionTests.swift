import Foundation
import Testing

@testable import FoundationModelsACP

/// The unstable compaction and notice updates in `SessionMergeEngine`.
///
/// A compaction changes only the model context of the agent. The transcript
/// keeps the full history, so a compaction is one more entry, and it never
/// removes or changes an earlier entry. A notice is a live event: `apply`
/// returns it, and the engine does not keep it.
@Suite struct SessionMergeEngineCompactionTests {
    private typealias Fixtures = SessionMergeEngineFixtures

    /// The compaction that most tests use.
    private static let compactionId = Unstable.CompactionId(rawValue: "compaction-1")

    /// A notice that a test applies.
    private static let notice = Unstable.Notice(severity: .warning, title: "Context is almost full")

    /// Makes the stable session update that carries an unstable update.
    ///
    /// - Parameter update: The unstable update.
    /// - Returns: The stable session update.
    /// - Throws: An error when the payload does not encode.
    private static func stable(_ update: Unstable.SessionUpdate) throws -> SessionUpdate {
        try SessionUpdate(update)
    }

    /// Makes a stable `compaction_update` for the compaction of these tests.
    ///
    /// - Parameters:
    ///   - status: The status of the compaction.
    ///   - error: The `error` patch.
    ///   - summary: The `summary` patch.
    ///   - meta: The `_meta` patch.
    /// - Returns: The stable session update.
    /// - Throws: An error when the payload does not encode.
    private static func compactionUpdate(
        _ status: Unstable.CompactionStatus,
        error: PatchField<String> = .unchanged,
        summary: PatchField<[ContentBlock]> = .unchanged,
        meta: PatchField<JSONValue> = .unchanged
    ) throws -> SessionUpdate {
        try stable(
            .compactionUpdate(
                Unstable.CompactionUpdate(
                    compactionId: compactionId,
                    status: status,
                    error: error,
                    summary: summary,
                    meta: meta
                )
            )
        )
    }

    /// Makes a stable `compaction_summary_chunk` for the compaction of these
    /// tests.
    ///
    /// - Parameters:
    ///   - text: The text of the content block.
    ///   - meta: The `_meta` of the chunk.
    /// - Returns: The stable session update.
    /// - Throws: An error when the payload does not encode.
    private static func summaryChunk(_ text: String, meta: JSONValue? = nil) throws -> SessionUpdate {
        try stable(
            .compactionSummaryChunk(
                Unstable.CompactionSummaryChunk(compactionId: compactionId, content: Fixtures.text(text), meta: meta)
            )
        )
    }

    /// Reads the compaction entry of these tests.
    ///
    /// - Parameter engine: The engine to read.
    /// - Returns: The compaction.
    /// - Throws: An error when the entry is missing or is not a compaction.
    private static func compaction(in engine: SessionMergeEngine) throws -> SessionEntry.Compaction {
        try #require(try Fixtures.entry(.compaction(compactionId), in: engine).kind.compaction)
    }

    // MARK: - Compaction updates

    @Test func aFirstCompactionUpdateAddsACompactionEntryAtTheEnd() throws {
        var engine = SessionMergeEngine()
        engine.apply(.userMessage(UserMessage(messageId: Fixtures.messageId)))
        let change = engine.apply(try Self.compactionUpdate(.inProgress))
        let expected = SessionEntry(
            id: .compaction(Self.compactionId),
            kind: .compaction(SessionEntry.Compaction(compactionId: Self.compactionId, status: .inProgress))
        )
        #expect(change == .entryAdded(index: 1, entry: expected))
        #expect(engine.entries.last == expected)
    }

    @Test func aLaterCompactionUpdatePatchesTheEntry() throws {
        var engine = SessionMergeEngine()
        engine.apply(try Self.compactionUpdate(.inProgress, meta: .value(Fixtures.traceMeta)))
        let change = engine.apply(try Self.compactionUpdate(.completed, summary: .value([Fixtures.text("short")])))
        let compaction = try Self.compaction(in: engine)
        #expect(compaction.status == .completed)
        #expect(compaction.summary == [Fixtures.text("short")])
        #expect(compaction.meta == .value(Fixtures.traceMeta))
        #expect(change == .entryChanged(index: 0, entry: try Fixtures.entry(.compaction(Self.compactionId), in: engine)))
    }

    @Test func aCompactionErrorFoldsWithThePatchRules() throws {
        var engine = SessionMergeEngine()
        engine.apply(try Self.compactionUpdate(.failed, error: .value("Model refused")))
        engine.apply(try Self.compactionUpdate(.failed))
        #expect(try Self.compaction(in: engine).error == .value("Model refused"))

        engine.apply(try Self.compactionUpdate(.inProgress, error: .cleared))
        #expect(try Self.compaction(in: engine).error == .cleared)
    }

    @Test func anEmptySummaryClearsTheSummary() throws {
        var engine = SessionMergeEngine()
        engine.apply(try Self.compactionUpdate(.completed, summary: .value([Fixtures.text("old")])))
        engine.apply(try Self.compactionUpdate(.completed, summary: .value([])))
        #expect(try Self.compaction(in: engine).summary.isEmpty)
    }

    @Test func aNullSummaryClearsTheSummary() throws {
        var engine = SessionMergeEngine()
        engine.apply(try Self.compactionUpdate(.completed, summary: .value([Fixtures.text("old")])))
        engine.apply(try Self.compactionUpdate(.completed, summary: .cleared))
        #expect(try Self.compaction(in: engine).summary.isEmpty)
    }

    // MARK: - Summary chunks

    @Test func summaryChunksAppendToTheSummary() throws {
        var engine = SessionMergeEngine()
        engine.apply(try Self.compactionUpdate(.inProgress))
        engine.apply(try Self.summaryChunk("one"))
        let change = engine.apply(try Self.summaryChunk("two", meta: Fixtures.traceMeta))
        let compaction = try Self.compaction(in: engine)
        #expect(compaction.summary == [Fixtures.text("one"), Fixtures.text("two")])
        #expect(compaction.meta == .value(Fixtures.traceMeta))
        #expect(change == .entryChanged(index: 0, entry: try Fixtures.entry(.compaction(Self.compactionId), in: engine)))
    }

    @Test func aSummaryChunkBeforeAnyUpdateCreatesTheEntryWithAnUnreportedStatus() throws {
        var engine = SessionMergeEngine()
        let change = engine.apply(try Self.summaryChunk("early"))
        let expected = SessionEntry(
            id: .compaction(Self.compactionId),
            kind: .compaction(
                SessionEntry.Compaction(
                    compactionId: Self.compactionId,
                    status: SessionEntry.Compaction.unreportedStatus,
                    summary: [Fixtures.text("early")]
                )
            )
        )
        #expect(change == .entryAdded(index: 0, entry: expected))

        engine.apply(try Self.compactionUpdate(.completed))
        let compaction = try Self.compaction(in: engine)
        #expect(compaction.status == .completed)
        #expect(compaction.summary == [Fixtures.text("early")])
    }

    // MARK: - The full history stays

    @Test func aCompactionDoesNotChangeEarlierEntries() throws {
        var engine = SessionMergeEngine()
        engine.apply(.userMessage(UserMessage(messageId: Fixtures.messageId, content: .value([Fixtures.text("hi")]))))
        engine.apply(.agentMessageChunk(ContentChunk(content: Fixtures.text("ok"), messageId: Fixtures.otherMessageId)))
        engine.apply(.toolCallUpdate(ToolCallUpdate(toolCallId: Fixtures.toolCallId, title: .value("List"))))
        let before = engine.entries

        engine.apply(try Self.compactionUpdate(.inProgress))
        engine.apply(try Self.summaryChunk("summary"))
        engine.apply(try Self.compactionUpdate(.completed))

        #expect(Array(engine.entries.prefix(before.count)) == before)
        #expect(engine.entries.count == before.count + 1)
    }

    @Test func aCompactionKeepsItsPositionWhenLaterEntriesArrive() throws {
        var engine = SessionMergeEngine()
        engine.apply(try Self.compactionUpdate(.inProgress))
        engine.apply(.userMessage(UserMessage(messageId: Fixtures.messageId)))
        let change = engine.apply(try Self.compactionUpdate(.completed))
        #expect(engine.entries.map(\.id) == [.compaction(Self.compactionId), .userMessage(Fixtures.messageId)])
        #expect(change == .entryChanged(index: 0, entry: try Fixtures.entry(.compaction(Self.compactionId), in: engine)))
    }

    @Test func theTranscriptReplaysACompactionAsOneUpdateWithItsFinalState() throws {
        var engine = SessionMergeEngine()
        engine.apply(.userMessage(UserMessage(messageId: Fixtures.messageId)))
        engine.apply(try Self.compactionUpdate(.inProgress))
        engine.apply(try Self.summaryChunk("one"))
        engine.apply(try Self.summaryChunk("two"))
        engine.apply(try Self.compactionUpdate(.completed))

        let transcript = engine.transcriptUpdates
        let expected = Unstable.CompactionUpdate(
            compactionId: Self.compactionId,
            status: .completed,
            summary: .value([Fixtures.text("one"), Fixtures.text("two")])
        )
        #expect(transcript.count == engine.entries.count)
        #expect(try Unstable.SessionUpdate(transcript[1]) == .compactionUpdate(expected))
    }

    @Test func theReplayOfAnUnreportedCompactionSendsAnExtensionStatus() throws {
        var engine = SessionMergeEngine()
        engine.apply(try Self.summaryChunk("early"))
        // The schema keeps a status that does not begin with `_` for future
        // ACP statuses, so the engine must send an extension value.
        let expected = Unstable.CompactionUpdate(
            compactionId: Self.compactionId,
            status: .unknown("_unreported"),
            summary: .value([Fixtures.text("early")])
        )
        let payload = try JSONValue.encode(result: expected)
        #expect(engine.transcriptUpdates == [.unknown("compaction_update", payload)])
    }

    // MARK: - Malformed payloads

    @Test func aMalformedCompactionUpdateStaysAnUnknownEntry() throws {
        // The payload has no `compactionId`, so it does not decode.
        let payload = JSONValue.object(["status": .string("completed")])
        var engine = SessionMergeEngine()
        let change = engine.apply(.unknown("compaction_update", payload))
        let entry = try #require(engine.entries.first)
        #expect(entry.kind == .unknown(type: "compaction_update", payload: payload))
        #expect(change == .entryAdded(index: 0, entry: entry))
    }

    // MARK: - Notices

    @Test func aNoticeIsReturnedAndIsNotStored() throws {
        var engine = SessionMergeEngine()
        let change = engine.apply(try Self.stable(.notice(Self.notice)))
        #expect(change == .notice(Self.notice))
        #expect(engine == SessionMergeEngine())
    }

    @Test func aNoticeIsNotReplayed() throws {
        var engine = SessionMergeEngine()
        engine.apply(.userMessage(UserMessage(messageId: Fixtures.messageId)))
        engine.apply(try Self.stable(.notice(Self.notice)))
        #expect(engine.entries.map(\.id) == [.userMessage(Fixtures.messageId)])
        #expect(engine.transcriptUpdates.count == 1)
        #expect(engine.stateUpdates.isEmpty)
    }
}
