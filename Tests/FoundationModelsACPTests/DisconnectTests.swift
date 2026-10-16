import Foundation
import Testing

import FoundationModelsACP

// MARK: - Fail loud on disconnect

@Test func eofRejectsEveryPendingRequest() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await Connection(transport: clientEnd)
    defer {
        await client.close()
        agentEnd.close()
    }
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

@Test func streamErrorRejectsPendingRequests() async throws {
    struct WireFailure: Error {}
    let incoming = AsyncThrowingStream<Data, any Error>.makeStream()
    let writes = AsyncStream<Data>.makeStream()
    // The close of the connection finishes the stream of writes. Thus the
    // wait for a write also ends when the connection closes first.
    let client = await Connection(
        transport: ScriptedTransport(bytes: incoming.stream, written: writes.continuation),
        onClose: { writes.continuation.finish() }
    )
    defer {
        await client.close()
        incoming.continuation.finish()
    }

    let caller = Task { try await client.request(method: "hang") }
    var writeIterator = writes.stream.makeAsyncIterator()
    _ = await writeIterator.next()  // the request reached the wire
    incoming.continuation.finish(throwing: WireFailure())

    await #expect(throws: ConnectionError.closed) {
        _ = try await caller.value
    }
}

@Test func requestAfterDisconnectFailsImmediately() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await Connection(transport: clientEnd)
    defer { await client.close() }
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

@Test func closeRejectsPendingAndRefusesNewRequests() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await Connection(transport: clientEnd)
    defer {
        await client.close()
        agentEnd.close()
    }
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

@Test func closeCancelsInFlightInboundHandlers() async throws {
    // Fail loud covers the inbound direction too: a handler still running
    // when the connection shuts down must not be left dangling.
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let started = AsyncStream<Void>.makeStream()
    let cancelled = AsyncStream<Void>.makeStream()
    let agent = await Connection(
        transport: agentEnd,
        requestHandler: { _, _ in
            // The end of the handler finishes the stream of cancels. Thus
            // the wait for the cancel also ends when the handler ends.
            defer { cancelled.continuation.finish() }
            started.continuation.yield(())
            await withTaskCancellationHandler {
                await waitForTaskCancellation()
            } onCancel: {
                cancelled.continuation.yield(())
            }
            return .bool(true)
        },
        // The close of the connection finishes the stream of starts. Thus
        // the wait for the start also ends when the connection closes first.
        onClose: { started.continuation.finish() }
    )
    defer {
        await agent.close()
        clientEnd.close()
    }

    try await send(
        .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("slow")]),
        over: clientEnd
    )
    var startedIterator = started.stream.makeAsyncIterator()
    try #require(await startedIterator.next() != nil)

    await agent.close()

    var cancelledIterator = cancelled.stream.makeAsyncIterator()
    try #require(await cancelledIterator.next() != nil)
}

@Test func closeFinishesStreamsDerivedFromOnClose() async throws {
    // The disconnect signal upper layers rely on to finish derived streams
    // (e.g. `ClientSideConnection`'s per-session update streams).
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let closed = AsyncStream<Void>.makeStream()
    let client = await Connection(
        transport: clientEnd,
        onClose: { closed.continuation.yield(()) }
    )
    defer { await client.close() }
    // The connection calls `onClose` before it gives the close reason. This
    // task finishes the stream after the close reason comes. Thus the wait
    // below also ends when the connection closes but does not call `onClose`.
    let finisher = Task {
        _ = await client.closed
        closed.continuation.finish()
    }
    agentEnd.close()

    var iterator = closed.stream.makeAsyncIterator()
    try #require(await iterator.next() != nil)
    await finisher.value
}

// MARK: - Timeout

// The tests drive each timeout by hand with `ManualRequestTimeouts`, so no
// test reads a clock. The peer end never answers the request. The request
// frame on the wire shows that the timeout started, because the connection
// starts it before it writes the frame. Each test requires that the timeout
// failed the request before it waits for the caller, so a broken timeout
// fails the test at once.

/// The time limit in the timeout tests. No clock measures it.
private let testRequestTimeout: Duration = .seconds(7)

@Test func perRequestTimeoutFiresWhenPeerNeverAnswers() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let timeouts = ManualRequestTimeouts()
    let client = await timeouts.connection(over: clientEnd)
    defer {
        await client.close()
        agentEnd.close()
    }
    let reader = WireReader(agentEnd)

    let caller = Task { try await client.request(method: "hang", timeout: testRequestTimeout) }
    _ = try #require(requestID(of: try await reader.next()))
    try #require(await timeouts.expireAll() == [testRequestTimeout])
    await #expect(throws: ConnectionError.timedOut) { try await caller.value }
}

@Test func connectionDefaultTimeoutApplies() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let timeouts = ManualRequestTimeouts()
    let client = await timeouts.connection(over: clientEnd, requestTimeout: testRequestTimeout)
    defer {
        await client.close()
        agentEnd.close()
    }
    let reader = WireReader(agentEnd)

    let caller = Task { try await client.request(method: "hang") }
    _ = try #require(requestID(of: try await reader.next()))
    try #require(await timeouts.expireAll() == [testRequestTimeout])
    await #expect(throws: ConnectionError.timedOut) { try await caller.value }
}

@Test func lateResponseAfterTimeoutIsIgnored() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let timeouts = ManualRequestTimeouts()
    let client = await timeouts.connection(over: clientEnd)
    defer {
        await client.close()
        agentEnd.close()
    }
    let reader = WireReader(agentEnd)

    let caller = Task { try await client.request(method: "slow", timeout: testRequestTimeout) }
    let first = try await reader.next()
    let firstID = try #require(requestID(of: first))
    try #require(await timeouts.expireAll() == [testRequestTimeout])
    await #expect(throws: ConnectionError.timedOut) { try await caller.value }

    // Answer the timed-out request after the fact; the connection must drop
    // the response and stay fully usable for the next exchange.
    try await send(
        .object(["jsonrpc": .string("2.0"), "id": firstID, "result": .string("too late")]),
        over: agentEnd
    )

    async let second = client.request(method: "prompt")
    let request = try await reader.next()
    let secondID = try #require(requestID(of: request))
    try await send(
        .object(["jsonrpc": .string("2.0"), "id": secondID, "result": .bool(true)]),
        over: agentEnd
    )
    #expect(try await second == .bool(true))
}

// MARK: - Task cancellation

@Test func cancellingCallerTaskUnblocksPendingRequest() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await Connection(transport: clientEnd)
    defer {
        await client.close()
        agentEnd.close()
    }
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

@Test func cancellingCallerTaskSendsCancelRequestNotificationToPeer() async throws {
    // Local cancellation must never block on the peer — but it should tell
    // the peer, best-effort, so a slow handler on the other end can stop
    // doing work nobody is waiting for anymore.
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await Connection(transport: clientEnd)
    defer {
        await client.close()
        agentEnd.close()
    }
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

@Test func cancellingAnAlreadyResolvedRequestSendsNoNotification() async throws {
    // No point telling the peer to stop working on a request that already
    // finished — and no pending entry survives to look up anyway.
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await Connection(transport: clientEnd)
    defer {
        await client.close()
        agentEnd.close()
    }
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
