import Testing

@testable import FoundationModelsACP

/// `PendingPromptCorrelator` links the local pending prompt of a client to the
/// user message that the agent inserted. The `session/prompt` response and the
/// `user_message` echo can arrive in either order.
@Suite struct PendingPromptCorrelatorTests {
    /// The local identifier that the client gives to its pending prompt.
    private static let localID = "local-1"

    /// The local identifier of a second pending prompt.
    private static let otherLocalID = "local-2"

    /// The identifier that the agent gives to the inserted user message.
    private static let messageId = MessageId(rawValue: "user-msg-1")

    /// The identifier of a user message that no pending prompt of this
    /// client caused.
    private static let foreignMessageId = MessageId(rawValue: "user-msg-foreign")

    /// The link that the correlator reports for the first pending prompt.
    private static let expectedLink = PendingPromptCorrelator<String>.Link(localID: localID, messageId: messageId)

    /// Makes the `user_message` echo of a message.
    ///
    /// - Parameter messageId: The identifier of the message.
    /// - Returns: The session update.
    private static func echo(_ messageId: MessageId) -> SessionUpdate {
        .userMessage(UserMessage(messageId: messageId, content: .value([.text(TextContent(text: "hello"))])))
    }

    /// Makes a correlator with the first local prompt pending.
    ///
    /// - Returns: The correlator.
    private static func correlatorWithPendingPrompt() -> PendingPromptCorrelator<String> {
        var correlator = PendingPromptCorrelator<String>()
        correlator.addPendingPrompt(localID)
        return correlator
    }

    // MARK: - Both orders

    @Test func anEchoBeforeTheResponseLinksWhenTheResponseArrives() {
        var correlator = Self.correlatorWithPendingPrompt()

        #expect(correlator.observe(Self.echo(Self.messageId)) == nil)
        #expect(correlator.resolve(Self.localID, with: PromptResponse(messageId: Self.messageId)) == Self.expectedLink)
    }

    @Test func aResponseBeforeTheEchoLinksWhenTheEchoArrives() {
        var correlator = Self.correlatorWithPendingPrompt()

        #expect(correlator.resolve(Self.localID, with: PromptResponse(messageId: Self.messageId)) == nil)
        #expect(correlator.observe(Self.echo(Self.messageId)) == Self.expectedLink)
    }

    @Test func aUserMessageChunkEchoAlsoLinks() {
        var correlator = Self.correlatorWithPendingPrompt()
        let chunk = SessionUpdate.userMessageChunk(
            ContentChunk(content: .text(TextContent(text: "hello")), messageId: Self.messageId)
        )

        #expect(correlator.resolve(Self.localID, with: PromptResponse(messageId: Self.messageId)) == nil)
        #expect(correlator.observe(chunk) == Self.expectedLink)
    }

    @Test func theLinkNamesTheTranscriptEntryOfTheUserMessage() {
        #expect(Self.expectedLink.entryID == .userMessage(Self.messageId))
    }

    // MARK: - One link for each prompt

    @Test func aLaterEchoOfALinkedMessageDoesNotLinkAgain() {
        var correlator = Self.correlatorWithPendingPrompt()
        correlator.resolve(Self.localID, with: PromptResponse(messageId: Self.messageId))
        correlator.observe(Self.echo(Self.messageId))

        #expect(correlator.observe(Self.echo(Self.messageId)) == nil)
    }

    @Test func twoPendingPromptsLinkEachToItsOwnMessage() {
        var correlator = Self.correlatorWithPendingPrompt()
        correlator.addPendingPrompt(Self.otherLocalID)

        #expect(correlator.observe(Self.echo(Self.foreignMessageId)) == nil)
        #expect(correlator.resolve(Self.localID, with: PromptResponse(messageId: Self.messageId)) == nil)
        #expect(
            correlator.resolve(Self.otherLocalID, with: PromptResponse(messageId: Self.foreignMessageId))
                == PendingPromptCorrelator<String>.Link(localID: Self.otherLocalID, messageId: Self.foreignMessageId)
        )
        #expect(correlator.observe(Self.echo(Self.messageId)) == Self.expectedLink)
    }

    // MARK: - Echoes that no pending prompt caused

    @Test func anEchoWithNoPendingPromptCannotLinkALaterResponse() {
        var correlator = PendingPromptCorrelator<String>()
        correlator.observe(Self.echo(Self.messageId))
        correlator.addPendingPrompt(Self.localID)

        #expect(correlator.resolve(Self.localID, with: PromptResponse(messageId: Self.messageId)) == nil)
    }

    @Test func anEchoThatNoResponseNamedIsForgottenWhenNoPromptWaitsForAResponse() {
        var correlator = Self.correlatorWithPendingPrompt()
        correlator.observe(Self.echo(Self.foreignMessageId))
        correlator.resolve(Self.localID, with: PromptResponse(messageId: Self.messageId))
        correlator.addPendingPrompt(Self.otherLocalID)

        #expect(correlator.resolve(Self.otherLocalID, with: PromptResponse(messageId: Self.foreignMessageId)) == nil)
    }

    // MARK: - A prompt that failed

    @Test func aRemovedPromptDoesNotLinkALaterEcho() {
        var correlator = Self.correlatorWithPendingPrompt()
        correlator.resolve(Self.localID, with: PromptResponse(messageId: Self.messageId))
        correlator.removePendingPrompt(Self.localID)

        #expect(correlator.observe(Self.echo(Self.messageId)) == nil)
    }

    @Test func removingTheLastPendingPromptForgetsTheEarlyEchoes() {
        var correlator = Self.correlatorWithPendingPrompt()
        correlator.observe(Self.echo(Self.messageId))
        correlator.removePendingPrompt(Self.localID)
        correlator.addPendingPrompt(Self.otherLocalID)

        #expect(correlator.resolve(Self.otherLocalID, with: PromptResponse(messageId: Self.messageId)) == nil)
    }

    @Test func anUpdateThatIsNotAUserMessageDoesNotLink() {
        var correlator = Self.correlatorWithPendingPrompt()
        correlator.resolve(Self.localID, with: PromptResponse(messageId: Self.messageId))
        let agentChunk = SessionUpdate.agentMessageChunk(
            ContentChunk(content: .text(TextContent(text: "hi")), messageId: Self.messageId)
        )

        #expect(correlator.observe(agentChunk) == nil)
        #expect(correlator.observe(Self.echo(Self.messageId)) == Self.expectedLink)
    }
}
