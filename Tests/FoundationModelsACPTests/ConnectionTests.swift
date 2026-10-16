import Foundation
import Synchronization
import Testing

import FoundationModelsACP

// MARK: - Request/response correlation

@Test func requestResolvesWithHandlerResult() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agent = await Connection(
        transport: agentEnd,
        requestHandler: { method, params in
            .object(["method": .string(method), "params": params ?? .null])
        }
    )
    defer { await agent.close() }
    let client = await Connection(transport: clientEnd)
    defer { await client.close() }

    let result = try await client.request(method: "ping", params: .object(["n": .number(1)]))

    #expect(result == .object(["method": .string("ping"), "params": .object(["n": .number(1)])]))
}

/// Lets the handlers of one connection answer in the reverse order of their
/// number, so the responses come back out of submission order. It uses no
/// clock.
private actor ReverseTurns {
    /// The number whose handler answers next.
    private var next: Int
    /// The handlers that wait for their turn, keyed by their number.
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]

    /// - Parameter count: The number of handlers. The handler with the
    ///   largest number, `count - 1`, answers first.
    init(count: Int) {
        next = count - 1
    }

    /// Suspends until it is the turn of handler `number`, or until the task
    /// is cancelled. A close of the connection cancels each handler, so the
    /// wait also ends when the test fails and closes the connection.
    func wait(for number: Int) async {
        guard number != next, !Task.isCancelled else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiters[number] = $0 }
        } onCancel: {
            Task { await self.endWait(for: number) }
        }
    }

    /// Resumes the handler `number` when it still waits.
    private func endWait(for number: Int) {
        waiters.removeValue(forKey: number)?.resume()
    }

    /// Gives the turn to the next handler.
    func advance() {
        next -= 1
        waiters.removeValue(forKey: next)?.resume()
    }
}

/// A handler that doubles `n`, and answers only in its turn of `turns`.
///
/// - Parameter turns: The answer order of the connection.
/// - Returns: The handler.
private func reverseOrderDoubler(_ turns: ReverseTurns) -> Connection.RequestHandler {
    { _, params in
        guard case .object(let fields) = params ?? .null,
            case .number(let n) = fields["n", default: .null]
        else {
            throw RequestError.invalidParams
        }
        await turns.wait(for: Int(n))
        // A cancelled handler does not give the turn to the next handler.
        try Task.checkCancellation()
        await turns.advance()
        return .object(["doubled": .number(n * 2)])
    }
}

@Test func concurrentBidirectionalRequestsCorrelateToCallers() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let count = 10
    // The handlers answer in reverse order, so responses return out of
    // submission order and correlation is exercised, not just FIFO luck.
    let agent = await Connection(transport: agentEnd, requestHandler: reverseOrderDoubler(ReverseTurns(count: count)))
    defer { await agent.close() }
    let client = await Connection(transport: clientEnd, requestHandler: reverseOrderDoubler(ReverseTurns(count: count)))
    defer { await client.close() }

    try await withThrowingTaskGroup(of: Void.self) { group in
        for n in 0..<count {
            for connection in [client, agent] {
                group.addTask {
                    let result = try await connection.request(
                        method: "double",
                        params: .object(["n": .number(Double(n))])
                    )
                    #expect(result == .object(["doubled": .number(Double(n) * 2)]))
                }
            }
        }
        try await group.waitForAll()
    }
}

@Test func responseWithUnknownIdIsIgnored() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await Connection(transport: clientEnd)
    defer { await client.close() }
    defer { agentEnd.close() }
    let reader = WireReader(agentEnd)

    // A response nobody asked for must be dropped without poisoning the connection.
    try await send(
        .object(["jsonrpc": .string("2.0"), "id": .number(999), "result": .bool(true)]),
        over: agentEnd
    )

    async let answer = client.request(method: "ping")
    let request = try await reader.next()
    let id = try #require(requestID(of: request))
    #expect(id != .number(999))
    try await send(
        .object(["jsonrpc": .string("2.0"), "id": id, "result": .string("pong")]),
        over: agentEnd
    )
    #expect(try await answer == .string("pong"))
}

// MARK: - Inbound dispatch

@Test func inboundRequestIsAnsweredWithEchoedIdAndResult() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agent = await Connection(
        transport: agentEnd,
        requestHandler: { method, _ in .object(["ok": .bool(true), "method": .string(method)]) }
    )
    defer { await agent.close() }
    defer { clientEnd.close() }
    let reader = WireReader(clientEnd)

    // String ids must be echoed back exactly, not renumbered.
    try await send(
        .object(["jsonrpc": .string("2.0"), "id": .string("req-1"), "method": .string("hello")]),
        over: clientEnd
    )

    let response = try await reader.next()
    #expect(
        response
            == .object([
                "jsonrpc": .string("2.0"),
                "id": .string("req-1"),
                "result": .object(["ok": .bool(true), "method": .string("hello")]),
            ]))
}

@Test func slowRequestHandlerDoesNotDelaySubsequentNotification() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let started = AsyncStream<Void>.makeStream()
    let gate = AsyncStream<Void>.makeStream()
    let notes = AsyncStream<String>.makeStream()
    let agent = await Connection(
        transport: agentEnd,
        requestHandler: { _, _ in
            started.continuation.yield(())
            // Suspend until the test opens the gate — a stand-in for a
            // long-lived request like session/request_permission. The wait
            // also ends when a close cancels the handler.
            var release = gate.stream.makeAsyncIterator()
            _ = await release.next()
            return .string("slow done")
        },
        notificationHandler: { method, _ in notes.continuation.yield(method) },
        // The close ends each wait of the test on the two streams.
        onClose: {
            started.continuation.finish()
            notes.continuation.finish()
        }
    )
    defer { await agent.close() }
    let client = await Connection(transport: clientEnd)
    defer { await client.close() }

    let slow = Task { try await client.request(method: "slow") }
    // Wait until the slow handler is definitely running before notifying, so
    // the notification demonstrably arrives while the request is in flight.
    var startedIterator = started.stream.makeAsyncIterator()
    try #require(await startedIterator.next() != nil)
    try await client.notify(method: "poke")

    var notesIterator = notes.stream.makeAsyncIterator()
    #expect(await notesIterator.next() == "poke")

    gate.continuation.finish()
    #expect(try await slow.value == .string("slow done"))
}

@Test func slowRequestHandlerDoesNotDelayConcurrentRequest() async throws {
    // The head-of-line-blocking guard for requests, not just notifications:
    // a concurrent request (standing in for `session/cancel` arriving as a
    // request rather than a notification on some future revision) must not
    // wait behind a slow one.
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let started = AsyncStream<Void>.makeStream()
    let gate = AsyncStream<Void>.makeStream()
    let agent = await Connection(
        transport: agentEnd,
        requestHandler: { method, _ in
            if method == "slow" {
                started.continuation.yield(())
                // The wait also ends when a close cancels the handler.
                var release = gate.stream.makeAsyncIterator()
                _ = await release.next()
                return .string("slow done")
            }
            return .string("fast done")
        },
        // The close ends the wait of the test for the start.
        onClose: { started.continuation.finish() }
    )
    defer { await agent.close() }
    let client = await Connection(transport: clientEnd)
    defer { await client.close() }

    let slow = Task { try await client.request(method: "slow") }
    var startedIterator = started.stream.makeAsyncIterator()
    try #require(await startedIterator.next() != nil)

    let fast = try await client.request(method: "fast")
    #expect(fast == .string("fast done"))

    gate.continuation.finish()
    #expect(try await slow.value == .string("slow done"))
}

@Test func notificationsRouteToHandlerInSendOrder() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let notes = AsyncStream<String>.makeStream()
    let agent = await Connection(
        transport: agentEnd,
        notificationHandler: { method, _ in notes.continuation.yield(method) },
        // The close ends each wait of the test for a notification.
        onClose: { notes.continuation.finish() }
    )
    defer { await agent.close() }
    let client = await Connection(transport: clientEnd)
    defer { await client.close() }

    for n in 0..<5 {
        try await client.notify(method: "note/\(n)")
    }

    var iterator = notes.stream.makeAsyncIterator()
    for n in 0..<5 {
        #expect(await iterator.next() == "note/\(n)")
    }
}

@Test func outOfOrderNotificationsAreDeliveredWithoutReordering() async throws {
    // The connection makes no reordering claim of its own: whatever order
    // notifications land on the wire is the order the handler observes them
    // in, even when a "later" update names an id that already moved on. That
    // correlation (by messageId/toolCallId/terminalId) is a higher layer's
    // job; this layer must not buffer or resequence to "fix" it.
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let notes = AsyncStream<JSONValue>.makeStream()
    let agent = await Connection(
        transport: agentEnd,
        notificationHandler: { _, params in notes.continuation.yield(params ?? .null) },
        // The close ends each wait of the test for a notification.
        onClose: { notes.continuation.finish() }
    )
    defer { await agent.close() }
    let client = await Connection(transport: clientEnd)
    defer { await client.close() }

    // A "later" toolCallId=1 update followed by an out-of-order toolCallId=2
    // arriving after it, then a late toolCallId=1 stray update.
    try await client.notify(method: "update", params: .object(["toolCallId": .string("1"), "seq": .number(1)]))
    try await client.notify(method: "update", params: .object(["toolCallId": .string("2"), "seq": .number(2)]))
    try await client.notify(method: "update", params: .object(["toolCallId": .string("1"), "seq": .number(3)]))

    var iterator = notes.stream.makeAsyncIterator()
    #expect(await iterator.next() == .object(["toolCallId": .string("1"), "seq": .number(1)]))
    #expect(await iterator.next() == .object(["toolCallId": .string("2"), "seq": .number(2)]))
    #expect(await iterator.next() == .object(["toolCallId": .string("1"), "seq": .number(3)]))
}

// MARK: - Errors

@Test func unknownMethodIsAnsweredWithMethodNotFound() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agent = await Connection(transport: agentEnd)
    defer { await agent.close() }
    let client = await Connection(transport: clientEnd)
    defer { await client.close() }

    do {
        _ = try await client.request(method: "no/such")
        Issue.record("request should have failed with method-not-found")
    } catch let error as RequestError {
        #expect(error.code == .methodNotFound)
    }
}

@Test func handlerRequestErrorPropagatesCodeMessageAndData() async throws {
    let thrown = RequestError(
        code: .resourceNotFound,
        message: "Resource not found",
        data: .object(["uri": .string("file:///missing")])
    )
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agent = await Connection(transport: agentEnd, requestHandler: { _, _ in throw thrown })
    defer { await agent.close() }
    let client = await Connection(transport: clientEnd)
    defer { await client.close() }

    do {
        _ = try await client.request(method: "op/whatever")
        Issue.record("request should have failed with the handler's error")
    } catch let error as RequestError {
        #expect(error == thrown)
    }
}

@Test func handlerFailureMapsToInternalError() async throws {
    struct Boom: Error {}
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agent = await Connection(transport: agentEnd, requestHandler: { _, _ in throw Boom() })
    defer { await agent.close() }
    let client = await Connection(transport: clientEnd)
    defer { await client.close() }

    do {
        _ = try await client.request(method: "explode")
        Issue.record("request should have failed with an internal error")
    } catch let error as RequestError {
        #expect(error.code == .internalError)
    }
}

@Test func unclassifiableMessageWithIdIsAnsweredInvalidRequest() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agent = await Connection(transport: agentEnd)
    defer { await agent.close() }
    defer { clientEnd.close() }
    let reader = WireReader(clientEnd)

    // No method and no result/error: not a request, notification, or response.
    try await send(.object(["jsonrpc": .string("2.0"), "id": .number(7)]), over: clientEnd)

    let response = try #require(try await reader.next())
    guard case .object(let fields) = response else {
        Issue.record("expected an error response object, got \(response)")
        return
    }
    #expect(fields["id"] == .number(7))
    guard case .object(let errorFields) = fields["error", default: .null] else {
        Issue.record("expected an error member in \(response)")
        return
    }
    #expect(errorFields["code"] == .number(-32600))
}

@Test func handlerAuthenticationRequiredErrorRoundTripsToCaller() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agent = await Connection(
        transport: agentEnd,
        requestHandler: { _, _ in throw RequestError.authenticationRequired }
    )
    defer { await agent.close() }
    let client = await Connection(transport: clientEnd)
    defer { await client.close() }

    do {
        _ = try await client.request(method: "session/new")
        Issue.record("request should have failed with authentication-required")
    } catch let error as RequestError {
        #expect(error == RequestError.authenticationRequired)
    }
}

@Test func messageWithoutJsonrpcVersionIsAnsweredInvalidRequest() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agent = await Connection(transport: agentEnd, requestHandler: { _, _ in .bool(true) })
    defer { await agent.close() }
    defer { clientEnd.close() }
    let reader = WireReader(clientEnd)

    // No `jsonrpc` member: the request must be rejected, not dispatched —
    // a result response here would prove the handler ran.
    try await send(.object(["id": .number(5), "method": .string("hello")]), over: clientEnd)

    let response = try #require(try await reader.next())
    guard case .object(let fields) = response else {
        Issue.record("expected an error response object, got \(response)")
        return
    }
    #expect(fields["id"] == .number(5))
    guard case .object(let errorFields) = fields["error", default: .null] else {
        Issue.record("expected an error member in \(response)")
        return
    }
    #expect(errorFields["code"] == .number(-32600))
}

@Test func messageWithWrongJsonrpcVersionIsAnsweredInvalidRequest() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agent = await Connection(transport: agentEnd, requestHandler: { _, _ in .bool(true) })
    defer { await agent.close() }
    defer { clientEnd.close() }
    let reader = WireReader(clientEnd)

    try await send(
        .object(["jsonrpc": .string("1.0"), "id": .number(6), "method": .string("hello")]),
        over: clientEnd
    )

    let response = try #require(try await reader.next())
    guard case .object(let fields) = response else {
        Issue.record("expected an error response object, got \(response)")
        return
    }
    #expect(fields["id"] == .number(6))
    guard case .object(let errorFields) = fields["error", default: .null] else {
        Issue.record("expected an error member in \(response)")
        return
    }
    #expect(errorFields["code"] == .number(-32600))
}

@Test func responseWithoutJsonrpcVersionFailsCallerInsteadOfHanging() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await Connection(transport: clientEnd)
    defer { await client.close() }
    defer { agentEnd.close() }
    let reader = WireReader(agentEnd)

    async let answer = client.request(method: "ping")
    let request = try await reader.next()
    let id = try #require(requestID(of: request))

    // A response-shaped envelope without the version: the awaiting caller
    // must fail loud immediately, not hang (timeouts are opt-in).
    try await send(.object(["id": id, "result": .bool(true)]), over: agentEnd)
    do {
        _ = try await answer
        Issue.record("request should have failed on the unversioned response")
    } catch let error as RequestError {
        #expect(error.code == .invalidRequest)
    }

    // And no -32600 reply may be echoed back — JSON-RPC only answers
    // requests, and the id could collide with one of the peer's own calls.
    // The next message on the wire must be the next request, nothing else.
    async let second = client.request(method: "ping2")
    let next = try #require(try await reader.next())
    guard case .object(let fields) = next else {
        Issue.record("expected the next request envelope, got \(next)")
        return
    }
    #expect(fields["method"] == .string("ping2"))
    let secondID = try #require(fields["id"])
    try await send(
        .object(["jsonrpc": .string("2.0"), "id": secondID, "result": .bool(true)]),
        over: agentEnd
    )
    #expect(try await second == .bool(true))
}

@Test func requestErrorProvidesSpecCataloguedConstructors() {
    #expect(RequestError.parseError.code == .parseError)
    #expect(RequestError.invalidRequest.code == .invalidRequest)
    #expect(RequestError.methodNotFound("session/nope").code == .methodNotFound)
    #expect(RequestError.invalidParams.code == .invalidParams)
    #expect(RequestError.internalError(detail: "boom").code == .internalError)
    #expect(RequestError.requestCancelled.code == .requestCancelled)
    #expect(RequestError.authenticationRequired.code == .authenticationRequired)
    #expect(RequestError.resourceNotFound(uri: "file:///x").code == .resourceNotFound)
}

// MARK: - `$/cancel_request` (protocol-level, connection layer only)

@Test func cancelRequestNotificationCancelsRunningHandlerAndAnswersRequestCancelled()
    async throws
{
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let started = AsyncStream<Void>.makeStream()
    let agent = await Connection(
        transport: agentEnd,
        requestHandler: { _, _ in
            started.continuation.yield(())
            // Ends only when the task is cancelled, unlike a plain
            // suspension on an external gate — the deterministic way to
            // prove a handler was actually cancelled rather than merely
            // outliving the test.
            await waitForTaskCancellation()
            throw CancellationError()
        },
        // The close ends the wait of the test for the start.
        onClose: { started.continuation.finish() }
    )
    defer { await agent.close() }
    defer { clientEnd.close() }
    let reader = WireReader(clientEnd)

    try await send(
        .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("slow")]),
        over: clientEnd
    )
    var startedIterator = started.stream.makeAsyncIterator()
    try #require(await startedIterator.next() != nil)

    try await send(
        .object([
            "jsonrpc": .string("2.0"),
            "method": .string("$/cancel_request"),
            "params": .object(["requestId": .number(1)]),
        ]),
        over: clientEnd
    )

    let response = try #require(try await reader.next())
    guard case .object(let fields) = response, case .object(let error) = fields["error"] ?? .null else {
        Issue.record("expected an error response, got \(response)")
        return
    }
    #expect(fields["id"] == .number(1))
    #expect(error["code"] == .number(-32800))
}

@Test func cancelRequestNotificationForUnknownIdIsANoOp() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agent = await Connection(transport: agentEnd, requestHandler: { _, _ in .bool(true) })
    defer { await agent.close() }
    defer { clientEnd.close() }
    let reader = WireReader(clientEnd)

    // Nothing pending named "999" — cancellation racing completion (or a
    // stray duplicate) must not crash the read loop or answer anything.
    try await send(
        .object([
            "jsonrpc": .string("2.0"),
            "method": .string("$/cancel_request"),
            "params": .object(["requestId": .number(999)]),
        ]),
        over: clientEnd
    )

    // The connection is still fully usable afterward.
    try await send(
        .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("ping")]),
        over: clientEnd
    )
    let response = try #require(try await reader.next())
    #expect(response == .object(["jsonrpc": .string("2.0"), "id": .number(1), "result": .bool(true)]))
}

@Test func cancelRequestIsNeverRoutedToARequestOrNotificationHandler() async throws {
    // `$/cancel_request` is protocol-level (spec: served at the connection
    // layer on both sides, never on a role protocol) — it must not reach
    // either handler the connection was configured with.
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let sawCancelRequest = Mutex(false)
    let agent = await Connection(
        transport: agentEnd,
        requestHandler: { method, _ in
            if method == "$/cancel_request" { sawCancelRequest.withLock { $0 = true } }
            return .bool(true)
        },
        notificationHandler: { method, _ in
            if method == "$/cancel_request" { sawCancelRequest.withLock { $0 = true } }
        }
    )
    defer { await agent.close() }
    defer { clientEnd.close() }
    let reader = WireReader(clientEnd)

    try await send(
        .object([
            "jsonrpc": .string("2.0"),
            "method": .string("$/cancel_request"),
            "params": .object(["requestId": .number(42)]),
        ]),
        over: clientEnd
    )
    // Prove the connection is still alive and nothing was routed by round
    // tripping an ordinary request right after.
    try await send(
        .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("ping")]),
        over: clientEnd
    )
    _ = try await reader.next()

    #expect(!sawCancelRequest.withLock { $0 })
}

// MARK: - Duplicate inbound request ids

@Test func duplicateInboundRequestIdWhileFirstIsInFlightIsRejectedNotMisdirected()
    async throws
{
    // `inboundTasks` has one slot per wire id — a second request reusing an
    // id still in flight must not silently overwrite the first task's handle
    // (which would make it uncancellable and unreachable by a later
    // `$/cancel_request`) or otherwise get misdirected. It is rejected
    // immediately, and the first request keeps running untouched.
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let started = AsyncStream<Void>.makeStream()
    let gate = AsyncStream<Void>.makeStream()
    let agent = await Connection(
        transport: agentEnd,
        requestHandler: { _, _ in
            started.continuation.yield(())
            // The wait also ends when a close cancels the handler.
            var release = gate.stream.makeAsyncIterator()
            _ = await release.next()
            return .string("first done")
        },
        // The close ends the wait of the test for the start.
        onClose: { started.continuation.finish() }
    )
    defer { await agent.close() }
    defer { clientEnd.close() }
    let reader = WireReader(clientEnd)

    try await send(
        .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("slow")]),
        over: clientEnd
    )
    var startedIterator = started.stream.makeAsyncIterator()
    try #require(await startedIterator.next() != nil)

    // A second request reusing the same still-in-flight id.
    try await send(
        .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("slow")]),
        over: clientEnd
    )

    let collisionResponse = try #require(try await reader.next())
    guard case .object(let fields) = collisionResponse, case .object(let error) = fields["error"] ?? .null else {
        Issue.record("expected the colliding request to be rejected, got \(collisionResponse)")
        return
    }
    #expect(fields["id"] == .number(1))
    #expect(error["code"] == .number(-32600))

    // The first request is still running, unaffected by the collision;
    // releasing the gate lets it complete and answer normally.
    gate.continuation.finish()
    let firstResponse = try #require(try await reader.next())
    #expect(firstResponse == .object(["jsonrpc": .string("2.0"), "id": .number(1), "result": .string("first done")]))
}

// MARK: - Batch JSON-RPC

@Test func batchOfRequestsIsAnsweredWithOneAggregateBatchResponse() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agent = await Connection(
        transport: agentEnd,
        requestHandler: { method, _ in .object(["echo": .string(method)]) }
    )
    defer { await agent.close() }
    defer { clientEnd.close() }

    try await clientEnd.write(
        NDJSONCodec.encode(
            JSONValue.array([
                .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("a")]),
                .object(["jsonrpc": .string("2.0"), "id": .number(2), "method": .string("b")]),
            ])
        )
    )

    var iterator = NDJSONCodec.frames(from: clientEnd.bytes, logger: .disabled).makeAsyncIterator()
    let frame = try await iterator.next()
    guard case .message(.array(let responses)) = frame else {
        Issue.record("expected a batch-response array, got \(String(describing: frame))")
        return
    }
    #expect(responses.count == 2)
    let byId = Dictionary(
        uniqueKeysWithValues: responses.compactMap { response -> (JSONValue, JSONValue)? in
            guard case .object(let fields) = response, let id = fields["id"] else { return nil }
            return (id, fields["result"] ?? .null)
        }
    )
    #expect(byId[.number(1)] == .object(["echo": .string("a")]))
    #expect(byId[.number(2)] == .object(["echo": .string("b")]))
}

@Test func batchOfOnlyNotificationsProducesNoReply() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let notes = AsyncStream<String>.makeStream()
    let agent = await Connection(
        transport: agentEnd,
        notificationHandler: { method, _ in notes.continuation.yield(method) },
        // The close ends each wait of the test for a notification.
        onClose: { notes.continuation.finish() }
    )
    defer { await agent.close() }
    defer { clientEnd.close() }

    try await clientEnd.write(
        NDJSONCodec.encode(
            JSONValue.array([
                .object(["jsonrpc": .string("2.0"), "method": .string("note/a")]),
                .object(["jsonrpc": .string("2.0"), "method": .string("note/b")]),
            ])
        )
    )

    var iterator = notes.stream.makeAsyncIterator()
    #expect(await iterator.next() == "note/a")
    #expect(await iterator.next() == "note/b")

    // Prove no reply arrived for the batch: the next thing on the wire must
    // be something written afterward, not a spurious batch acknowledgement.
    try await send(.object(["jsonrpc": .string("2.0"), "method": .string("sentinel")]), over: agentEnd)
    let reader = WireReader(clientEnd)
    let received = try await reader.next()
    #expect(received == .object(["jsonrpc": .string("2.0"), "method": .string("sentinel")]))
}

@Test func batchMixingRequestsAndNotificationsOwesOnlyTheRequests() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let notes = AsyncStream<String>.makeStream()
    let agent = await Connection(
        transport: agentEnd,
        requestHandler: { _, _ in .bool(true) },
        notificationHandler: { method, _ in notes.continuation.yield(method) },
        // The close ends the wait of the test for the notification.
        onClose: { notes.continuation.finish() }
    )
    defer { await agent.close() }
    defer { clientEnd.close() }

    try await clientEnd.write(
        NDJSONCodec.encode(
            JSONValue.array([
                .object(["jsonrpc": .string("2.0"), "method": .string("note/only")]),
                .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("call")]),
            ])
        )
    )

    var notesIterator = notes.stream.makeAsyncIterator()
    #expect(await notesIterator.next() == "note/only")

    var iterator = NDJSONCodec.frames(from: clientEnd.bytes, logger: .disabled).makeAsyncIterator()
    let frame = try await iterator.next()
    guard case .message(.array(let responses)) = frame else {
        Issue.record("expected a batch-response array, got \(String(describing: frame))")
        return
    }
    #expect(responses.count == 1)
    #expect(requestID(of: responses.first) == .number(1))
}

// MARK: - Malformed frame (clean protocol error, not a crashed read loop)

@Test func malformedFrameGetsCleanParseErrorAndReadLoopContinues() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agent = await Connection(transport: agentEnd, requestHandler: { _, _ in .bool(true) })
    defer { await agent.close() }
    defer { clientEnd.close() }
    let reader = WireReader(clientEnd)

    try await sendRawLine("not json at all", over: clientEnd)

    let parseErrorResponse = try #require(try await reader.next())
    guard case .object(let fields) = parseErrorResponse, case .object(let error) = fields["error"] ?? .null else {
        Issue.record("expected a parse-error envelope, got \(parseErrorResponse)")
        return
    }
    #expect(fields["id"] == .null)
    #expect(error["code"] == .number(-32700))

    // The read loop survived: a well-formed request right after still works.
    try await send(
        .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("ping")]),
        over: clientEnd
    )
    let response = try #require(try await reader.next())
    #expect(response == .object(["jsonrpc": .string("2.0"), "id": .number(1), "result": .bool(true)]))
}

// MARK: - _meta passthrough

@Test func metaFieldsPassThroughParamsAndResultUnchanged() async throws {
    let params: JSONValue = .object([
        "_meta": .object(["traceId": .string("t-1")]),
        "text": .string("hello"),
    ])
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agent = await Connection(
        transport: agentEnd,
        requestHandler: { _, params in params ?? .null }
    )
    defer { await agent.close() }
    let client = await Connection(transport: clientEnd)
    defer { await client.close() }

    let result = try await client.request(method: "echo", params: params)

    #expect(result == params)
}
