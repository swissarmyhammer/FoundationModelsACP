import Foundation
import Testing

import FoundationModelsACP

// MARK: - Helpers

/// Transport stub whose incoming stream and outgoing writes are both driven
/// by the test: feed `bytes` via its continuation, observe writes on `written`.
private struct ScriptedTransport: ACPTransport {
    let bytes: AsyncThrowingStream<Data, any Error>
    let written: AsyncStream<Data>.Continuation

    /// Records the outgoing chunk for the test to observe; never fails.
    ///
    /// - Parameter data: The framed bytes the connection wrote.
    func write(_ data: Data) async throws {
        written.yield(data)
    }
}

// MARK: - Fail loud on disconnect

@Test(.timeLimit(.minutes(1))) func eofRejectsEveryPendingRequest() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await Connection(transport: clientEnd)
    let reader = WireReader(agentEnd)

    let pending = (0..<3).map { n in
        Task { try await client.request(method: "hang/\(n)") }
    }
    // All three are on the wire, so all three continuations are registered.
    for _ in 0..<3 {
        _ = try await reader.next()
    }
    agentEnd.close()

    for task in pending {
        await #expect(throws: ConnectionError.closed) {
            _ = try await task.value
        }
    }
}

@Test(.timeLimit(.minutes(1))) func streamErrorRejectsPendingRequests() async throws {
    struct WireFailure: Error {}
    let incoming = AsyncThrowingStream<Data, any Error>.makeStream()
    let writes = AsyncStream<Data>.makeStream()
    let client = await Connection(
        transport: ScriptedTransport(bytes: incoming.stream, written: writes.continuation)
    )

    let caller = Task { try await client.request(method: "hang") }
    var writeIterator = writes.stream.makeAsyncIterator()
    _ = await writeIterator.next()  // the request reached the wire
    incoming.continuation.finish(throwing: WireFailure())

    await #expect(throws: ConnectionError.closed) {
        _ = try await caller.value
    }
}

@Test(.timeLimit(.minutes(1))) func requestAfterDisconnectFailsImmediately() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await Connection(transport: clientEnd)
    agentEnd.close()

    // The first failure proves EOF was processed; everything after must fail
    // fast without touching the dead transport.
    await #expect(throws: ConnectionError.closed) {
        _ = try await client.request(method: "late")
    }
    await #expect(throws: ConnectionError.closed) {
        _ = try await client.request(method: "later")
    }
    await #expect(throws: ConnectionError.closed) {
        try await client.notify(method: "note")
    }
}

@Test(.timeLimit(.minutes(1))) func closeRejectsPendingAndRefusesNewRequests() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await Connection(transport: clientEnd)
    let reader = WireReader(agentEnd)

    let caller = Task { try await client.request(method: "hang") }
    _ = try await reader.next()  // the request is registered
    await client.close()

    await #expect(throws: ConnectionError.closed) {
        _ = try await caller.value
    }
    await #expect(throws: ConnectionError.closed) {
        _ = try await client.request(method: "late")
    }
}

@Test(.timeLimit(.minutes(1))) func closeCancelsInFlightInboundHandlers() async throws {
    // Fail loud covers the inbound direction too: a handler still running
    // when the connection shuts down must not be left dangling.
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let started = AsyncStream<Void>.makeStream()
    let cancelled = AsyncStream<Void>.makeStream()
    let agent = await Connection(
        transport: agentEnd,
        requestHandler: { _, _ in
            started.continuation.yield(())
            await withTaskCancellationHandler {
                try? await Task.sleep(for: .seconds(3600))
            } onCancel: {
                cancelled.continuation.yield(())
            }
            return .bool(true)
        }
    )

    try await send(
        .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("slow")]),
        over: clientEnd
    )
    var startedIterator = started.stream.makeAsyncIterator()
    _ = await startedIterator.next()

    await agent.close()

    var cancelledIterator = cancelled.stream.makeAsyncIterator()
    _ = await cancelledIterator.next()
}

@Test(.timeLimit(.minutes(1))) func closeFinishesStreamsDerivedFromOnClose() async throws {
    // The disconnect signal upper layers rely on to finish derived streams
    // (e.g. `ClientSideConnection`'s per-session update streams).
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let closed = AsyncStream<Void>.makeStream()
    let client = await Connection(
        transport: clientEnd,
        onClose: { closed.continuation.yield(()) }
    )
    agentEnd.close()

    var iterator = closed.stream.makeAsyncIterator()
    _ = await iterator.next()
    _ = client
}

// MARK: - Timeout

@Test(.timeLimit(.minutes(1))) func perRequestTimeoutFiresWhenPeerNeverAnswers() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await Connection(transport: clientEnd)

    await #expect(throws: ConnectionError.timedOut) {
        _ = try await client.request(method: "hang", timeout: .milliseconds(50))
    }
    _ = agentEnd  // keep the peer end alive so EOF does not race the timeout
}

@Test(.timeLimit(.minutes(1))) func connectionDefaultTimeoutApplies() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await Connection(transport: clientEnd, requestTimeout: .milliseconds(50))

    await #expect(throws: ConnectionError.timedOut) {
        _ = try await client.request(method: "hang")
    }
    _ = agentEnd
}

@Test(.timeLimit(.minutes(1))) func lateResponseAfterTimeoutIsIgnored() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await Connection(transport: clientEnd)
    let reader = WireReader(agentEnd)

    await #expect(throws: ConnectionError.timedOut) {
        _ = try await client.request(method: "slow", timeout: .milliseconds(30))
    }

    // Answer the timed-out request after the fact; the connection must drop
    // the response and stay fully usable for the next exchange.
    let first = try await reader.next()
    let firstID = try #require(requestID(of: first))
    try await send(
        .object(["jsonrpc": .string("2.0"), "id": firstID, "result": .string("too late")]),
        over: agentEnd
    )

    async let second = client.request(method: "prompt", timeout: .seconds(10))
    let request = try await reader.next()
    let secondID = try #require(requestID(of: request))
    try await send(
        .object(["jsonrpc": .string("2.0"), "id": secondID, "result": .bool(true)]),
        over: agentEnd
    )
    #expect(try await second == .bool(true))
}

// MARK: - Task cancellation

@Test(.timeLimit(.minutes(1))) func cancellingCallerTaskUnblocksPendingRequest() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await Connection(transport: clientEnd)
    let reader = WireReader(agentEnd)

    let caller = Task { try await client.request(method: "hang") }
    _ = try await reader.next()  // the request is registered
    caller.cancel()

    let outcome = await caller.result
    guard case .failure(let error) = outcome else {
        Issue.record("request should not succeed after cancellation")
        return
    }
    #expect(error is CancellationError)
    _ = agentEnd
}

@Test(.timeLimit(.minutes(1))) func cancellingCallerTaskSendsCancelRequestNotificationToPeer() async throws {
    // Local cancellation must never block on the peer — but it should tell
    // the peer, best-effort, so a slow handler on the other end can stop
    // doing work nobody is waiting for anymore.
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await Connection(transport: clientEnd)
    let reader = WireReader(agentEnd)

    let caller = Task { try await client.request(method: "hang") }
    let request = try await reader.next()
    let id = try #require(requestID(of: request))
    caller.cancel()

    let outcome = await caller.result
    guard case .failure(let error) = outcome else {
        Issue.record("request should not succeed after cancellation")
        return
    }
    #expect(error is CancellationError)

    let notification = try #require(try await reader.next())
    guard case .object(let fields) = notification else {
        Issue.record("expected a notification envelope, got \(notification)")
        return
    }
    #expect(fields["method"] == .string("$/cancel_request"))
    guard case .object(let params) = fields["params"] ?? .null else {
        Issue.record("expected params carrying the cancelled requestId")
        return
    }
    #expect(params["requestId"] == id)
}

@Test(.timeLimit(.minutes(1))) func cancellingAnAlreadyResolvedRequestSendsNoNotification() async throws {
    // No point telling the peer to stop working on a request that already
    // finished — and no pending entry survives to look up anyway.
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await Connection(transport: clientEnd)
    let reader = WireReader(agentEnd)

    let caller = Task { try await client.request(method: "quick") }
    let request = try await reader.next()
    let id = try #require(requestID(of: request))
    try await send(.object(["jsonrpc": .string("2.0"), "id": id, "result": .bool(true)]), over: agentEnd)
    #expect(try await caller.value == .bool(true))

    caller.cancel()  // no-op: the task already completed

    // Prove nothing extra arrived by round-tripping a fresh request; if a
    // stray `$/cancel_request` had been sent, it would show up first.
    async let answer = client.request(method: "ping")
    let next = try #require(try await reader.next())
    guard case .object(let fields) = next else {
        Issue.record("expected the next request envelope, got \(next)")
        return
    }
    #expect(fields["method"] == .string("ping"))
    let nextID = try #require(fields["id"])
    try await send(.object(["jsonrpc": .string("2.0"), "id": nextID, "result": .bool(true)]), over: agentEnd)
    #expect(try await answer == .bool(true))
}
