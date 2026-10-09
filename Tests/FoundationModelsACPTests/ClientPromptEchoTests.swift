import Testing

@testable import FoundationModelsACP

// MARK: - Fixtures

/// The session that each test prompts in.
private let echoSessionId = SessionId(rawValue: "echo-session")

/// A second session, whose updates must not complete a prompt of
/// `echoSessionId`.
private let otherSessionId = SessionId(rawValue: "echo-other-session")

/// The identifier that the agent gives to the inserted user message.
private let echoMessageId = MessageId(rawValue: "echo-user-msg-1")

/// The identifier of a user message that the test prompt did not cause.
private let foreignMessageId = MessageId(rawValue: "echo-user-msg-foreign")

/// The content of the test prompt.
private let echoPromptContent: [ContentBlock] = [.text(TextContent(text: "hello"))]

/// The content of a user message that the test prompt did not cause.
private let foreignContent: [ContentBlock] = [.text(TextContent(text: "not this prompt"))]

/// The prompt that each test sends.
private let echoPrompt = PromptRequest(prompt: echoPromptContent, sessionId: echoSessionId)

/// The time limit of each test in this suite, in minutes.
private let echoTestTimeout = 1

/// The error that the agent gives to a prompt that fails.
private let echoPromptFailure = RequestError.invalidParams

/// The first chunk of a `user_message_chunk` echo of the test prompt.
private let firstEchoChunk = SessionUpdate.userMessageChunk(
    ContentChunk(content: .text(TextContent(text: "hel")), messageId: echoMessageId)
)

/// The second chunk of a `user_message_chunk` echo of the test prompt.
private let secondEchoChunk = SessionUpdate.userMessageChunk(
    ContentChunk(content: .text(TextContent(text: "lo")), messageId: echoMessageId)
)

/// Makes a `user_message` echo.
///
/// - Parameters:
///   - messageId: The identifier of the message.
///   - content: The content of the message.
/// - Returns: The session update.
private func userMessageEcho(_ messageId: MessageId, content: [ContentBlock] = echoPromptContent) -> SessionUpdate {
    .userMessage(UserMessage(messageId: messageId, content: .value(content)))
}

/// The `user_message` echo of the test prompt.
private let promptEcho = userMessageEcho(echoMessageId)

// MARK: - Harness

/// A client connection, and the raw agent end that the test writes as the
/// agent.
private struct EchoHarness {
    /// The client side, under test.
    let client: ClientSideConnection

    /// The raw agent end of the transport.
    let agentEnd: InMemoryTransport

    /// Reads the requests that the client writes.
    let reader: WireReader

    /// Makes a client over an in-memory transport.
    ///
    /// - Returns: The harness.
    static func connect() async -> EchoHarness {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let client = await ClientSideConnection(stream: clientEnd) { _ in HandshakeClient() }
        return EchoHarness(client: client, agentEnd: agentEnd, reader: WireReader(agentEnd))
    }

    /// Starts `promptWithEcho(_:)` with the test prompt, and reads the request
    /// from the wire.
    ///
    /// - Returns: The prompt task, and the wire ID of the request.
    /// - Throws: Rethrows a transport read failure.
    func startPrompt() async throws -> (task: Task<EchoedPromptResponse, any Error>, id: JSONValue) {
        let client = client
        let task = Task { try await client.promptWithEcho(echoPrompt) }
        let id = try #require(requestID(of: try await reader.next()))
        return (task, id)
    }

    /// Sends one `session/update` as the agent.
    ///
    /// - Parameters:
    ///   - update: The update.
    ///   - sessionId: The session of the update.
    /// - Throws: Rethrows an encoding or transport failure.
    func sendUpdate(_ update: SessionUpdate, in sessionId: SessionId = echoSessionId) async throws {
        let notification = UpdateSessionNotification(sessionId: sessionId, update: update)
        try await send(sessionUpdateEnvelope(notification), over: agentEnd)
    }

    /// Sends the `session/prompt` response as the agent.
    ///
    /// - Parameters:
    ///   - id: The wire ID of the request.
    ///   - messageId: The identifier of the inserted user message.
    /// - Throws: Rethrows an encoding or transport failure.
    func sendResponse(id: JSONValue, messageId: MessageId = echoMessageId) async throws {
        try await send(responseEnvelope(id: id, result: PromptResponse(messageId: messageId)), over: agentEnd)
    }

    /// Sends an error response to `session/prompt` as the agent.
    ///
    /// - Parameter id: The wire ID of the request.
    /// - Throws: Rethrows a transport failure.
    func sendFailure(id: JSONValue) async throws {
        try await send(errorEnvelope(id: id, error: echoPromptFailure), over: agentEnd)
    }
}

// MARK: - Tests

/// `ClientSideConnection.promptWithEcho(_:)` gives the `session/prompt`
/// response together with the `user_message` echo of the same message, in
/// either arrival order.
@Suite struct ClientPromptEchoTests {
    /// Checks that a result names the test message and carries its echo.
    ///
    /// - Parameter result: The result of `promptWithEcho(_:)`.
    private func expectLinkedToPromptEcho(_ result: EchoedPromptResponse) {
        #expect(result.response == PromptResponse(messageId: echoMessageId))
        #expect(result.messageId == echoMessageId)
        #expect(result.echo == promptEcho)
        #expect(result.entryID == .userMessage(echoMessageId))
    }

    @Test(.timeLimit(.minutes(echoTestTimeout)))
    func anEchoBeforeTheResponseGivesTheMessageIdAndTheEcho() async throws {
        let harness = await EchoHarness.connect()
        let (prompt, id) = try await harness.startPrompt()

        try await harness.sendUpdate(promptEcho)
        try await harness.sendResponse(id: id)

        expectLinkedToPromptEcho(try await prompt.value)
        await harness.client.close()
    }

    @Test(.timeLimit(.minutes(echoTestTimeout)))
    func anEchoAfterTheResponseGivesTheMessageIdAndTheEcho() async throws {
        let harness = await EchoHarness.connect()
        let (prompt, id) = try await harness.startPrompt()

        try await harness.sendResponse(id: id)
        try await harness.sendUpdate(promptEcho)

        expectLinkedToPromptEcho(try await prompt.value)
        await harness.client.close()
    }

    @Test(.timeLimit(.minutes(echoTestTimeout)))
    func aUserMessageChunkEchoGivesTheFirstChunk() async throws {
        let harness = await EchoHarness.connect()
        let (prompt, id) = try await harness.startPrompt()

        try await harness.sendUpdate(firstEchoChunk)
        try await harness.sendUpdate(secondEchoChunk)
        try await harness.sendResponse(id: id)

        let result = try await prompt.value
        #expect(result.messageId == echoMessageId)
        #expect(result.echo == firstEchoChunk)
        await harness.client.close()
    }

    @Test(.timeLimit(.minutes(echoTestTimeout)))
    func anEchoOfAnotherMessageDoesNotCompleteThePrompt() async throws {
        let harness = await EchoHarness.connect()
        let (prompt, id) = try await harness.startPrompt()

        try await harness.sendUpdate(userMessageEcho(foreignMessageId, content: foreignContent))
        try await harness.sendResponse(id: id)
        try await harness.sendUpdate(userMessageEcho(foreignMessageId, content: foreignContent))
        try await harness.sendUpdate(promptEcho)

        expectLinkedToPromptEcho(try await prompt.value)
        await harness.client.close()
    }

    @Test(.timeLimit(.minutes(echoTestTimeout)))
    func anEchoInAnotherSessionDoesNotCompleteThePrompt() async throws {
        let harness = await EchoHarness.connect()
        let (prompt, id) = try await harness.startPrompt()

        try await harness.sendUpdate(userMessageEcho(echoMessageId, content: foreignContent), in: otherSessionId)
        try await harness.sendResponse(id: id)
        try await harness.sendUpdate(promptEcho)

        expectLinkedToPromptEcho(try await prompt.value)
        await harness.client.close()
    }

    @Test(.timeLimit(.minutes(echoTestTimeout)))
    func anErrorResponseThrowsTheError() async throws {
        let harness = await EchoHarness.connect()
        let (prompt, id) = try await harness.startPrompt()

        try await harness.sendUpdate(promptEcho)
        try await harness.sendFailure(id: id)

        await #expect(throws: echoPromptFailure) { try await prompt.value }
        await harness.client.close()
    }

    @Test(.timeLimit(.minutes(echoTestTimeout)))
    func aConnectionCloseBeforeTheEchoThrowsClosed() async throws {
        let harness = await EchoHarness.connect()
        let (prompt, id) = try await harness.startPrompt()

        try await harness.sendResponse(id: id)
        await harness.client.close()

        await #expect(throws: ConnectionError.closed) { try await prompt.value }
    }

    @Test(.timeLimit(.minutes(echoTestTimeout)))
    func aCancelledTaskBeforeTheEchoThrowsCancellationError() async throws {
        let harness = await EchoHarness.connect()
        let (prompt, id) = try await harness.startPrompt()

        try await harness.sendResponse(id: id)
        prompt.cancel()

        await #expect(throws: CancellationError.self) { try await prompt.value }
        await harness.client.close()
    }
}
