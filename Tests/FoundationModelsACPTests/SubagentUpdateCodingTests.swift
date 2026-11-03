import Foundation
import Testing

@testable import FoundationModelsACP

/// The unstable `subagent_update` session update and the `subagent` entry of
/// the `background` list (ACP v2 "Subagent Sessions" and "Background Work").
@Suite struct SubagentUpdateCodingTests {
    private static let child = SessionId(rawValue: "child-1")

    @Test func aSubagentUpdateWithOnlyASessionIdLeavesEveryFieldUnchanged() throws {
        let update = try WireRoundTrip.expectLossless(SessionUpdate.self, """
            {"sessionUpdate":"subagent_update","sessionId":"child-1"}
            """)
        #expect(update == .subagentUpdate(SubagentUpdate(sessionId: Self.child)))
    }

    @Test func omittedNullAndConcreteFieldsStayApart() throws {
        let update = try WireRoundTrip.expectLossless(SubagentUpdate.self, """
            {"sessionId":"child-1","title":"Researcher","description":null,"cwd":"/work"}
            """)
        #expect(update.title == .value("Researcher"))
        #expect(update.description == .cleared)
        #expect(update.cwd == .value(AbsolutePath(rawValue: "/work")))
        #expect(update.state == .unchanged)
        #expect(update.capabilities == .unchanged)
        #expect(update.additionalDirectories == .unchanged)
    }

    @Test func aStateSnapshotAndCapabilitiesRoundTrip() throws {
        let update = try WireRoundTrip.expectLossless(SubagentUpdate.self, """
            {"sessionId":"child-1","state":{"state":"running"},"capabilities":{"cancel":{}}}
            """)
        #expect(update.state == .value(.running(RunningStateUpdate())))
        #expect(update.capabilities == .value(SubagentSessionCapabilities(cancel: SessionCancelCapabilities())))
    }

    @Test func aNullStateRemovesTheStateReport() throws {
        let update = try WireRoundTrip.decode(SubagentUpdate.self, from: #"{"sessionId":"child-1","state":null}"#)
        #expect(update.state == .cleared)
        #expect(try WireRoundTrip.encode(update) == (try WireRoundTrip.parse(#"{"sessionId":"child-1","state":null}"#)))
    }

    @Test func aCapabilitiesKeyThatThisRevisionDoesNotKnowIsKeptInMeta() throws {
        // The capabilities object has its own `_meta`; a member that is not
        // declared is not a field, so only `_meta` carries extensions.
        let update = try WireRoundTrip.expectLossless(SubagentUpdate.self, """
            {"sessionId":"child-1","capabilities":{"cancel":{},"_meta":{"vendor.example/x":1}}}
            """)
        guard case .value(let capabilities) = update.capabilities else {
            Issue.record("expected capabilities")
            return
        }
        #expect(capabilities.meta == .object(["vendor.example/x": .number(1)]))
    }

    @Test func aSubagentEntryOfTheBackgroundListDecodes() throws {
        let running = try WireRoundTrip.expectLossless(RunningStateUpdate.self, """
            {"background":[{"type":"subagent","sessionId":"child-1"},{"type":"terminal","terminalId":"t-1"}]}
            """)
        let background = try #require(running.background)
        #expect(background.first == .subagent(BackgroundSubagent(sessionId: Self.child)))
        #expect(background.count == 2)
    }
}
