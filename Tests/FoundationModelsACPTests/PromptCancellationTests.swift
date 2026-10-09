import Foundation
import Testing

@testable import FoundationModelsACP

// MARK: - The agent that waits for cancellation

/// When the prompt handler of `CancelledPromptAgent` stops to wait for the
/// `$/cancel_request`.
private enum CancellationPoint: Sendable {
    /// The handler waits before it inserts the user message. It never
    /// inserts the message.
    case beforeInsertion

    /// The handler inserts the user message and defers a probe, and then
    /// waits.
    case afterInsertion
}

/// The events that `CancelledPromptAgent` sends to the test.
private final class CancellationProbe: Sendable {
    /// Gets one element when the handler starts to wait for the
    /// `$/cancel_request`.
    let waiting = AsyncStream<Void>.makeStream()

    /// Gets the value of `Task.isCancelled` that the deferred work of the
    /// handler sees.
    let deferredWorkCancellation = AsyncStream<Bool>.makeStream()
}

/// An agent whose prompt handler waits until the connection cancels it, and
/// then throws `CancellationError`.
private struct CancelledPromptAgent: Agent {
    /// The connection that the factory gave this agent.
    let connection: AgentSideConnection

    /// When the handler waits for the cancellation.
    let point: CancellationPoint

    /// The events for the test.
    let probe: CancellationProbe

    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(
            info: Implementation(name: "cancelled-prompt-agent", version: "0.0.0"),
            protocolVersion: .v2,
            capabilities: AgentCapabilities(session: SessionCapabilities())
        )
    }

    func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: cancellationSessionId)
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

    /// Inserts the prompt when `point` tells it to, then waits until the
    /// connection cancels the handler.
    ///
    /// - Parameter params: The prompt request.
    /// - Returns: Never. The handler always throws.
    /// - Throws: `CancellationError` after the connection cancels the handler.
    func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        if case .afterInsertion = point {
            connection.insertUserMessage(params, messageId: cancellationMessageId)
            connection.afterRespondingToCurrentRequest { [probe] in
                probe.deferredWorkCancellation.continuation.yield(Task.isCancelled)
            }
        }
        probe.waiting.continuation.yield(())
        while !Task.isCancelled {
            try await Task.sleep(for: cancellationPollInterval)
        }
        throw CancellationError()
    }

    func sessionCancel(_ params: CancelSessionNotification) async {}
}

// MARK: - Fixtures

/// The one session of the tests.
private let cancellationSessionId = SessionId(rawValue: "cancellation-session")

/// The identifier that the agent gives to the inserted user message.
private let cancellationMessageId = MessageId(rawValue: "cancelled-prompt-msg-1")

/// The content of the test prompt.
private let cancellationPromptContent: [ContentBlock] = [.text(TextContent(text: "hello"))]

/// The wire id of the `session/prompt` request.
private let promptRequestId: JSONValue = .number(1)

/// The number of the request that proves that no frame came after the error
/// response.
private let followUpRequestNumber: Double = 2

/// The wire id of the request that proves that no frame came after the
/// error response.
private let followUpRequestId: JSONValue = .number(followUpRequestNumber)

/// How many milliseconds the handler sleeps between two checks for
/// cancellation.
private let cancellationPollMilliseconds = 5

/// How long the handler sleeps between two checks for cancellation.
private let cancellationPollInterval = Duration.milliseconds(cancellationPollMilliseconds)

/// The time limit of each test in this suite, in minutes.
private let cancellationTestTimeout = 1

/// The JSON-RPC version of each frame.
private let jsonrpcVersion: JSONValue = .string("2.0")

/// One agent connection and the raw client end of its transport.
private struct RawClientHarness {
    /// The agent side.
    let agent: AgentSideConnection

    /// The raw client end of the transport.
    let clientEnd: InMemoryTransport

    /// Reads the frames that the agent writes.
    let reader: WireReader

    /// Sends one JSON-RPC request.
    ///
    /// - Parameters:
    ///   - id: The wire id of the request.
    ///   - handler: The Swift handler name of the agent method.
    ///   - params: The typed request parameters.
    /// - Throws: Any encoding or transport failure.
    func sendRequest(id: JSONValue, handler: String, params: some Encodable) async throws {
        try await send(
            .object([
                "jsonrpc": jsonrpcVersion,
                "id": id,
                "method": .string(RoleRouting.wireMethod(for: handler, on: .agent)),
                "params": try JSONValue.encode(result: params),
            ]),
            over: clientEnd
        )
    }

    /// Sends a `$/cancel_request` for the prompt request.
    ///
    /// - Throws: Any transport failure.
    func cancelPrompt() async throws {
        try await send(
            .object([
                "jsonrpc": jsonrpcVersion,
                "method": .string("$/cancel_request"),
                "params": .object(["requestId": promptRequestId]),
            ]),
            over: clientEnd
        )
    }

    /// Reads the next frame that the agent wrote.
    ///
    /// - Returns: The frame.
    /// - Throws: When the stream ends before a frame comes.
    func nextFrame() async throws -> JSONValue {
        try #require(try await reader.next())
    }
}

// MARK: - Tests

/// A `$/cancel_request` for a `session/prompt` does not give `-32800` after
/// the agent inserted the user message, and deferred work does not see the
/// cancellation.
@Suite struct PromptCancellationTests {
    /// Connects a `CancelledPromptAgent` to a raw client end, sends the
    /// prompt, and waits until the handler waits for the cancellation.
    ///
    /// - Parameters:
    ///   - point: When the handler waits for the cancellation.
    ///   - probe: The events of the agent.
    /// - Returns: The harness.
    /// - Throws: Any transport failure.
    private func startPrompt(
        cancelledAt point: CancellationPoint,
        probe: CancellationProbe
    ) async throws -> RawClientHarness {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agent = await AgentSideConnection(stream: agentEnd) { connection in
            CancelledPromptAgent(connection: connection, point: point, probe: probe)
        }
        let harness = RawClientHarness(agent: agent, clientEnd: clientEnd, reader: WireReader(clientEnd))
        let prompt = PromptRequest(prompt: cancellationPromptContent, sessionId: cancellationSessionId)
        try await harness.sendRequest(id: promptRequestId, handler: "prompt", params: prompt)
        var waiting = probe.waiting.stream.makeAsyncIterator()
        _ = await waiting.next()
        return harness
    }

    @Test(.timeLimit(.minutes(cancellationTestTimeout)))
    func aCancelAfterInsertionAnswersTheMessageIdAndThenSendsTheEcho() async throws {
        let harness = try await startPrompt(cancelledAt: .afterInsertion, probe: CancellationProbe())

        try await harness.cancelPrompt()

        let expectedResponse: JSONValue = .object([
            "jsonrpc": jsonrpcVersion,
            "id": promptRequestId,
            "result": try JSONValue.encode(result: PromptResponse(messageId: cancellationMessageId)),
        ])
        #expect(try await harness.nextFrame() == expectedResponse)
        let echo = UpdateSessionNotification(
            sessionId: cancellationSessionId,
            update: .userMessage(
                UserMessage(messageId: cancellationMessageId, content: .value(cancellationPromptContent)))
        )
        let expectedEcho: JSONValue = .object([
            "jsonrpc": jsonrpcVersion,
            "method": .string(RoleRouting.wireMethod(for: "sessionUpdate", on: .client)),
            "params": try JSONValue.encode(result: echo),
        ])
        #expect(try await harness.nextFrame() == expectedEcho)
        await harness.agent.close()
    }

    @Test(.timeLimit(.minutes(cancellationTestTimeout)))
    func aCancelBeforeInsertionAnswersRequestCancelledAndSendsNoEcho() async throws {
        let harness = try await startPrompt(cancelledAt: .beforeInsertion, probe: CancellationProbe())

        try await harness.cancelPrompt()

        let expectedResponse: JSONValue = .object([
            "jsonrpc": jsonrpcVersion,
            "id": promptRequestId,
            "error": RequestError.requestCancelled.wireValue,
        ])
        #expect(try await harness.nextFrame() == expectedResponse)
        // An echo would come before the answer to a later request.
        try await harness.sendRequest(id: followUpRequestId, handler: "listSessions", params: ListSessionsRequest())
        #expect(requestID(of: try await harness.nextFrame()) == followUpRequestId)
        await harness.agent.close()
    }

    @Test(.timeLimit(.minutes(cancellationTestTimeout)))
    func deferredWorkDoesNotSeeTheCancellationOfTheHandler() async throws {
        let probe = CancellationProbe()
        let harness = try await startPrompt(cancelledAt: .afterInsertion, probe: probe)

        try await harness.cancelPrompt()

        var observed = probe.deferredWorkCancellation.stream.makeAsyncIterator()
        // `nil` means that the deferred work did not run, and fails too.
        #expect(await observed.next() == false)
        await harness.agent.close()
    }
}
