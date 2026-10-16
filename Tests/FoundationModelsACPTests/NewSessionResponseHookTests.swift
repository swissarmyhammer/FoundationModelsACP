import Foundation
import Synchronization
import Testing

@testable import FoundationModelsACP

// MARK: - Fixtures

/// The working directory of the first `session/new` call.
private let firstWorkingDirectory = AbsolutePath(rawValue: "/work/first")

/// The working directory of the second `session/new` call.
private let secondWorkingDirectory = AbsolutePath(rawValue: "/work/second")

/// The session that the agent creates for the first call.
private let firstSession = SessionId(rawValue: "hook-session-first")

/// The session that the agent creates for the second call.
private let secondSession = SessionId(rawValue: "hook-session-second")

/// The wire id of the `session/request_permission` request that the agent
/// sends directly after the `session/new` response.
private let permissionRequestId: JSONValue = .number(1)

/// The wire method of `session/request_permission`.
private let requestPermissionMethod = RoleRouting.wireMethod(for: "requestPermission", on: .client)

/// An ordered record of events, safe from any thread.
private final class SynchronousEventLog: Sendable {
    /// The events, in the order that they occurred.
    private let events = Mutex<[String]>([])

    /// Adds one event at the end.
    ///
    /// - Parameter event: The event.
    func append(_ event: String) {
        events.withLock { $0.append(event) }
    }

    /// The events, in the order that they occurred.
    var entries: [String] {
        events.withLock { $0 }
    }
}

/// The event that a `onResponse` hook records.
///
/// - Parameter sessionId: The session of the response.
/// - Returns: The event text.
private func hookEvent(_ sessionId: SessionId) -> String {
    "hook(\(sessionId.rawValue))"
}

/// The event that the permission handler records.
///
/// - Parameter sessionId: The session of the permission request.
/// - Returns: The event text.
private func requestEvent(_ sessionId: SessionId) -> String {
    "request(\(sessionId.rawValue))"
}

/// What the permission handler saw when it started.
private struct HandlerObservation: Sendable {
    /// The session of the permission request.
    let sessionId: SessionId

    /// `true` when the hook for that session ran before the handler started.
    let hookRanBefore: Bool
}

/// A client whose permission handler records its start in `log`, records if
/// the hook for the session already ran, and then gives a fixed outcome.
private struct OrderProbeClient: Client {
    /// The shared event log of the test.
    let log: SynchronousEventLog

    /// Gets one observation for each permission handler that starts.
    let observed: AsyncStream<HandlerObservation>.Continuation

    func sessionUpdate(_ notification: UpdateSessionNotification) async {}

    func requestPermission(_ request: RequestPermissionRequest) async throws -> RequestPermissionResponse {
        let hookRanBefore = log.entries.contains(hookEvent(request.sessionId))
        log.append(requestEvent(request.sessionId))
        observed.yield(HandlerObservation(sessionId: request.sessionId, hookRanBefore: hookRanBefore))
        return RequestPermissionResponse(outcome: .selectedStubOption)
    }

    func createElicitation(_ request: CreateElicitationRequest) async throws -> CreateElicitationResponse {
        throw RequestError.methodNotFound("createElicitation")
    }

    func elicitationComplete(_ notification: CompleteElicitationNotification) async {}
}

/// A `ClientSideConnection` that serves an `OrderProbeClient`, and the raw
/// agent end of its transport.
private struct HookHarness {
    /// The client side.
    let client: ClientSideConnection

    /// The raw agent end of the transport.
    let agentEnd: InMemoryTransport

    /// Reads the frames that the client writes.
    let reader: WireReader

    /// The shared event log of the test.
    let log: SynchronousEventLog

    /// One observation for each permission handler that started.
    let observed: AsyncStream<HandlerObservation>

    /// Feeds `observed`. `close()` finishes it.
    let observedFeed: AsyncStream<HandlerObservation>.Continuation

    /// Connects an `OrderProbeClient` to a raw agent end over
    /// `InMemoryTransport`.
    ///
    /// - Returns: The harness.
    static func connect() async -> HookHarness {
        let log = SynchronousEventLog()
        let observed = AsyncStream<HandlerObservation>.makeStream()
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let client = await ClientSideConnection(stream: clientEnd) { _ in
            OrderProbeClient(log: log, observed: observed.continuation)
        }
        // The close of the client ends the stream of observations. Then a
        // test that waits for a handler that never starts does not stay
        // suspended after the connection closed.
        Task {
            _ = await client.closed
            observed.continuation.finish()
        }
        return HookHarness(
            client: client,
            agentEnd: agentEnd,
            reader: WireReader(agentEnd),
            log: log,
            observed: observed.stream,
            observedFeed: observed.continuation
        )
    }

    /// Closes the client and the raw agent end, and ends the stream of
    /// observations. The close of the client ends each call that still
    /// waits for a response.
    func close() async {
        await client.close()
        agentEnd.close()
        observedFeed.finish()
    }

    /// Starts one `newSession(_:onResponse:)` call whose hook records into
    /// `log`.
    ///
    /// - Parameter cwd: The working directory of the request.
    /// - Returns: The task of the call.
    func startNewSession(cwd: AbsolutePath) -> Task<NewSessionResponse, any Error> {
        let client = client
        let log = log
        return Task {
            try await client.newSession(NewSessionRequest(cwd: cwd)) { response in
                log.append(hookEvent(response.sessionId))
            }
        }
    }

    /// Reads the next `session/new` request that the client wrote.
    ///
    /// - Returns: The wire id and the working directory of the request.
    /// - Throws: When the stream ends before a frame comes, or when the frame
    ///   has no id or no `cwd`.
    func nextNewSessionRequest() async throws -> (id: JSONValue, cwd: String) {
        let frame = try #require(try await reader.next())
        let id = try #require(requestID(of: frame))
        guard case .object(let fields) = frame, case .object(let params) = fields["params"] ?? .null,
            case .string(let cwd) = params["cwd"] ?? .null
        else {
            Issue.record("the frame is not a session/new request with a cwd: \(frame)")
            throw CancellationError()
        }
        return (id, cwd)
    }

    /// Waits for the next permission handler to start.
    ///
    /// - Returns: What the handler saw, or `nil` when the stream ended.
    func nextObservation() async -> HandlerObservation? {
        var iterator = observed.makeAsyncIterator()
        return await iterator.next()
    }
}

/// Writes several envelopes in one transport write, so that the reader gets
/// all of them at the same time.
///
/// - Parameters:
///   - messages: The envelopes, in wire order.
///   - transport: The transport end to write to.
/// - Throws: Rethrows encoding or transport-write failures.
private func sendTogether(_ messages: [JSONValue], over transport: some ACPTransport) async throws {
    var bytes = Data()
    for message in messages {
        bytes.append(try NDJSONCodec.encode(message))
    }
    try await transport.write(bytes)
}

// MARK: - Tests

/// `ClientSideConnection.newSession(_:onResponse:)` runs its hook in the read
/// loop, before the read loop dispatches the next frame.
@Suite struct NewSessionResponseHookTests {
    @Test func theHookRunsBeforeTheNextFrameIsDispatched() async throws {
        let harness = await HookHarness.connect()
        defer { await harness.close() }
        let call = harness.startNewSession(cwd: firstWorkingDirectory)
        let request = try await harness.nextNewSessionRequest()

        // The response and a request for the new session arrive in one write,
        // in this order.
        let permission = try JSONValue.encode(result: RequestPermissionRequest.stub(for: firstSession))
        try await sendTogether(
            [
                try responseEnvelope(id: request.id, result: NewSessionResponse(sessionId: firstSession)),
                RawPeerEnvelope.request(id: permissionRequestId, method: requestPermissionMethod, params: permission),
            ],
            over: harness.agentEnd
        )

        let observation = try #require(await harness.nextObservation())
        let response = try await call.value

        #expect(observation.sessionId == firstSession)
        #expect(observation.hookRanBefore)
        #expect(response.sessionId == firstSession)
        #expect(harness.log.entries == [hookEvent(firstSession), requestEvent(firstSession)])
    }

    @Test func eachHookGetsOnlyTheResponseToItsOwnCall() async throws {
        let harness = await HookHarness.connect()
        defer { await harness.close() }
        let firstLog = SynchronousEventLog()
        let secondLog = SynchronousEventLog()
        let client = harness.client
        let firstCall = Task {
            try await client.newSession(NewSessionRequest(cwd: firstWorkingDirectory)) { response in
                firstLog.append(hookEvent(response.sessionId))
            }
        }
        let secondCall = Task {
            try await client.newSession(NewSessionRequest(cwd: secondWorkingDirectory)) { response in
                secondLog.append(hookEvent(response.sessionId))
            }
        }

        // The two calls write in any order. Match each frame to its call by
        // its working directory.
        var ids: [String: JSONValue] = [:]
        for _ in 0..<2 {
            let request = try await harness.nextNewSessionRequest()
            ids[request.cwd] = request.id
        }
        let firstId = try #require(ids[firstWorkingDirectory.rawValue])
        let secondId = try #require(ids[secondWorkingDirectory.rawValue])

        // The agent answers the second call first.
        try await sendTogether(
            [
                try responseEnvelope(id: secondId, result: NewSessionResponse(sessionId: secondSession)),
                try responseEnvelope(id: firstId, result: NewSessionResponse(sessionId: firstSession)),
            ],
            over: harness.agentEnd
        )

        #expect(try await firstCall.value.sessionId == firstSession)
        #expect(try await secondCall.value.sessionId == secondSession)
        #expect(firstLog.entries == [hookEvent(firstSession)])
        #expect(secondLog.entries == [hookEvent(secondSession)])
    }

    @Test func anErrorResponseDoesNotRunTheHook() async throws {
        let harness = await HookHarness.connect()
        defer { await harness.close() }
        let call = harness.startNewSession(cwd: firstWorkingDirectory)
        let request = try await harness.nextNewSessionRequest()

        try await send(errorEnvelope(id: request.id, error: .invalidParams), over: harness.agentEnd)

        await #expect(throws: RequestError.self) {
            try await call.value
        }
        #expect(harness.log.entries.isEmpty)
    }

    @Test func aResultThatDoesNotDecodeDoesNotRunTheHook() async throws {
        let harness = await HookHarness.connect()
        defer { await harness.close() }
        let call = harness.startNewSession(cwd: firstWorkingDirectory)
        let request = try await harness.nextNewSessionRequest()

        // A `session/new` result must have a `sessionId`.
        try await send(responseEnvelope(id: request.id, result: JSONValue.object([:])), over: harness.agentEnd)

        await #expect(throws: DecodingError.self) {
            try await call.value
        }
        #expect(harness.log.entries.isEmpty)
    }

    @Test func aCloseBeforeTheResponseDoesNotRunTheHook() async throws {
        let harness = await HookHarness.connect()
        defer { await harness.close() }
        let call = harness.startNewSession(cwd: firstWorkingDirectory)
        _ = try await harness.nextNewSessionRequest()

        await harness.client.close()

        await #expect(throws: ConnectionError.self) {
            try await call.value
        }
        #expect(harness.log.entries.isEmpty)
    }
}
