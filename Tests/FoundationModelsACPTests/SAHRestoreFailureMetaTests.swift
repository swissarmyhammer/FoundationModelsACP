import Foundation
import Testing

@testable import FoundationModelsACP

/// `SAH.RestoreFailure` in `_meta.sah.restoreFailure`: the reason that a
/// child session did not restore.
@Suite struct SAHRestoreFailureMetaTests {
    private static let child = SessionId(rawValue: "child-1")

    @Test func theMetaKeyIsRestoreFailure() {
        #expect(SAH.RestoreFailure.metaKey == "restoreFailure")
    }

    @Test func theReasonRoundTrips() throws {
        let failure = try WireRoundTrip.expectLossless(SAH.RestoreFailure.self, #"{"reason":"an ancestor was not restored"}"#)
        #expect(failure == SAH.RestoreFailure(reason: "an ancestor was not restored"))
    }

    @Test func aSubagentUpdateCarriesTheFailureInItsMeta() throws {
        let failure = SAH.RestoreFailure(reason: "the session file is missing")
        let meta = try failure.inject(into: nil)
        #expect(meta == .object(["sah": .object(["restoreFailure": .object(["reason": .string("the session file is missing")])])]))
        let decoded = try WireRoundTrip.expectLossless(SessionUpdate.self, """
            {"sessionUpdate":"subagent_update","sessionId":"child-1","state":{"state":"unknown"},\
            "_meta":{"sah":{"restoreFailure":{"reason":"the session file is missing"}}}}
            """)
        guard case .subagentUpdate(let received) = decoded, case .value(let receivedMeta) = received.meta else {
            Issue.record("expected a subagent_update with _meta")
            return
        }
        #expect(received.sessionId == Self.child)
        #expect(SAH.RestoreFailure.extract(from: receivedMeta) == failure)
    }

    @Test func injectKeepsOtherSAHMembersAndOtherMetaKeys() throws {
        let existing = try WireRoundTrip.parse(#"{"vendor.example/x":1,"sah":{"agentRun":{"sessionId":"child-1"},"future":true}}"#)
        let merged = try SAH.RestoreFailure(reason: "r").inject(into: existing)
        #expect(merged == (try WireRoundTrip.parse("""
            {"vendor.example/x":1,"sah":{"agentRun":{"sessionId":"child-1"},"future":true,"restoreFailure":{"reason":"r"}}}
            """)))
        #expect(SAH.AgentRun.extract(from: merged) != nil)
    }

    @Test func injectReplacesAnEarlierFailure() throws {
        let first = try SAH.RestoreFailure(reason: "a").inject(into: nil)
        let second = try SAH.RestoreFailure(reason: "b").inject(into: first)
        #expect(SAH.RestoreFailure.extract(from: second) == SAH.RestoreFailure(reason: "b"))
    }

    @Test func aMissingPayloadGivesNil() throws {
        #expect(SAH.RestoreFailure.extract(from: nil) == nil)
        #expect(SAH.RestoreFailure.extract(from: try WireRoundTrip.parse(#"{"sah":{}}"#)) == nil)
    }

    @Test func aMalformedPayloadGivesNil() throws {
        #expect(SAH.RestoreFailure.extract(from: try WireRoundTrip.parse(#"{"sah":{"restoreFailure":{}}}"#)) == nil)
        #expect(SAH.RestoreFailure.extract(from: try WireRoundTrip.parse(#"{"sah":{"restoreFailure":{"reason":5}}}"#)) == nil)
        #expect(SAH.RestoreFailure.extract(from: try WireRoundTrip.parse(#"{"sah":{"restoreFailure":"x"}}"#)) == nil)
    }
}
