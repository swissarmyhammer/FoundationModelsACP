import Foundation
import Testing

@testable import FoundationModelsACP

/// The unstable `session_message` and `session_message_chunk` session
/// updates (ACP v2 "Subagent Sessions").
@Suite struct SessionMessageCodingTests {
    private static let messageId = MessageId(rawValue: "m-1")

    @Test func aMessageWithOnlyAMessageIdLeavesEveryFieldUnchanged() throws {
        let update = try WireRoundTrip.expectLossless(SessionUpdate.self, """
            {"sessionUpdate":"session_message","messageId":"m-1"}
            """)
        #expect(update == .sessionMessage(SessionMessage(messageId: Self.messageId)))
    }

    @Test func participantsAndReferencesDecodeAndRoundTrip() throws {
        let message = try WireRoundTrip.expectLossless(SessionMessage.self, """
            {"messageId":"m-1","senderSessionId":"parent","recipientSessionId":"child-1","senderMessageId":"p-9","recipientMessageId":"c-2"}
            """)
        #expect(message.senderSessionId == .value(SessionId(rawValue: "parent")))
        #expect(message.recipientSessionId == .value(SessionId(rawValue: "child-1")))
        #expect(message.senderMessageId == .value(MessageId(rawValue: "p-9")))
        #expect(message.recipientMessageId == .value(MessageId(rawValue: "c-2")))
    }

    @Test func nullClearsAParticipantAndOmittedLeavesIt() throws {
        let message = try WireRoundTrip.expectLossless(SessionMessage.self, """
            {"messageId":"m-1","senderSessionId":null,"content":null}
            """)
        #expect(message.senderSessionId == .cleared)
        #expect(message.recipientSessionId == .unchanged)
        #expect(message.content == .cleared)
    }

    @Test func aChunkCarriesOnlyContent() throws {
        let update = try WireRoundTrip.expectLossless(SessionUpdate.self, """
            {"sessionUpdate":"session_message_chunk","messageId":"m-1","content":{"type":"text","text":"hi"}}
            """)
        guard case .sessionMessageChunk(let chunk) = update else {
            Issue.record("expected a session_message_chunk, got \(update)")
            return
        }
        #expect(chunk.messageId == Self.messageId)
        #expect(chunk.content == .text(TextContent(text: "hi")))
    }
}
