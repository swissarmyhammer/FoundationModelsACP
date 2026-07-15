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
