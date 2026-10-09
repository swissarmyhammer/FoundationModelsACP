/// The result of ``ClientSideConnection/promptWithEcho(_:)``: the
/// `session/prompt` response, and the echo of the user message that the agent
/// inserted for the prompt.
///
/// The agent gives the inserted user message a `messageId`. The response and
/// the echo both name it. The echo can arrive before or after the response.
/// This value has both, so the client can replace its local pending entry of
/// the prompt with the transcript entry of the message, ``entryID``.
public struct EchoedPromptResponse: Hashable, Sendable {
    /// The `session/prompt` response.
    public let response: PromptResponse

    /// The first echo of the user message: a `user_message` update, or the
    /// first `user_message_chunk` update of the message.
    public let echo: SessionUpdate

    /// The identifier that the agent gave to the user message.
    public var messageId: MessageId {
        response.messageId
    }

    /// The identifier of the user message entry in a ``SessionMergeEngine``
    /// transcript.
    public var entryID: SessionEntry.ID {
        .userMessage(messageId)
    }
}
