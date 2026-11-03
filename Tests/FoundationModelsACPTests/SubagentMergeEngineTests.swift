import Foundation
import Testing

@testable import FoundationModelsACP

/// The merge engine keeps the unstable subagent updates and the
/// inter-session messages, so a replay sends them again.
@Suite struct SubagentMergeEngineTests {
    private static let child = SessionId(rawValue: "child-1")
    private static let parent = SessionId(rawValue: "parent")
    private static let messageId = MessageId(rawValue: "m-1")

    private static func text(_ string: String) -> ContentBlock {
        .text(TextContent(text: string))
    }

    @Test func aSubagentUpdateAnnouncesTheChildAndLaterUpdatesFoldOntoIt() {
        var engine = SessionMergeEngine()
        let first = engine.apply(.subagentUpdate(SubagentUpdate(sessionId: Self.child, title: .value("Researcher"))))
        engine.apply(.subagentUpdate(SubagentUpdate(sessionId: Self.child, description: .value("Reads papers"))))
        engine.apply(.subagentUpdate(SubagentUpdate(sessionId: Self.child, title: .cleared)))
        #expect(first == .subagentChanged(SubagentUpdate(sessionId: Self.child, title: .value("Researcher"))))
        #expect(engine.subagents.count == 1)
        #expect(engine.subagents[0].title == .cleared)
        #expect(engine.subagents[0].description == .value("Reads papers"))
    }

    @Test func childrenKeepTheOrderOfTheirFirstAnnouncement() {
        var engine = SessionMergeEngine()
        let other = SessionId(rawValue: "child-2")
        engine.apply(.subagentUpdate(SubagentUpdate(sessionId: Self.child)))
        engine.apply(.subagentUpdate(SubagentUpdate(sessionId: other)))
        engine.apply(.subagentUpdate(SubagentUpdate(sessionId: Self.child, title: .value("T"))))
        #expect(engine.subagents.map(\.sessionId) == [Self.child, other])
    }

    @Test func aSessionMessageUpsertsAndChunksAppend() {
        var engine = SessionMergeEngine()
        engine.apply(.sessionMessageChunk(SessionMessageChunk(content: Self.text("he"), messageId: Self.messageId)))
        engine.apply(.sessionMessageChunk(SessionMessageChunk(content: Self.text("llo"), messageId: Self.messageId)))
        engine.apply(.sessionMessage(SessionMessage(
            messageId: Self.messageId, recipientSessionId: .value(Self.child), senderSessionId: .value(Self.parent))))
        #expect(engine.entries.count == 1)
        guard case .sessionMessage(let message) = engine.entries[0].kind else {
            Issue.record("expected a session message entry")
            return
        }
        #expect(message.content == [Self.text("he"), Self.text("llo")])
        #expect(message.senderSessionId == .value(Self.parent))
        #expect(message.recipientSessionId == .value(Self.child))
        #expect(message.recipientMessageId == .unchanged)
    }

    @Test func aMessageUpsertWithContentReplacesAndNullClears() {
        var engine = SessionMergeEngine()
        engine.apply(.sessionMessage(SessionMessage(messageId: Self.messageId, content: .value([Self.text("a")]))))
        engine.apply(.sessionMessage(SessionMessage(messageId: Self.messageId, content: .value([Self.text("b")]))))
        #expect(engine.entries[0].kind.sessionMessage?.content == [Self.text("b")])
        engine.apply(.sessionMessage(SessionMessage(messageId: Self.messageId, content: .cleared)))
        #expect(engine.entries[0].kind.sessionMessage?.content == [])
    }

    @Test func aReplayInANewEngineGivesTheSameChildrenAndMessages() {
        var engine = SessionMergeEngine()
        engine.apply(.subagentUpdate(SubagentUpdate(sessionId: Self.child, state: .value(.running(RunningStateUpdate())), title: .value("T"))))
        engine.apply(.sessionMessage(SessionMessage(
            messageId: Self.messageId, content: .value([Self.text("hi")]), senderSessionId: .value(Self.parent))))
        engine.apply(.sessionMessageChunk(SessionMessageChunk(content: Self.text("!"), messageId: Self.messageId)))

        var replayed = SessionMergeEngine()
        for update in engine.stateUpdates + engine.transcriptUpdates {
            replayed.apply(update)
        }
        #expect(replayed.subagents == engine.subagents)
        #expect(replayed.entries == engine.entries)
    }

    @Test func theAnnouncementsComeBeforeTheOtherStateInTheReplay() {
        var engine = SessionMergeEngine()
        engine.apply(.usageUpdate(UsageUpdate(size: 10, used: 1)))
        engine.apply(.subagentUpdate(SubagentUpdate(sessionId: Self.child)))
        guard case .subagentUpdate = engine.stateUpdates.first else {
            Issue.record("the first state update must announce the child")
            return
        }
    }

    @Test func aBackgroundSubagentSurvivesInTheAgentState() {
        var engine = SessionMergeEngine()
        let state = StateUpdate.running(RunningStateUpdate(background: [.subagent(BackgroundSubagent(sessionId: Self.child))]))
        engine.apply(.stateUpdate(state))
        #expect(engine.agentState == state)
    }
}
