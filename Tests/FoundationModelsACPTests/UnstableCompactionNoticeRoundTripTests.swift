import Foundation
import Testing

@testable import FoundationModelsACP

/// Wire round trips of the generated unstable compaction and notice types.
///
/// Each type decodes from a wire literal and encodes back to the same JSON.
/// The suite also pins the patch semantics of `CompactionUpdate`: omitted,
/// `null`, `[]` and a value are four different wire states of `summary`.
@Suite struct UnstableCompactionNoticeRoundTripTests {
    /// The compaction that the fixtures name.
    private static let compactionId = Unstable.CompactionId(rawValue: "compaction-1")

    /// One text block of a retained summary.
    private static let summaryBlock = ContentBlock.text(TextContent(text: "Earlier turns set up the build."))

    @Test func compactionIdRoundTripsAsABareString() throws {
        let decoded = try WireRoundTrip.expectLossless(Unstable.CompactionId.self, #""compaction-1""#)
        #expect(decoded == Self.compactionId)
    }

    @Test(arguments: [
        ("in_progress", Unstable.CompactionStatus.inProgress),
        ("completed", .completed),
        ("failed", .failed),
        ("cancelled", .cancelled),
    ])
    func knownCompactionStatusRoundTrips(wireValue: String, status: Unstable.CompactionStatus) throws {
        #expect(try WireRoundTrip.expectLossless(Unstable.CompactionStatus.self, "\"\(wireValue)\"") == status)
    }

    @Test func unknownCompactionStatusIsKeptAndReEncoded() throws {
        let decoded = try WireRoundTrip.expectLossless(Unstable.CompactionStatus.self, #""_vendor_paused""#)
        #expect(decoded == .unknown("_vendor_paused"))
    }

    @Test(arguments: [
        ("info", Unstable.NoticeSeverity.info),
        ("warning", .warning),
        ("error", .error),
    ])
    func knownNoticeSeverityRoundTrips(wireValue: String, severity: Unstable.NoticeSeverity) throws {
        #expect(try WireRoundTrip.expectLossless(Unstable.NoticeSeverity.self, "\"\(wireValue)\"") == severity)
    }

    @Test func unknownNoticeSeverityIsKeptAndReEncoded() throws {
        let decoded = try WireRoundTrip.expectLossless(Unstable.NoticeSeverity.self, #""critical""#)
        #expect(decoded == .unknown("critical"))
    }

    @Test func compactionUpdateWithAnOmittedSummaryLeavesTheSummaryUnchanged() throws {
        let decoded = try WireRoundTrip.expectLossless(
            Unstable.CompactionUpdate.self,
            #"{"compactionId":"compaction-1","status":"in_progress"}"#
        )
        #expect(decoded == Unstable.CompactionUpdate(compactionId: Self.compactionId, status: .inProgress))
        #expect(decoded.summary == .unchanged)
        #expect(decoded.error == .unchanged)
        #expect(decoded.meta == .unchanged)
    }

    @Test func compactionUpdateWithANullSummaryClearsTheSummary() throws {
        let decoded = try WireRoundTrip.expectLossless(
            Unstable.CompactionUpdate.self,
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
            Unstable.CompactionUpdate.self,
            #"{"compactionId":"compaction-1","status":"completed","summary":[]}"#
        )
        #expect(decoded.summary == .value([]))
        #expect(decoded.summary.resolved(onto: [Self.summaryBlock]).isEmpty)
    }

    @Test func compactionUpdateWithASummaryReplacesTheSummary() throws {
        let decoded = try WireRoundTrip.expectLossless(
            Unstable.CompactionUpdate.self,
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
            Unstable.CompactionUpdate.self,
            #"{"compactionId":"compaction-1","status":"failed","error":"The model context was too small."}"#
        )
        #expect(decoded.status == .failed)
        #expect(decoded.error == .value("The model context was too small."))
    }

    @Test func foldingAnUpdateThatOmitsTheSummaryKeepsTheEarlierSummary() {
        let earlier = Unstable.CompactionUpdate(
            compactionId: Self.compactionId,
            status: .completed,
            summary: .value([Self.summaryBlock])
        )
        let later = Unstable.CompactionUpdate(compactionId: Self.compactionId, status: .completed, meta: .value(.null))
        let folded = later.folded(onto: earlier)
        #expect(folded.summary == .value([Self.summaryBlock]))
        #expect(folded.meta == .value(.null))
    }

    @Test func foldingAnUpdateWithANullSummaryClearsTheEarlierSummary() {
        let earlier = Unstable.CompactionUpdate(
            compactionId: Self.compactionId,
            status: .completed,
            summary: .value([Self.summaryBlock])
        )
        let later = Unstable.CompactionUpdate(compactionId: Self.compactionId, status: .failed, summary: .cleared)
        let folded = later.folded(onto: earlier)
        #expect(folded.summary == .cleared)
        #expect(folded.status == .failed)
    }

    @Test func foldingAnUpdateWithAnEmptySummaryReplacesTheEarlierSummary() {
        let earlier = Unstable.CompactionUpdate(
            compactionId: Self.compactionId,
            status: .completed,
            summary: .value([Self.summaryBlock])
        )
        let later = Unstable.CompactionUpdate(compactionId: Self.compactionId, status: .completed, summary: .value([]))
        #expect(later.folded(onto: earlier).summary == .value([]))
    }

    @Test func compactionSummaryChunkRoundTrips() throws {
        let decoded = try WireRoundTrip.expectLossless(
            Unstable.CompactionSummaryChunk.self,
            #"{"compactionId":"compaction-1","content":{"type":"text","text":"Earlier turns set up the build."}}"#
        )
        #expect(decoded == Unstable.CompactionSummaryChunk(compactionId: Self.compactionId, content: Self.summaryBlock))
    }

    @Test func compactionSummaryChunkReadsANullMetaAsAbsent() throws {
        let decoded = try WireRoundTrip.decode(
            Unstable.CompactionSummaryChunk.self,
            from: #"{"compactionId":"compaction-1","content":{"type":"text","text":"x"},"_meta":null}"#
        )
        #expect(decoded.meta == nil)
    }

    @Test func noticeRoundTrips() throws {
        let decoded = try WireRoundTrip.expectLossless(
            Unstable.Notice.self,
            #"{"severity":"warning","title":"Context is almost full","description":"Older turns will be compacted."}"#
        )
        #expect(
            decoded == Unstable.Notice(
                severity: .warning,
                title: "Context is almost full",
                description: "Older turns will be compacted."
            )
        )
    }

    @Test func noticeReadsANullDescriptionAsAbsent() throws {
        let decoded = try WireRoundTrip.decode(
            Unstable.Notice.self,
            from: #"{"severity":"info","title":"Saved","description":null}"#
        )
        #expect(decoded.description == nil)
    }
}
