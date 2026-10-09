import Foundation
import Testing

@testable import FoundationModelsACP

/// The compaction and notice session updates on the stable `SessionUpdate`.
///
/// Upstream made `compaction_update`, `compaction_summary_chunk` and `notice`
/// stable in `schema-v2.0.0-alpha.8`. Each one decodes as its own typed case,
/// not as `SessionUpdate.unknown`, and encodes back to the same wire object.
@Suite struct CompactionNoticeSessionUpdateTests {
    /// The session that the end-to-end test uses.
    private static let sessionId = SessionId(rawValue: "session-compaction")

    /// The wire object of a completed compaction.
    private static let compactionWire = #"""
        {"sessionUpdate":"compaction_update","compactionId":"compaction-1","status":"completed",
         "summary":[{"type":"text","text":"Earlier turns set up the build."}]}
        """#

    /// The typed compaction that `compactionWire` holds.
    private static let compaction = CompactionUpdate(
        compactionId: CompactionId(rawValue: "compaction-1"),
        status: .completed,
        summary: .value([.text(TextContent(text: "Earlier turns set up the build."))])
    )

    @Test func compactionUpdateDecodesAsItsOwnCase() throws {
        let decoded = try WireRoundTrip.expectLossless(SessionUpdate.self, Self.compactionWire)
        #expect(decoded == .compactionUpdate(Self.compaction))
    }

    @Test func compactionSummaryChunkDecodesAsItsOwnCase() throws {
        let decoded = try WireRoundTrip.expectLossless(
            SessionUpdate.self,
            #"{"sessionUpdate":"compaction_summary_chunk","compactionId":"compaction-1","content":{"type":"text","text":"More."}}"#
        )
        let expected = CompactionSummaryChunk(
            compactionId: CompactionId(rawValue: "compaction-1"),
            content: .text(TextContent(text: "More."))
        )
        #expect(decoded == .compactionSummaryChunk(expected))
    }

    @Test func noticeDecodesAsItsOwnCase() throws {
        let decoded = try WireRoundTrip.expectLossless(
            SessionUpdate.self,
            #"{"sessionUpdate":"notice","severity":"warning","title":"Low"}"#
        )
        #expect(decoded == .notice(Notice(severity: .warning, title: "Low")))
    }

    @Test func malformedNoticePayloadFailsToDecode() throws {
        // `severity` is required. A known tag with a payload that does not
        // decode is a decode error, as for each other stable variant.
        #expect(throws: DecodingError.self) {
            try WireRoundTrip.decode(SessionUpdate.self, from: #"{"sessionUpdate":"notice","title":"No severity"}"#)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aCompactionUpdateSentAsASessionUpdateReachesThePeer() async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agent = await Connection(transport: agentEnd)
        let client = await ClientSideConnection(stream: clientEnd) { _ in HandshakeClient() }
        var updates = client.subscribe(to: Self.sessionId).updates.makeAsyncIterator()

        let notification = UpdateSessionNotification(sessionId: Self.sessionId, update: .compactionUpdate(Self.compaction))
        try await agent.notify(method: "session/update", params: try JSONValue.encode(result: notification))

        let received = try #require(await updates.nextUpdate())
        #expect(received == .compactionUpdate(Self.compaction))

        await client.close()
        await agent.close()
    }
}
