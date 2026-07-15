import Foundation
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
            // long-lived request like session/prompt.
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

// MARK: - Errors

@Test(.timeLimit(.minutes(1))) func unknownMethodIsAnsweredWithMethodNotFound() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agent = await Connection(transport: agentEnd)
    let client = await Connection(transport: clientEnd)

    do {
        _ = try await client.request(method: "no/such")
        Issue.record("request should have failed with method-not-found")
    } catch let error as RequestError {
        #expect(error.code == -32601)
    }
    _ = agent
}

@Test(.timeLimit(.minutes(1))) func handlerRequestErrorPropagatesCodeMessageAndData() async throws {
    let thrown = RequestError(
        code: -32002,
        message: "Resource not found",
        data: .object(["uri": .string("file:///missing")])
    )
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agent = await Connection(transport: agentEnd, requestHandler: { _, _ in throw thrown })
    let client = await Connection(transport: clientEnd)

    do {
        _ = try await client.request(method: "fs/read_text_file")
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
        #expect(error.code == -32603)
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

@Test(.timeLimit(.minutes(1))) func handlerAuthRequiredErrorRoundTripsToCaller() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agent = await Connection(
        transport: agentEnd,
        requestHandler: { _, _ in throw RequestError.authRequired }
    )
    let client = await Connection(transport: clientEnd)

    do {
        _ = try await client.request(method: "session/new")
        Issue.record("request should have failed with auth-required")
    } catch let error as RequestError {
        #expect(error == RequestError.authRequired)
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
        #expect(error.code == -32600)
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
    #expect(RequestError.parseError.code == -32700)
    #expect(RequestError.invalidRequest.code == -32600)
    #expect(RequestError.methodNotFound("session/nope").code == -32601)
    #expect(RequestError.invalidParams.code == -32602)
    #expect(RequestError.internalError(detail: "boom").code == -32603)
    #expect(RequestError.authRequired.code == -32000)
    #expect(RequestError.resourceNotFound(uri: "file:///x").code == -32002)
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
