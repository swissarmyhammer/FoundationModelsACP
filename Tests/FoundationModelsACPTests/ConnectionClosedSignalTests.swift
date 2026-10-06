import Foundation
import Synchronization
import Testing

import FoundationModelsACP

// MARK: - Fixtures

/// The time limit of each test in this suite, in minutes.
private let closedSignalTestTimeout = 1

/// The number of seconds in one hour.
private let secondsPerHour = 3600

/// How long a test request handler waits for its cancellation. The value is
/// much longer than any test, so only the cancellation ends the wait.
private let handlerWaitForCancellation: Duration = .seconds(secondsPerHour)

/// The number of milliseconds that a test request handler continues to work
/// after its cancellation.
private let handlerWorkAfterCancellationMilliseconds = 200

/// How long a test request handler continues to work after its
/// cancellation. The signal must wait for this work to end.
private let handlerWorkAfterCancellation: Duration =
    .milliseconds(handlerWorkAfterCancellationMilliseconds)

/// The error that the scripted input stream fails with.
private struct WireFailure: Error {}

/// The case of a `ConnectionCloseReason`, with no associated value, so a test
/// can compare it with `==`. Not `private`, because `CloseTrigger` gives it.
enum CloseReasonKind {
    /// The case `ConnectionCloseReason.endOfInput`.
    case endOfInput

    /// The case `ConnectionCloseReason.transportFailed(_:)`.
    case transportFailed

    /// The case `ConnectionCloseReason.closedLocally`.
    case closedLocally
}

extension ConnectionCloseReason {
    /// The case of this reason, with no associated value.
    fileprivate var kind: CloseReasonKind {
        switch self {
        case .endOfInput:
            return .endOfInput
        case .transportFailed:
            return .transportFailed
        case .closedLocally:
            return .closedLocally
        }
    }

    /// The error of a `transportFailed(_:)` reason, or `nil` for each other
    /// reason.
    fileprivate var transportError: (any Error)? {
        switch self {
        case .transportFailed(let error):
            return error
        case .endOfInput, .closedLocally:
            return nil
        }
    }
}

/// The three ways that a connection can close. Not `private`, because a
/// parameterized test takes it as an argument.
enum CloseTrigger: CaseIterable, Sendable {
    /// The peer closes its side: the input stream finishes.
    case endOfInput

    /// The input stream fails with an error.
    case transportFailure

    /// The owner calls `close()`.
    case localClose

    /// The reason that the connection must give for this trigger.
    var expectedKind: CloseReasonKind {
        switch self {
        case .endOfInput:
            return .endOfInput
        case .transportFailure:
            return .transportFailed
        case .localClose:
            return .closedLocally
        }
    }
}

/// A peer that the test controls: it feeds the input of the connection, and
/// it can finish or fail that input.
private struct ScriptedPeer: Sendable {
    /// The transport that the connection under test runs over.
    let transport: ScriptedTransport

    /// Feeds the input stream of `transport`.
    private let input: AsyncThrowingStream<Data, any Error>.Continuation

    /// Creates a peer with an open input stream. The peer ignores the
    /// frames that the connection writes.
    init() {
        let incoming = AsyncThrowingStream<Data, any Error>.makeStream()
        let writes = AsyncStream<Data>.makeStream()
        transport = ScriptedTransport(bytes: incoming.stream, written: writes.continuation)
        input = incoming.continuation
    }

    /// Sends one framed message to the connection.
    ///
    /// - Parameter message: The JSON value to frame and send.
    /// - Throws: Rethrows the encoding failure.
    func send(_ message: JSONValue) throws {
        input.yield(try NDJSONCodec.encode(message))
    }

    /// Closes the connection in the way that `trigger` names.
    ///
    /// - Parameters:
    ///   - trigger: The way to close the connection.
    ///   - connection: The connection under test.
    func close(by trigger: CloseTrigger, _ connection: Connection) async {
        switch trigger {
        case .endOfInput:
            input.finish()
        case .transportFailure:
            input.finish(throwing: WireFailure())
        case .localClose:
            await connection.close()
        }
    }
}

/// Holds a connection for a handler that the connection itself calls, safe
/// to share between tasks. The test sets the connection after `init`.
private final class ConnectionBox: Sendable {
    /// The guarded connection.
    private let storage = Mutex<Connection?>(nil)

    /// The connection, or `nil` before the test sets it.
    var connection: Connection? {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

/// The prompt that the deferred-work test sends.
private let signalTestPrompt = PromptRequest(
    prompt: [.text(TextContent(text: "hello"))],
    sessionId: SessionId(rawValue: "session-1")
)

/// An agent whose prompt handler can defer work until after its response.
private struct SignalTestAgent: Agent {
    /// The connection that the factory gave this agent.
    let connection: AgentSideConnection

    /// The work that `prompt(_:)` defers until after its response, or `nil`
    /// for no work.
    var deferredWork: (@Sendable () async -> Void)?

    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(
            info: Implementation(name: "signal-test-agent", version: "0.0.0"),
            protocolVersion: .v2,
            capabilities: AgentCapabilities(session: SessionCapabilities())
        )
    }

    func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: SessionId(rawValue: "session-1"))
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

    /// Defers `deferredWork`, when it is set, and acknowledges the prompt.
    ///
    /// - Parameter params: The prompt request.
    /// - Returns: The acknowledgement.
    func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        if let deferredWork {
            connection.afterRespondingToCurrentRequest(deferredWork)
        }
        return PromptResponse.stubAcknowledgement
    }

    func sessionCancel(_ params: CancelSessionNotification) async {}
}

/// Works for `handlerWorkAfterCancellation`, also when the current task is
/// cancelled, and then records the end.
///
/// - Parameter record: Is set at the end of the work.
private func finishWorkPastCancellation(record: AtomicFlag) async {
    // A detached task does not get the cancellation of the current task, so
    // this work continues after the connection closed.
    await Task.detached { try? await Task.sleep(for: handlerWorkAfterCancellation) }.value
    record.set()
}

/// A request handler that runs until its cancellation, then continues to
/// work for `handlerWorkAfterCancellation`, and then records that it ended.
///
/// - Parameters:
///   - started: Gets one value when the handler starts.
///   - record: Is set at the end of the handler.
/// - Returns: The handler.
private func slowHandler(
    started: AsyncStream<Void>.Continuation,
    record: AtomicFlag
) -> Connection.RequestHandler {
    { _, _ in
        started.yield(())
        try? await Task.sleep(for: handlerWaitForCancellation)
        await finishWorkPastCancellation(record: record)
        return .null
    }
}

// MARK: - Connection

/// `Connection.closed` gives one reason, after the connection closed and
/// after each inbound handler ended.
@Suite struct ConnectionClosedSignalTests {
    @Test(.timeLimit(.minutes(closedSignalTestTimeout)), arguments: CloseTrigger.allCases)
    func everyWaiterGetsTheReasonOfTheFirstClose(trigger: CloseTrigger) async {
        let peer = ScriptedPeer()
        let connection = await Connection(transport: peer.transport)
        let earlyWaiter = Task { await connection.closed }

        await peer.close(by: trigger, connection)
        let early = await earlyWaiter.value
        await connection.close()
        let late = await connection.closed

        #expect(early.kind == trigger.expectedKind)
        #expect(late.kind == trigger.expectedKind)
    }

    @Test(.timeLimit(.minutes(closedSignalTestTimeout)))
    func transportFailureGivesTheErrorOfTheInputStream() async throws {
        let peer = ScriptedPeer()
        let connection = await Connection(transport: peer.transport)

        await peer.close(by: .transportFailure, connection)
        let reason = await connection.closed

        let error = try #require(reason.transportError)
        #expect(error is WireFailure)
    }

    @Test(.timeLimit(.minutes(closedSignalTestTimeout)), arguments: CloseTrigger.allCases)
    func signalComesAfterARunningRequestHandlerEnded(trigger: CloseTrigger) async throws {
        let peer = ScriptedPeer()
        let started = AsyncStream<Void>.makeStream()
        let record = AtomicFlag()
        let connection = await Connection(
            transport: peer.transport,
            requestHandler: slowHandler(started: started.continuation, record: record)
        )
        try peer.send(.object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("slow")]))
        var startedIterator = started.stream.makeAsyncIterator()
        _ = await startedIterator.next()

        await peer.close(by: trigger, connection)
        let reason = await connection.closed

        #expect(reason.kind == trigger.expectedKind)
        #expect(record.isSet)
    }

    @Test(.timeLimit(.minutes(closedSignalTestTimeout)))
    func batchRequestAfterCloseStartsNoHandler() async throws {
        let peer = ScriptedPeer()
        let box = ConnectionBox()
        let record = AtomicFlag()
        let connection = await Connection(
            transport: peer.transport,
            requestHandler: { _, _ in
                record.set()
                return .null
            },
            notificationHandler: { _, _ in await box.connection?.close() }
        )
        box.connection = connection

        try peer.send(
            .array([
                .object(["jsonrpc": .string("2.0"), "method": .string("stop")]),
                .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("late")]),
            ]))
        let reason = await connection.closed

        #expect(reason.kind == .closedLocally)
        #expect(!record.isSet)
    }
}

// MARK: - Role connections

/// `AgentSideConnection.closed` and `ClientSideConnection.closed` give the
/// reason of the underlying connection.
@Suite struct RoleConnectionClosedSignalTests {
    @Test(.timeLimit(.minutes(closedSignalTestTimeout)))
    func agentSideConnectionGivesEndOfInputWhenTheClientCloses() async {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let connection = await AgentSideConnection(stream: agentEnd) { SignalTestAgent(connection: $0) }

        clientEnd.close()

        #expect(await connection.closed.kind == .endOfInput)
    }

    @Test(.timeLimit(.minutes(closedSignalTestTimeout)))
    func agentSideConnectionGivesClosedLocallyAfterClose() async {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let connection = await AgentSideConnection(stream: agentEnd) { SignalTestAgent(connection: $0) }

        await connection.close()

        #expect(await connection.closed.kind == .closedLocally)
        _ = clientEnd
    }

    @Test(.timeLimit(.minutes(closedSignalTestTimeout)))
    func agentSideSignalComesAfterDeferredWorkOfARespondedRequestEnded() async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let started = AsyncStream<Void>.makeStream()
        let record = AtomicFlag()
        let agent = await AgentSideConnection(stream: agentEnd) { connection in
            SignalTestAgent(connection: connection) {
                started.continuation.yield(())
                await finishWorkPastCancellation(record: record)
            }
        }
        let client = await ClientSideConnection(stream: clientEnd) { _ in HandshakeClient() }
        _ = try await client.prompt(signalTestPrompt)
        var startedIterator = started.stream.makeAsyncIterator()
        _ = await startedIterator.next()

        await agent.close()
        let reason = await agent.closed

        #expect(reason.kind == .closedLocally)
        #expect(record.isSet)
        await client.close()
    }

    @Test(.timeLimit(.minutes(closedSignalTestTimeout)))
    func clientSideConnectionGivesEndOfInputWhenTheAgentCloses() async {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let connection = await ClientSideConnection(stream: clientEnd) { _ in HandshakeClient() }

        agentEnd.close()

        #expect(await connection.closed.kind == .endOfInput)
    }

    @Test(.timeLimit(.minutes(closedSignalTestTimeout)))
    func clientSideConnectionGivesClosedLocallyAfterClose() async {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let connection = await ClientSideConnection(stream: clientEnd) { _ in HandshakeClient() }

        await connection.close()

        #expect(await connection.closed.kind == .closedLocally)
        _ = agentEnd
    }
}
