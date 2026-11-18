import Foundation
import Testing

import FoundationModelsACP

/// `SessionMergeEngine.init(replaying:)`: the engine holds the history that
/// the updates give.
@Suite struct SessionMergeEngineReplayInitTests {
    /// The updates of one short session.
    private static let updates: [SessionUpdate] = [
        .userMessageChunk(ContentChunk(content: .text(TextContent(text: "Hello")), messageId: MessageId(rawValue: "u1"))),
        .agentMessageChunk(ContentChunk(content: .text(TextContent(text: "Hi")), messageId: MessageId(rawValue: "a1"))),
        .agentMessageChunk(ContentChunk(content: .text(TextContent(text: " there")), messageId: MessageId(rawValue: "a1"))),
        .toolCallUpdate(ToolCallUpdate(toolCallId: ToolCallId(rawValue: "t1"), status: .value(.completed), title: .value("Read"))),
    ]

    @Test func theReplayEqualsTheSameUpdatesAppliedOneByOne() {
        var applied = SessionMergeEngine()
        for update in Self.updates {
            applied.apply(update)
        }
        #expect(SessionMergeEngine(replaying: Self.updates) == applied)
    }

    @Test func aReplayOfNoUpdatesIsAnEmptyEngine() {
        #expect(SessionMergeEngine(replaying: [SessionUpdate]()) == SessionMergeEngine())
    }

    @Test func aReplayTakesAnySequence() {
        #expect(SessionMergeEngine(replaying: Self.updates.lazy.map { $0 }) == SessionMergeEngine(replaying: Self.updates))
    }
}
