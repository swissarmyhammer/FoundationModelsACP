import Foundation
import Testing

@testable import FoundationModelsACP

/// `SAH.AgentRun` in `_meta.sah.agentRun`: the link between an `agents` tool
/// call and its child session.
@Suite struct SAHAgentRunMetaTests {
    private static let child = SessionId(rawValue: "child-1")
    private static let toolCall = ToolCallId(rawValue: "call-7")

    @Test func bothMembersAreOptional() throws {
        let empty = try WireRoundTrip.expectLossless(SAH.AgentRun.self, "{}")
        #expect(empty == SAH.AgentRun())
        let toolCallOnly = try WireRoundTrip.expectLossless(SAH.AgentRun.self, #"{"toolCallId":"call-7"}"#)
        #expect(toolCallOnly == SAH.AgentRun(toolCallId: Self.toolCall))
        let sessionOnly = try WireRoundTrip.expectLossless(SAH.AgentRun.self, #"{"sessionId":"child-1"}"#)
        #expect(sessionOnly == SAH.AgentRun(sessionId: Self.child))
    }

    @Test func theMetaKeyIsAgentRun() {
        #expect(SAH.AgentRun.metaKey == "agentRun")
    }

    @Test func aSubagentUpdateCarriesTheToolCallIdInItsMeta() throws {
        let run = SAH.AgentRun(toolCallId: Self.toolCall)
        let meta = try run.inject(into: nil)
        #expect(meta == .object(["sah": .object(["agentRun": .object(["toolCallId": .string("call-7")])])]))
        let update = SubagentUpdate(sessionId: Self.child, meta: .value(meta))
        let decoded = try WireRoundTrip.expectLossless(SessionUpdate.self, """
            {"sessionUpdate":"subagent_update","sessionId":"child-1","_meta":{"sah":{"agentRun":{"toolCallId":"call-7"}}}}
            """)
        #expect(decoded == .subagentUpdate(update))
        guard case .subagentUpdate(let received) = decoded, case .value(let receivedMeta) = received.meta else {
            Issue.record("expected a subagent_update with _meta")
            return
        }
        #expect(SAH.AgentRun.extract(from: receivedMeta) == run)
    }

    @Test func aToolCallCarriesTheChildSessionIdInItsMeta() throws {
        let run = SAH.AgentRun(sessionId: Self.child)
        let update = ToolCallUpdate(toolCallId: Self.toolCall, meta: .value(try run.inject(into: nil)))
        let wire = try WireRoundTrip.encode(update)
        let decoded = try WireRoundTrip.decode(ToolCallUpdate.self, from: String(decoding: JSONEncoder().encode(wire), as: UTF8.self))
        guard case .value(let meta) = decoded.meta else {
            Issue.record("expected _meta")
            return
        }
        #expect(SAH.AgentRun.extract(from: meta) == run)
    }

    @Test func injectKeepsOtherSAHMembersAndOtherMetaKeys() throws {
        let existing = try WireRoundTrip.parse("""
            {"vendor.example/x":1,"sah":{"message":{"sender":{"kind":"user"}},"future":true}}
            """)
        let merged = try SAH.AgentRun(sessionId: Self.child).inject(into: existing)
        #expect(merged == (try WireRoundTrip.parse("""
            {"vendor.example/x":1,"sah":{"message":{"sender":{"kind":"user"}},"future":true,"agentRun":{"sessionId":"child-1"}}}
            """)))
        #expect(SAH.SessionMessage.extract(from: merged) != nil)
    }

    @Test func injectReplacesAnEarlierAgentRun() throws {
        let first = try SAH.AgentRun(toolCallId: Self.toolCall).inject(into: nil)
        let second = try SAH.AgentRun(sessionId: Self.child).inject(into: first)
        #expect(SAH.AgentRun.extract(from: second) == SAH.AgentRun(sessionId: Self.child))
    }

    @Test func anUnknownMemberOfThePayloadDoesNotStopTheRead() throws {
        let meta = try WireRoundTrip.parse(#"{"sah":{"agentRun":{"toolCallId":"call-7","later":1}}}"#)
        #expect(SAH.AgentRun.extract(from: meta) == SAH.AgentRun(toolCallId: Self.toolCall))
    }

    @Test func aMissingPayloadGivesNil() throws {
        #expect(SAH.AgentRun.extract(from: nil) == nil)
        #expect(SAH.AgentRun.extract(from: .object([:])) == nil)
        #expect(SAH.AgentRun.extract(from: try WireRoundTrip.parse(#"{"sah":{}}"#)) == nil)
    }

    @Test func aMalformedPayloadGivesNilAndDoesNotThrow() throws {
        #expect(SAH.AgentRun.extract(from: try WireRoundTrip.parse(#"{"sah":{"agentRun":"x"}}"#)) == nil)
        #expect(SAH.AgentRun.extract(from: try WireRoundTrip.parse(#"{"sah":{"agentRun":{"toolCallId":5}}}"#)) == nil)
        #expect(SAH.AgentRun.extract(from: try WireRoundTrip.parse(#"{"sah":"x"}"#)) == nil)
    }
}
