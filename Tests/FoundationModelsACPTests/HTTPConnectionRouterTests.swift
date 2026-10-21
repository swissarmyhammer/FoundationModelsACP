import Foundation
import Synchronization
import Testing

@testable import FoundationModelsACP

// MARK: - Helpers

/// The bearer token that the connections of these tests send.
private let clientToken = "device-token"

/// The JSON-RPC `initialize` request that opens a connection.
///
/// - Returns: The encoded request body.
/// - Throws: An error when the request does not encode.
private func initializeBody() throws -> Data {
    let envelope = RawPeerEnvelope.request(
        id: initializeRequestId,
        method: "initialize",
        params: try JSONValue.encode(result: handshakeInitializeRequest())
    )
    return try JSONEncoder().encode(envelope)
}

/// The wire id of the `initialize` request of `initializeBody()`.
private let initializeRequestId = JSONValue.number(1)

/// A JSON-RPC notification body, which is not `initialize`.
private let cancelBody = Data(
    #"{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"s"}}"#.utf8
)

/// Makes one HTTP request of the client.
///
/// - Parameters:
///   - method: The HTTP method.
///   - connectionId: The `Acp-Connection-Id` header, or `nil` for none.
///   - token: The bearer token of the `Authorization` header, or `nil` for
///     none.
///   - body: The body of the request.
/// - Returns: The request.
private func request(
    _ method: String,
    connectionId: String? = nil,
    token: String? = clientToken,
    body: Data = Data()
) -> HTTPRequest {
    var headers: [String: String] = [:]
    if let connectionId {
        headers[HTTPServerTransport.connectionIdHeader] = connectionId
    }
    if let token {
        headers["Authorization"] = "Bearer \(token)"
    }
    return HTTPRequest(method: method, target: "/acp", headers: headers, body: body)
}

/// The response of a route that must answer at once.
///
/// - Parameter route: The route of a request.
/// - Returns: The response.
/// - Throws: An error when the route is a stream.
private func response(of route: HTTPRoute) throws -> HTTPResponse {
    guard case .respond(let response) = route else {
        throw UnexpectedStreamRouteError()
    }
    return response
}

/// Thrown when a request that must get a response at once opened a stream.
private struct UnexpectedStreamRouteError: Error {}

/// The connection whose stream a route opened.
///
/// - Parameter route: The route of a `GET` request.
/// - Returns: The connection of the stream.
/// - Throws: An error when the route is a response.
private func streamedConnection(of route: HTTPRoute) throws -> HTTPConnectionTransport {
    guard case .stream(let transport) = route else {
        throw UnexpectedResponseRouteError()
    }
    return transport
}

/// Thrown when a request that must open a stream got a response.
private struct UnexpectedResponseRouteError: Error {}

/// The members of a JSON object.
///
/// - Parameter value: The value to read.
/// - Returns: The members, or `nil` when `value` is not an object.
private func members(of value: JSONValue) -> [String: JSONValue]? {
    guard case .object(let members) = value else { return nil }
    return members
}

/// A router with one open connection.
private struct OpenConnection {
    /// The router of the connection.
    let router: HTTPConnectionRouter

    /// The id that the `initialize` response gave.
    let id: String

    /// The connection that the router gave to the host.
    let transport: HTTPConnectionTransport

    /// Opens a connection with an `initialize` request.
    ///
    /// - Returns: The open connection.
    /// - Throws: An error when the router does not open a connection.
    static func open() async throws -> OpenConnection {
        let router = HTTPConnectionRouter(logger: .disabled)
        let answer = try response(of: router.route(request("POST", body: initializeBody())))
        let id = try #require(answer.headers[HTTPServerTransport.connectionIdHeader])
        var accepted = router.connections.makeAsyncIterator()
        let transport = try #require(await accepted.next())
        return OpenConnection(router: router, id: id, transport: transport)
    }
}

/// Reads the next chunk of the agent-to-client stream of a connection, and
/// decodes it as one JSON value.
///
/// - Parameter iterator: The iterator of the stream.
/// - Returns: The decoded value.
/// - Throws: An error when the stream ended or the chunk does not decode.
private func nextMessage(from iterator: inout AsyncStream<Data>.Iterator) async throws -> JSONValue {
    let chunk = try #require(await iterator.next())
    return try JSONDecoder().decode(JSONValue.self, from: chunk)
}

// MARK: - Opening a connection

@Test func initializeWithNoConnectionIdAnswersAConnectionId() async throws {
    let router = HTTPConnectionRouter(logger: .disabled)

    let answer = try response(of: router.route(request("POST", body: initializeBody())))

    #expect(answer.status == .accepted)
    let id = try #require(answer.headers[HTTPServerTransport.connectionIdHeader])
    #expect(!id.isEmpty)
}

@Test func initializeGivesTheHostAConnectionWithTheAnsweredIdAndToken() async throws {
    let connection = try await OpenConnection.open()

    let info = try #require(connection.transport.connectionInfo)
    #expect(info.id.rawValue == connection.id)
    #expect(info.bearerToken == clientToken)
}

@Test func twoInitializeRequestsOpenTwoConnections() async throws {
    let router = HTTPConnectionRouter(logger: .disabled)

    let first = try response(of: router.route(request("POST", body: initializeBody())))
    let second = try response(of: router.route(request("POST", body: initializeBody())))

    #expect(
        first.headers[HTTPServerTransport.connectionIdHeader]
            != second.headers[HTTPServerTransport.connectionIdHeader]
    )
}

@Test func initializeWithNoAuthorizationGivesAConnectionWithNoToken() async throws {
    let router = HTTPConnectionRouter(logger: .disabled)
    _ = router.route(request("POST", token: nil, body: try initializeBody()))
    var accepted = router.connections.makeAsyncIterator()

    let transport = try #require(await accepted.next())

    #expect(transport.connectionInfo?.bearerToken == nil)
}

// MARK: - Later requests

@Test func aRequestWithTheConnectionIdReachesTheSameConnection() async throws {
    let connection = try await OpenConnection.open()

    let answer = try response(
        of: connection.router.route(request("POST", connectionId: connection.id, body: cancelBody))
    )

    #expect(answer.status == .accepted)
    let reader = WireReader(connection.transport)
    let initialize = try #require(try await reader.next())
    #expect(initialize.string(member: "method") == "initialize")
    let cancel = try #require(try await reader.next())
    #expect(cancel.string(member: "method") == "session/cancel")
}

@Test func aRequestWithNoConnectionIdIsRefused() async throws {
    let connection = try await OpenConnection.open()

    let answer = try response(of: connection.router.route(request("POST", body: cancelBody)))

    #expect(answer.status == .badRequest)
}

@Test func aRequestWithAnUnknownConnectionIdIsRefused() async throws {
    let connection = try await OpenConnection.open()

    let answer = try response(
        of: connection.router.route(request("POST", connectionId: "not-a-connection", body: cancelBody))
    )

    #expect(answer.status == .notFound)
}

@Test func aRequestWithAnotherBearerTokenIsRefused() async throws {
    let connection = try await OpenConnection.open()

    let answer = try response(
        of: connection.router.route(
            request("POST", connectionId: connection.id, token: "other-token", body: cancelBody)
        )
    )

    #expect(answer.status == .forbidden)
}

@Test func aConnectionIdHeaderOfAnotherCaseReachesTheConnection() async throws {
    let connection = try await OpenConnection.open()
    let lowerCase = HTTPRequest(
        method: "POST",
        target: "/acp",
        headers: [
            HTTPServerTransport.connectionIdHeader.lowercased(): connection.id,
            "authorization": "bearer \(clientToken)",
        ],
        body: cancelBody
    )

    let answer = try response(of: connection.router.route(lowerCase))

    #expect(answer.status == .accepted)
}

@Test func anUnknownMethodIsRefused() async throws {
    let connection = try await OpenConnection.open()

    let answer = try response(of: connection.router.route(request("PUT", connectionId: connection.id)))

    #expect(answer.status == .methodNotAllowed)
}

// MARK: - The agent-to-client stream

@Test func theStreamRequestCarriesWhatTheAgentWrites() async throws {
    let connection = try await OpenConnection.open()
    let streamed = try streamedConnection(of: connection.router.route(request("GET", connectionId: connection.id)))
    #expect(streamed === connection.transport)

    try await connection.transport.write(NDJSONCodec.encode(JSONValue.object(["method": .string("x")])))

    var stream = streamed.outgoing.makeAsyncIterator()
    let message = try await nextMessage(from: &stream)
    #expect(message.string(member: "method") == "x")
}

@Test func aSecondStreamRequestIsRefused() async throws {
    let connection = try await OpenConnection.open()
    _ = connection.router.route(request("GET", connectionId: connection.id))

    let answer = try response(of: connection.router.route(request("GET", connectionId: connection.id)))

    #expect(answer.status == .conflict)
}

// MARK: - Closing

@Test func deleteEndsTheConnectionAndForgetsItsId() async throws {
    let connection = try await OpenConnection.open()

    let answer = try response(of: connection.router.route(request("DELETE", connectionId: connection.id)))

    #expect(answer.status == .noContent)
    var received: [Data] = []
    for try await chunk in connection.transport.bytes {
        received.append(chunk)
    }
    #expect(received.count == 1)
    let later = try response(
        of: connection.router.route(request("POST", connectionId: connection.id, body: cancelBody))
    )
    #expect(later.status == .notFound)
}

@Test func aClosedTransportFinishesItsStream() async throws {
    let connection = try await OpenConnection.open()
    _ = connection.router.route(request("GET", connectionId: connection.id))

    connection.transport.close()

    var stream = connection.transport.outgoing.makeAsyncIterator()
    #expect(await stream.next() == nil)
    await #expect(throws: HTTPConnectionTransport.ClosedError.self) {
        try await connection.transport.write(Data("{}\n".utf8))
    }
}

@Test func closeAllEndsEachConnection() async throws {
    let connection = try await OpenConnection.open()

    connection.router.closeAll()

    var stream = connection.transport.outgoing.makeAsyncIterator()
    #expect(await stream.next() == nil)
    let later = try response(of: connection.router.route(request("POST", body: initializeBody())))
    #expect(later.status == .serviceUnavailable)
}

// MARK: - The agent side

@Test func theAgentSideReadsTheConnectionIdAndTheBearerToken() async throws {
    let connection = try await OpenConnection.open()
    let seen = Mutex<ACPConnectionInfo?>(nil)

    let agent = await AgentSideConnection(stream: connection.transport) { agentConnection in
        seen.withLock { $0 = agentConnection.connectionInfo }
        return StubAgent()
    }
    defer { connection.transport.close() }

    #expect(agent.connectionInfo?.id.rawValue == connection.id)
    #expect(agent.connectionInfo?.bearerToken == clientToken)
    #expect(seen.withLock { $0 } == agent.connectionInfo)
}

@Test func theInitializeResponseReachesTheStream() async throws {
    let connection = try await OpenConnection.open()
    let streamed = try streamedConnection(of: connection.router.route(request("GET", connectionId: connection.id)))
    let agent = await AgentSideConnection(stream: connection.transport) { _ in StubAgent() }
    defer { connection.transport.close() }

    var stream = streamed.outgoing.makeAsyncIterator()
    let answer = try #require(members(of: try await nextMessage(from: &stream)))

    #expect(answer["id"] == initializeRequestId)
    #expect(answer["result"] != nil)
    withExtendedLifetime(agent) {}
}

@Test func aTransportWithNoHeaderGivesNoConnectionInfo() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    defer {
        clientEnd.close()
        agentEnd.close()
    }

    let agent = await AgentSideConnection(stream: agentEnd) { _ in StubAgent() }

    #expect(agent.connectionInfo == nil)
}
