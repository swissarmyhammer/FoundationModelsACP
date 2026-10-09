import Foundation
import Testing

@testable import FoundationModelsACP

/// Wire round trips of the generated compaction and notice types.
///
/// Each type decodes from a wire literal and encodes back to the same JSON.
/// The suite also pins the patch semantics of `CompactionUpdate`: omitted,
/// `null`, `[]` and a value are four different wire states of `summary`.
@Suite struct CompactionNoticeRoundTripTests {
    /// The compaction that the fixtures name.
    private static let compactionId = CompactionId(rawValue: "compaction-1")

    /// One text block of a retained summary.
    private static let summaryBlock = ContentBlock.text(TextContent(text: "Earlier turns set up the build."))

    @Test func compactionIdRoundTripsAsABareString() throws {
        let decoded = try WireRoundTrip.expectLossless(CompactionId.self, #""compaction-1""#)
        #expect(decoded == Self.compactionId)
    }

    @Test(arguments: [
        ("in_progress", CompactionStatus.inProgress),
        ("completed", .completed),
        ("failed", .failed),
        ("cancelled", .cancelled),
    ])
    func knownCompactionStatusRoundTrips(wireValue: String, status: CompactionStatus) throws {
        #expect(try WireRoundTrip.expectLossless(CompactionStatus.self, "\"\(wireValue)\"") == status)
    }

    @Test func unknownCompactionStatusIsKeptAndReEncoded() throws {
        let decoded = try WireRoundTrip.expectLossless(CompactionStatus.self, #""_vendor_paused""#)
        #expect(decoded == .unknown("_vendor_paused"))
    }

    @Test(arguments: [
        ("info", NoticeSeverity.info),
        ("warning", .warning),
        ("error", .error),
    ])
    func knownNoticeSeverityRoundTrips(wireValue: String, severity: NoticeSeverity) throws {
        #expect(try WireRoundTrip.expectLossless(NoticeSeverity.self, "\"\(wireValue)\"") == severity)
    }

    @Test func unknownNoticeSeverityIsKeptAndReEncoded() throws {
        let decoded = try WireRoundTrip.expectLossless(NoticeSeverity.self, #""critical""#)
        #expect(decoded == .unknown("critical"))
    }

    @Test func compactionUpdateWithAnOmittedSummaryLeavesTheSummaryUnchanged() throws {
        let decoded = try WireRoundTrip.expectLossless(
            CompactionUpdate.self,
            #"{"compactionId":"compaction-1","status":"in_progress"}"#
        )
        #expect(decoded == CompactionUpdate(compactionId: Self.compactionId, status: .inProgress))
        #expect(decoded.summary == .unchanged)
        #expect(decoded.error == .unchanged)
        #expect(decoded.meta == .unchanged)
    }

    @Test func compactionUpdateWithANullSummaryClearsTheSummary() throws {
        let decoded = try WireRoundTrip.expectLossless(
            CompactionUpdate.self,
            #"{"compactionId":"compaction-1","status":"cancelled","summary":null,"error":null,"_meta":null}"#
        )
        #expect(decoded.summary == .cleared)
        #expect(decoded.error == .cleared)
        #expect(decoded.meta == .cleared)
    }

    @Test func compactionUpdateWithAnEmptySummaryCarriesTheEmptyArray() throws {
        // `summary: []` also clears the retained summary, but it is a value
        // on the wire, different from `null`, and it must encode back as `[]`.
        let decoded = try WireRoundTrip.expectLossless(
            CompactionUpdate.self,
            #"{"compactionId":"compaction-1","status":"completed","summary":[]}"#
        )
        #expect(decoded.summary == .value([]))
        #expect(decoded.summary.resolved(onto: [Self.summaryBlock]).isEmpty)
    }

    @Test func compactionUpdateWithASummaryReplacesTheSummary() throws {
        let decoded = try WireRoundTrip.expectLossless(
            CompactionUpdate.self,
            #"""
            {"compactionId":"compaction-1","status":"completed",
             "summary":[{"type":"text","text":"Earlier turns set up the build."}],
             "_meta":{"vendor":{"tokensSaved":1200}}}
            """#
        )
        #expect(decoded.summary == .value([Self.summaryBlock]))
        #expect(decoded.meta == .value(.object(["vendor": .object(["tokensSaved": .number(1200)])])))
    }

    @Test func failedCompactionUpdateCarriesTheError() throws {
        let decoded = try WireRoundTrip.expectLossless(
            CompactionUpdate.self,
            #"{"compactionId":"compaction-1","status":"failed","error":"The model context was too small."}"#
        )
        #expect(decoded.status == .failed)
        #expect(decoded.error == .value("The model context was too small."))
    }

    @Test func foldingAnUpdateThatOmitsTheSummaryKeepsTheEarlierSummary() {
        let earlier = CompactionUpdate(
            compactionId: Self.compactionId,
            status: .completed,
            summary: .value([Self.summaryBlock])
        )
        let later = CompactionUpdate(compactionId: Self.compactionId, status: .completed, meta: .value(.null))
        let folded = later.folded(onto: earlier)
        #expect(folded.summary == .value([Self.summaryBlock]))
        #expect(folded.meta == .value(.null))
    }

    @Test func foldingAnUpdateWithANullSummaryClearsTheEarlierSummary() {
        let earlier = CompactionUpdate(
            compactionId: Self.compactionId,
            status: .completed,
            summary: .value([Self.summaryBlock])
        )
        let later = CompactionUpdate(compactionId: Self.compactionId, status: .failed, summary: .cleared)
        let folded = later.folded(onto: earlier)
        #expect(folded.summary == .cleared)
        #expect(folded.status == .failed)
    }

    @Test func foldingAnUpdateWithAnEmptySummaryReplacesTheEarlierSummary() {
        let earlier = CompactionUpdate(
            compactionId: Self.compactionId,
            status: .completed,
            summary: .value([Self.summaryBlock])
        )
        let later = CompactionUpdate(compactionId: Self.compactionId, status: .completed, summary: .value([]))
        #expect(later.folded(onto: earlier).summary == .value([]))
    }

    @Test func compactionSummaryChunkRoundTrips() throws {
        let decoded = try WireRoundTrip.expectLossless(
            CompactionSummaryChunk.self,
            #"{"compactionId":"compaction-1","content":{"type":"text","text":"Earlier turns set up the build."}}"#
        )
        #expect(decoded == CompactionSummaryChunk(compactionId: Self.compactionId, content: Self.summaryBlock))
    }

    @Test func compactionSummaryChunkReadsANullMetaAsAbsent() throws {
        let decoded = try WireRoundTrip.decode(
            CompactionSummaryChunk.self,
            from: #"{"compactionId":"compaction-1","content":{"type":"text","text":"x"},"_meta":null}"#
        )
        #expect(decoded.meta == nil)
    }

    @Test func noticeRoundTrips() throws {
        let decoded = try WireRoundTrip.expectLossless(
            Notice.self,
            #"{"severity":"warning","title":"Context is almost full","description":"Older turns will be compacted."}"#
        )
        #expect(
            decoded == Notice(
                severity: .warning,
                title: "Context is almost full",
                description: "Older turns will be compacted."
            )
        )
    }

    @Test func noticeReadsANullDescriptionAsAbsent() throws {
        let decoded = try WireRoundTrip.decode(
            Notice.self,
            from: #"{"severity":"info","title":"Saved","description":null}"#
        )
        #expect(decoded.description == nil)
    }
}
