import Foundation
import Synchronization
import Testing

import FoundationModelsACP

// MARK: - Request/response correlation

@Test(.timeLimit(.minutes(1))) func requestResolvesWithHandlerResult() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agent = await Connection(
        transport: agentEnd,
        requestHandler: { method, params in
            .object(["method": .string(method), "params": params ?? .null])
        }
    )
    let client = await Connection(transport: clientEnd)

    let result = try await client.request(method: "ping", params: .object(["n": .number(1)]))

    #expect(result == .object(["method": .string("ping"), "params": .object(["n": .number(1)])]))
    _ = agent
}

@Test(.timeLimit(.minutes(1))) func concurrentBidirectionalRequestsCorrelateToCallers() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    // Stagger completions so responses return out of submission order and
    // correlation is exercised, not just FIFO luck.
    let doubler: Connection.RequestHandler = { _, params in
        guard case .object(let fields) = params ?? .null,
            case .number(let n) = fields["n", default: .null]
        else {
            throw RequestError.invalidParams
        }
        try await Task.sleep(for: .milliseconds(10 - Int(n)))
        return .object(["doubled": .number(n * 2)])
    }
    let agent = await Connection(transport: agentEnd, requestHandler: doubler)
    let client = await Connection(transport: clientEnd, requestHandler: doubler)

    try await withThrowingTaskGroup(of: Void.self) { group in
        for n in 0..<10 {
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

@Test(.timeLimit(.minutes(1))) func responseWithUnknownIdIsIgnored() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await Connection(transport: clientEnd)
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

@Test(.timeLimit(.minutes(1))) func inboundRequestIsAnsweredWithEchoedIdAndResult() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agent = await Connection(
        transport: agentEnd,
        requestHandler: { method, _ in .object(["ok": .bool(true), "method": .string(method)]) }
    )
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
    _ = agent
}

@Test(.timeLimit(.minutes(1))) func slowRequestHandlerDoesNotDelaySubsequentNotification() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let started = AsyncStream<Void>.makeStream()
    let gate = AsyncStream<Void>.makeStream()
    let notes = AsyncStream<String>.makeStream()
    let agent = await Connection(
        transport: agentEnd,
        requestHandler: { _, _ in
            started.continuation.yield(())
            // Suspend until the test opens the gate — a stand-in for a
            // long-lived request like session/request_permission.
            var release = gate.stream.makeAsyncIterator()
            _ = await release.next()
            return .string("slow done")
        },
        notificationHandler: { method, _ in notes.continuation.yield(method) }
    )
    let client = await Connection(transport: clientEnd)

    let slow = Task { try await client.request(method: "slow") }
    // Wait until the slow handler is definitely running before notifying, so
    // the notification demonstrably arrives while the request is in flight.
    var startedIterator = started.stream.makeAsyncIterator()
    _ = await startedIterator.next()
    try await client.notify(method: "poke")

    var notesIterator = notes.stream.makeAsyncIterator()
    #expect(await notesIterator.next() == "poke")

    gate.continuation.finish()
    #expect(try await slow.value == .string("slow done"))
    _ = agent
}

@Test(.timeLimit(.minutes(1))) func slowRequestHandlerDoesNotDelayConcurrentRequest() async throws {
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
                var release = gate.stream.makeAsyncIterator()
                _ = await release.next()
                return .string("slow done")
            }
            return .string("fast done")
        }
    )
    let client = await Connection(transport: clientEnd)

    let slow = Task { try await client.request(method: "slow") }
    var startedIterator = started.stream.makeAsyncIterator()
    _ = await startedIterator.next()

    let fast = try await client.request(method: "fast")
    #expect(fast == .string("fast done"))

    gate.continuation.finish()
    #expect(try await slow.value == .string("slow done"))
    _ = agent
}

@Test(.timeLimit(.minutes(1))) func notificationsRouteToHandlerInSendOrder() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let notes = AsyncStream<String>.makeStream()
    let agent = await Connection(
        transport: agentEnd,
        notificationHandler: { method, _ in notes.continuation.yield(method) }
    )
    let client = await Connection(transport: clientEnd)

    for n in 0..<5 {
        try await client.notify(method: "note/\(n)")
    }

    var iterator = notes.stream.makeAsyncIterator()
    for n in 0..<5 {
        #expect(await iterator.next() == "note/\(n)")
    }
    _ = agent
}

@Test(.timeLimit(.minutes(1))) func outOfOrderNotificationsAreDeliveredWithoutReordering() async throws {
    // The connection makes no reordering claim of its own: whatever order
    // notifications land on the wire is the order the handler observes them
    // in, even when a "later" update names an id that already moved on. That
    // correlation (by messageId/toolCallId/terminalId) is a higher layer's
    // job; this layer must not buffer or resequence to "fix" it.
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let notes = AsyncStream<JSONValue>.makeStream()
    let agent = await Connection(
        transport: agentEnd,
        notificationHandler: { _, params in notes.continuation.yield(params ?? .null) }
    )
    let client = await Connection(transport: clientEnd)

    // A "later" toolCallId=1 update followed by an out-of-order toolCallId=2
    // arriving after it, then a late toolCallId=1 stray update.
    try await client.notify(method: "update", params: .object(["toolCallId": .string("1"), "seq": .number(1)]))
    try await client.notify(method: "update", params: .object(["toolCallId": .string("2"), "seq": .number(2)]))
    try await client.notify(method: "update", params: .object(["toolCallId": .string("1"), "seq": .number(3)]))

    var iterator = notes.stream.makeAsyncIterator()
    #expect(await iterator.next() == .object(["toolCallId": .string("1"), "seq": .number(1)]))
    #expect(await iterator.next() == .object(["toolCallId": .string("2"), "seq": .number(2)]))
    #expect(await iterator.next() == .object(["toolCallId": .string("1"), "seq": .number(3)]))
    _ = agent
}

// MARK: - Errors

@Test(.timeLimit(.minutes(1))) func unknownMethodIsAnsweredWithMethodNotFound() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agent = await Connection(transport: agentEnd)
    let client = await Connection(transport: clientEnd)

    do {
        _ = try await client.request(method: "no/such")
        Issue.record("request should have failed with method-not-found")
    } catch let error as RequestError {
        #expect(error.code == .methodNotFound)
    }
    _ = agent
}

@Test(.timeLimit(.minutes(1))) func handlerRequestErrorPropagatesCodeMessageAndData() async throws {
    let thrown = RequestError(
        code: .resourceNotFound,
        message: "Resource not found",
        data: .object(["uri": .string("file:///missing")])
    )
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agent = await Connection(transport: agentEnd, requestHandler: { _, _ in throw thrown })
    let client = await Connection(transport: clientEnd)

    do {
        _ = try await client.request(method: "op/whatever")
        Issue.record("request should have failed with the handler's error")
    } catch let error as RequestError {
        #expect(error == thrown)
    }
    _ = agent
}

@Test(.timeLimit(.minutes(1))) func handlerFailureMapsToInternalError() async throws {
    struct Boom: Error {}
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agent = await Connection(transport: agentEnd, requestHandler: { _, _ in throw Boom() })
    let client = await Connection(transport: clientEnd)

    do {
        _ = try await client.request(method: "explode")
        Issue.record("request should have failed with an internal error")
    } catch let error as RequestError {
        #expect(error.code == .internalError)
    }
    _ = agent
}

@Test(.timeLimit(.minutes(1))) func unclassifiableMessageWithIdIsAnsweredInvalidRequest() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agent = await Connection(transport: agentEnd)
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
    _ = agent
}

@Test(.timeLimit(.minutes(1))) func handlerAuthenticationRequiredErrorRoundTripsToCaller() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agent = await Connection(
        transport: agentEnd,
        requestHandler: { _, _ in throw RequestError.authenticationRequired }
    )
    let client = await Connection(transport: clientEnd)

    do {
        _ = try await client.request(method: "session/new")
        Issue.record("request should have failed with authentication-required")
    } catch let error as RequestError {
        #expect(error == RequestError.authenticationRequired)
    }
    _ = agent
}

@Test(.timeLimit(.minutes(1))) func messageWithoutJsonrpcVersionIsAnsweredInvalidRequest() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agent = await Connection(transport: agentEnd, requestHandler: { _, _ in .bool(true) })
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
    _ = agent
}

@Test(.timeLimit(.minutes(1))) func messageWithWrongJsonrpcVersionIsAnsweredInvalidRequest() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agent = await Connection(transport: agentEnd, requestHandler: { _, _ in .bool(true) })
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
    _ = agent
}

@Test(.timeLimit(.minutes(1))) func responseWithoutJsonrpcVersionFailsCallerInsteadOfHanging() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let client = await Connection(transport: clientEnd)
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

@Test(.timeLimit(.minutes(1))) func cancelRequestNotificationCancelsRunningHandlerAndAnswersRequestCancelled()
    async throws
{
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let started = AsyncStream<Void>.makeStream()
    let agent = await Connection(
        transport: agentEnd,
        requestHandler: { _, _ in
            started.continuation.yield(())
            // Task.sleep observes cancellation and throws, unlike a plain
            // suspension on an external gate — the deterministic way to
            // prove a handler was actually cancelled rather than merely
            // outliving the test.
            while !Task.isCancelled {
                try await Task.sleep(for: .milliseconds(5))
            }
            throw CancellationError()
        }
    )
    let reader = WireReader(clientEnd)

    try await send(
        .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("slow")]),
        over: clientEnd
    )
    var startedIterator = started.stream.makeAsyncIterator()
    _ = await startedIterator.next()

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
    _ = agent
}

@Test(.timeLimit(.minutes(1))) func cancelRequestNotificationForUnknownIdIsANoOp() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agent = await Connection(transport: agentEnd, requestHandler: { _, _ in .bool(true) })
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
    _ = agent
}

@Test(.timeLimit(.minutes(1))) func cancelRequestIsNeverRoutedToARequestOrNotificationHandler() async throws {
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
    _ = agent
}

// MARK: - Duplicate inbound request ids

@Test(.timeLimit(.minutes(1))) func duplicateInboundRequestIdWhileFirstIsInFlightIsRejectedNotMisdirected()
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
            var release = gate.stream.makeAsyncIterator()
            _ = await release.next()
            return .string("first done")
        }
    )
    let reader = WireReader(clientEnd)

    try await send(
        .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("slow")]),
        over: clientEnd
    )
    var startedIterator = started.stream.makeAsyncIterator()
    _ = await startedIterator.next()

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
    _ = agent
}

// MARK: - Batch JSON-RPC

@Test(.timeLimit(.minutes(1))) func batchOfRequestsIsAnsweredWithOneAggregateBatchResponse() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agent = await Connection(
        transport: agentEnd,
        requestHandler: { method, _ in .object(["echo": .string(method)]) }
    )

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
    _ = agent
}

@Test(.timeLimit(.minutes(1))) func batchOfOnlyNotificationsProducesNoReply() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let notes = AsyncStream<String>.makeStream()
    let agent = await Connection(
        transport: agentEnd,
        notificationHandler: { method, _ in notes.continuation.yield(method) }
    )

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
    _ = agent
}

@Test(.timeLimit(.minutes(1))) func batchMixingRequestsAndNotificationsOwesOnlyTheRequests() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let notes = AsyncStream<String>.makeStream()
    let agent = await Connection(
        transport: agentEnd,
        requestHandler: { _, _ in .bool(true) },
        notificationHandler: { method, _ in notes.continuation.yield(method) }
    )

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
    _ = agent
}

// MARK: - Malformed frame (clean protocol error, not a crashed read loop)

@Test(.timeLimit(.minutes(1))) func malformedFrameGetsCleanParseErrorAndReadLoopContinues() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agent = await Connection(transport: agentEnd, requestHandler: { _, _ in .bool(true) })
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
    _ = agent
}

// MARK: - _meta passthrough

@Test(.timeLimit(.minutes(1))) func metaFieldsPassThroughParamsAndResultUnchanged() async throws {
    let params: JSONValue = .object([
        "_meta": .object(["traceId": .string("t-1")]),
        "text": .string("hello"),
    ])
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agent = await Connection(
        transport: agentEnd,
        requestHandler: { _, params in params ?? .null }
    )
    let client = await Connection(transport: clientEnd)

    let result = try await client.request(method: "echo", params: params)

    #expect(result == params)
    _ = agent
}
