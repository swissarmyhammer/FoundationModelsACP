import Foundation
import Synchronization
import Testing

@testable import FoundationModelsACP

// MARK: - The inserting agent

/// How `InsertingAgent` calls `AgentSideConnection.insertUserMessage`.
private enum InsertionMode: Sendable {
    /// The helper makes a new message identifier.
    case newMessageId

    /// The agent gives this message identifier to the helper.
    case callerMessageId(MessageId)

    /// The helper also applies the echo to the history of the agent.
    case recordInHistory
}

/// The retained history of `InsertingAgent`. The test reads it after the
/// prompt.
private final class AgentHistory: Sendable {
    /// The merge engine that holds the history.
    let engine = Mutex(SessionMergeEngine())
}

/// An agent that inserts each prompt as a user message with
/// `AgentSideConnection.insertUserMessage`, and returns the identifier that
/// the helper gives.
private struct InsertingAgent: Agent {
    /// The connection that the factory gave this agent.
    let connection: AgentSideConnection

    /// How the agent calls the helper.
    let mode: InsertionMode

    /// The retained history, for `InsertionMode.recordInHistory`.
    let history: AgentHistory

    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(
            info: Implementation(name: "inserting-agent", version: "0.0.0"),
            protocolVersion: .v2,
            capabilities: AgentCapabilities(session: SessionCapabilities())
        )
    }

    func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: insertionSessionId)
    }

    func listSessions(_ params: ListSessionsRequest) async throws -> ListSessionsResponse {
        ListSessionsResponse(sessions: [])
    }

    func resumeSession(_ params: ResumeSessionRequest) async throws -> ResumeSessionResponse {
        ResumeSessionResponse()
    }

    func closeSession(_ params: CloseSessionRequest) async throws -> CloseSessionResponse {
        CloseSessionResponse()
    }

    /// Inserts the prompt as a user message, and names that message in the
    /// response.
    ///
    /// - Parameter params: The prompt request.
    /// - Returns: The response that names the inserted user message.
    func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        PromptResponse(messageId: insert(params))
    }

    func sessionCancel(_ params: CancelSessionNotification) async {}

    /// Calls the helper in the mode of this agent.
    ///
    /// - Parameter request: The prompt request.
    /// - Returns: The identifier of the inserted user message.
    private func insert(_ request: PromptRequest) -> MessageId {
        switch mode {
        case .newMessageId:
            connection.insertUserMessage(request)
        case .callerMessageId(let messageId):
            connection.insertUserMessage(request, messageId: messageId)
        case .recordInHistory:
            history.engine.withLock { connection.insertUserMessage(request, into: &$0) }
        }
    }
}

/// A client that only opens the connection. The tests read updates through
/// `ClientSideConnection.subscribe(to:)`.
private struct ObservingClient: Client {
    func sessionUpdate(_ notification: UpdateSessionNotification) async {}

    func requestPermission(_ params: RequestPermissionRequest) async throws -> RequestPermissionResponse {
        throw RequestError.methodNotFound("requestPermission")
    }

    func createElicitation(_ params: CreateElicitationRequest) async throws -> CreateElicitationResponse {
        throw RequestError.methodNotFound("createElicitation")
    }

    func elicitationComplete(_ notification: CompleteElicitationNotification) async {}
}

// MARK: - Fixtures

/// The one session that `InsertingAgent` makes.
private let insertionSessionId = SessionId(rawValue: "insertion-session")

/// The working directory of the test session. Its value has no effect.
private let insertionWorkingDirectory = AbsolutePath(rawValue: "/work")

/// The content of each test prompt.
private let promptContent: [ContentBlock] = [.text(TextContent(text: "hello")), .text(TextContent(text: "world"))]

/// The prompt that each test sends.
private let insertionPrompt = PromptRequest(prompt: promptContent, sessionId: insertionSessionId)

/// The number of new agent and client pairs that the ordering test uses. One
/// pass can show the correct order by chance, so the test uses many passes.
private let orderingRepetitions = 50

/// The time limit of each test in this suite, in minutes.
private let insertionTestTimeout = 1

/// The agent and client connections of one test.
private struct ConnectionPair {
    /// The agent side.
    let agent: AgentSideConnection

    /// The client side.
    let client: ClientSideConnection

    /// Closes both sides.
    func close() async {
        await agent.close()
        await client.close()
    }
}

// MARK: - Tests

/// `AgentSideConnection.insertUserMessage` inserts the prompt as a user
/// message, echoes it as a `user_message` update after the response, and
/// returns the identifier that the response names.
@Suite struct UserMessageInsertionTests {
    /// Connects an `InsertingAgent` to a client over `InMemoryTransport`, and
    /// opens the session.
    ///
    /// - Parameters:
    ///   - mode: How the agent calls the helper.
    ///   - history: The retained history of the agent.
    ///   - wrap: Wraps the agent end of the transport.
    /// - Returns: The two connections.
    /// - Throws: Any error from `session/new`.
    private func connect(
        mode: InsertionMode,
        history: AgentHistory = AgentHistory(),
        wrap: (any ACPTransport) -> any ACPTransport = { $0 }
    ) async throws -> ConnectionPair {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agent = await AgentSideConnection(stream: wrap(agentEnd)) { connection in
            InsertingAgent(connection: connection, mode: mode, history: history)
        }
        let client = await ClientSideConnection(stream: clientEnd) { _ in ObservingClient() }
        _ = try await client.newSession(NewSessionRequest(cwd: insertionWorkingDirectory))
        return ConnectionPair(agent: agent, client: client)
    }

    @Test(.timeLimit(.minutes(insertionTestTimeout)))
    func theEchoCarriesThePromptAndTheMessageIdThatTheResponseNames() async throws {
        let pair = try await connect(mode: .newMessageId)
        var updates = pair.client.subscribe(to: insertionSessionId).updates.makeAsyncIterator()

        let response = try await pair.client.prompt(insertionPrompt)

        #expect(!response.messageId.rawValue.isEmpty)
        let echo = UserMessage(messageId: response.messageId, content: .value(promptContent))
        #expect(await updates.next() == .userMessage(echo))
        await pair.close()
    }

    @Test(.timeLimit(.minutes(insertionTestTimeout)))
    func eachPromptGetsANewMessageId() async throws {
        let pair = try await connect(mode: .newMessageId)

        let first = try await pair.client.prompt(insertionPrompt)
        let second = try await pair.client.prompt(insertionPrompt)

        #expect(first.messageId != second.messageId)
        await pair.close()
    }

    @Test(.timeLimit(.minutes(insertionTestTimeout)))
    func aMessageIdFromTheCallerIsTheIdOfTheResponseAndTheEcho() async throws {
        let callerId = MessageId(rawValue: "caller-msg-1")
        let pair = try await connect(mode: .callerMessageId(callerId))
        var updates = pair.client.subscribe(to: insertionSessionId).updates.makeAsyncIterator()

        let response = try await pair.client.prompt(insertionPrompt)

        #expect(response.messageId == callerId)
        #expect(await updates.next() == .userMessage(UserMessage(messageId: callerId, content: .value(promptContent))))
        await pair.close()
    }

    @Test(.timeLimit(.minutes(insertionTestTimeout)))
    func theEchoEntersTheHistoryWithTheMessageIdThatTheResponseNames() async throws {
        let history = AgentHistory()
        let pair = try await connect(mode: .recordInHistory, history: history)

        let response = try await pair.client.prompt(insertionPrompt)

        let recorded = history.engine.withLock { $0.entries }
        let message = SessionEntry.Message(messageId: response.messageId, content: promptContent)
        #expect(recorded == [SessionEntry(id: .userMessage(response.messageId), kind: .userMessage(message))])
        await pair.close()
    }

    @Test(.timeLimit(.minutes(insertionTestTimeout)))
    func theResponseIsWrittenBeforeTheEcho() async throws {
        for _ in 0..<orderingRepetitions {
            let log = EventLog()
            let pair = try await connect(mode: .newMessageId) { LoggingTransport(underlying: $0, log: log) }
            await log.reset()
            var updates = pair.client.subscribe(to: insertionSessionId).updates.makeAsyncIterator()

            _ = try await pair.client.prompt(insertionPrompt)
            // When the client has the echo, the agent wrote both frames.
            _ = try #require(await updates.next())

            #expect(await log.events == ["response", "update"])
            await pair.close()
        }
    }

    @Test(.timeLimit(.minutes(insertionTestTimeout)))
    func theClientCorrelatorLinksThePendingPromptToTheEchoedMessage() async throws {
        let pair = try await connect(mode: .newMessageId)
        var updates = pair.client.subscribe(to: insertionSessionId).updates.makeAsyncIterator()
        var correlator = PendingPromptCorrelator<Int>()
        let localID = 1
        correlator.addPendingPrompt(localID)

        let response = try await pair.client.prompt(insertionPrompt)
        let echo = try #require(await updates.next())

        #expect(correlator.resolve(localID, with: response) == nil)
        #expect(correlator.observe(echo) == PendingPromptCorrelator<Int>.Link(localID: localID, messageId: response.messageId))
        await pair.close()
    }
}
