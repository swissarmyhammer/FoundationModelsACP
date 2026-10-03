import Foundation
import Testing

@testable import FoundationModelsACP

/// `Unstable.SessionUpdate`: the typed view of the unstable session updates.
///
/// The stable `SessionUpdate` enum has no case for an unstable update, so a
/// `compaction_update`, `compaction_summary_chunk` or `notice` decodes as
/// `SessionUpdate.unknown(type, payload)`. The view reads that case, and it
/// encodes back to the same stable case for an agent to send.
@Suite struct UnstableSessionUpdateTests {
    /// The session that the end-to-end test uses.
    private static let sessionId = SessionId(rawValue: "session-unstable")

    /// The wire payload of a completed compaction, without the
    /// `sessionUpdate` member.
    private static let compactionPayload = #"""
        {"compactionId":"compaction-1","status":"completed",
         "summary":[{"type":"text","text":"Earlier turns set up the build."}]}
        """#

    /// The wire payload of one summary chunk.
    private static let chunkPayload = #"{"compactionId":"compaction-1","content":{"type":"text","text":"More."}}"#

    /// The wire payload of one notice.
    private static let noticePayload = #"{"severity":"info","title":"Context compacted"}"#

    /// The typed compaction that `compactionPayload` holds.
    private static let compaction = Unstable.CompactionUpdate(
        compactionId: Unstable.CompactionId(rawValue: "compaction-1"),
        status: .completed,
        summary: .value([.text(TextContent(text: "Earlier turns set up the build."))])
    )

    @Test func readsACompactionUpdateFromTheStableUnknownCase() throws {
        let stable = SessionUpdate.unknown("compaction_update", try WireRoundTrip.parse(Self.compactionPayload))
        #expect(try Unstable.SessionUpdate(stable) == .compactionUpdate(Self.compaction))
    }

    @Test func readsACompactionSummaryChunkFromTheStableUnknownCase() throws {
        let stable = SessionUpdate.unknown("compaction_summary_chunk", try WireRoundTrip.parse(Self.chunkPayload))
        let expected = Unstable.CompactionSummaryChunk(
            compactionId: Unstable.CompactionId(rawValue: "compaction-1"),
            content: .text(TextContent(text: "More."))
        )
        #expect(try Unstable.SessionUpdate(stable) == .compactionSummaryChunk(expected))
    }

    @Test func readsANoticeFromTheStableUnknownCase() throws {
        let stable = SessionUpdate.unknown("notice", try WireRoundTrip.parse(Self.noticePayload))
        #expect(try Unstable.SessionUpdate(stable) == .notice(Unstable.Notice(severity: .info, title: "Context compacted")))
    }

    @Test func returnsNilForAStableUpdate() throws {
        let stable = SessionUpdate.agentMessageChunk(
            ContentChunk(content: .text(TextContent(text: "hi")), messageId: MessageId(rawValue: "m1"))
        )
        #expect(try Unstable.SessionUpdate(stable) == nil)
    }

    @Test func returnsNilForAnUnknownTypeThatIsNotAnUnstableUpdate() throws {
        let stable = SessionUpdate.unknown("_vendor_progress", try WireRoundTrip.parse(Self.noticePayload))
        #expect(try Unstable.SessionUpdate(stable) == nil)
    }

    @Test func throwsForAMalformedPayloadOfAnUnstableType() throws {
        let stable = SessionUpdate.unknown("notice", try WireRoundTrip.parse(#"{"title":"No severity"}"#))
        #expect(throws: DecodingError.self) { try Unstable.SessionUpdate(stable) }
    }

    @Test func encodesBackToTheStableUnknownCase() throws {
        let stable = try SessionUpdate(.compactionUpdate(Self.compaction))
        #expect(stable == .unknown("compaction_update", try WireRoundTrip.parse(Self.compactionPayload)))
    }

    @Test func encodesTheDiscriminatorOnTheWire() throws {
        let wire = try WireRoundTrip.encode(try SessionUpdate(.notice(Unstable.Notice(severity: .warning, title: "Low"))))
        #expect(wire == (try WireRoundTrip.parse(#"{"sessionUpdate":"notice","severity":"warning","title":"Low"}"#)))
    }

    @Test(arguments: [
        Unstable.SessionUpdate.compactionUpdate(compaction),
        .compactionSummaryChunk(
            Unstable.CompactionSummaryChunk(
                compactionId: Unstable.CompactionId(rawValue: "compaction-2"),
                content: .text(TextContent(text: "Part."))
            )
        ),
        .notice(Unstable.Notice(severity: .unknown("_vendor_hint"), title: "Hint", description: "Detail")),
    ])
    func everyCaseRoundTripsThroughTheStableWireForm(update: Unstable.SessionUpdate) throws {
        let wire = try JSONEncoder().encode(try SessionUpdate(update))
        let decoded = try JSONDecoder().decode(SessionUpdate.self, from: wire)
        #expect(try Unstable.SessionUpdate(decoded) == update)
    }

    @Test(.timeLimit(.minutes(1)))
    func aCompactionUpdateSentAsASessionUpdateReachesThePeer() async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agent = await Connection(transport: agentEnd)
        let client = await ClientSideConnection(stream: clientEnd) { _ in HandshakeClient() }
        var updates = client.subscribe(to: Self.sessionId).updates.makeAsyncIterator()

        let notification = UpdateSessionNotification(
            sessionId: Self.sessionId,
            update: try SessionUpdate(.compactionUpdate(Self.compaction))
        )
        try await agent.notify(method: "session/update", params: try JSONValue.encode(result: notification))

        let received = try #require(await updates.next())
        #expect(try Unstable.SessionUpdate(received) == .compactionUpdate(Self.compaction))

        await client.close()
        await agent.close()
    }
}
