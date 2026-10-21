import Foundation
import Synchronization
import Testing

import FoundationModelsACP

// The HTTP server transport over a real loopback socket: a URLSession
// client opens a connection, reads the agent-to-client stream, and is
// refused without its connection id.

/// The bearer token of the client of these tests.
private let clientToken = "device-token"

/// The JSON-RPC `initialize` request of the client.
private let initializeBody = Data(
    #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"info":{"name":"http-test-client","version":"0.0.0"},"protocolVersion":2}}"#
        .utf8
)

/// A JSON-RPC notification of the client, which is not `initialize`.
private let cancelBody = Data(#"{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"s"}}"#.utf8)

/// An agent that answers `initialize` and has no session.
private struct InitializeOnlyAgent: Agent {
    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(
            info: Implementation(name: "http-test-agent", version: "0.0.0"),
            protocolVersion: .v2,
            capabilities: AgentCapabilities(session: SessionCapabilities())
        )
    }

    func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        throw RequestError.methodNotFound("newSession")
    }

    func listSessions(_ params: ListSessionsRequest) async throws -> ListSessionsResponse {
        ListSessionsResponse(sessions: [])
    }

    func resumeSession(_ params: ResumeSessionRequest) async throws -> ResumeSessionResponse {
        throw RequestError.methodNotFound("resumeSession")
    }

    func closeSession(_ params: CloseSessionRequest) async throws -> CloseSessionResponse {
        CloseSessionResponse()
    }

    func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        throw RequestError.methodNotFound("prompt")
    }

    func sessionCancel(_ params: CancelSessionNotification) async {}
}

/// What the host of a live server saw.
private final class HostRecord: Sendable {
    /// The connection information that each agent side read.
    let seen = Mutex<[ACPConnectionInfo?]>([])

    /// The agent side of each connection, kept alive while the test runs.
    let agents = Mutex<[AgentSideConnection]>([])
}

/// A running server whose host serves each connection with an
/// `InitializeOnlyAgent`, and records what each agent side read.
private final class LiveServer: Sendable {
    /// The server.
    let server: HTTPServerTransport

    /// The URL of the server.
    let url: URL

    /// What the host saw.
    let record: HostRecord

    /// The task that accepts connections; it ends when the server stops.
    private let host: Task<Void, Never>

    /// Starts a server on a free loopback port.
    ///
    /// - Throws: An error when the server cannot listen.
    init() async throws {
        let server = try HTTPServerTransport()
        let port = try await server.start()
        let record = HostRecord()
        host = Task {
            for await transport in server.connections {
                let agent = await AgentSideConnection(stream: transport) { connection in
                    record.seen.withLock { $0.append(connection.connectionInfo) }
                    return InitializeOnlyAgent()
                }
                record.agents.withLock { $0.append(agent) }
            }
        }
        self.server = server
        self.record = record
        url = try #require(URL(string: "http://127.0.0.1:\(port.rawValue)/acp"))
    }

    /// Stops the server and its host.
    func stop() async {
        server.stop()
        await host.value
    }
}

/// Makes a request of the client.
///
/// - Parameters:
///   - url: The URL of the server.
///   - method: The HTTP method.
///   - connectionId: The `Acp-Connection-Id`, or `nil` for none.
///   - body: The body, or `nil` for none.
/// - Returns: The request.
private func request(_ url: URL, _ method: String, connectionId: String? = nil, body: Data? = nil) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = body
    request.setValue("Bearer \(clientToken)", forHTTPHeaderField: "Authorization")
    if let connectionId {
        request.setValue(connectionId, forHTTPHeaderField: HTTPServerTransport.connectionIdHeader)
    }
    return request
}

/// Sends a request and gives the HTTP response.
///
/// - Parameters:
///   - session: The URL session.
///   - request: The request.
/// - Returns: The HTTP response.
/// - Throws: An error when the request fails.
private func send(_ session: URLSession, _ request: URLRequest) async throws -> HTTPURLResponse {
    let (_, response) = try await session.data(for: request)
    return try #require(response as? HTTPURLResponse)
}

@Test func anHTTPClientOpensAConnectionAndReadsTheInitializeResponseOnTheStream() async throws {
    let live = try await LiveServer()
    let session = URLSession(configuration: .ephemeral)

    let opened = try await send(session, request(live.url, "POST", body: initializeBody))
    #expect(opened.statusCode == 202)
    let id = try #require(opened.value(forHTTPHeaderField: HTTPServerTransport.connectionIdHeader))

    let (stream, streamResponse) = try await session.bytes(for: request(live.url, "GET", connectionId: id))
    #expect((streamResponse as? HTTPURLResponse)?.statusCode == 200)
    var lines = stream.lines.makeAsyncIterator()
    let first = try #require(try await lines.next())
    let answer = try #require(members(of: JSONDecoder().decode(JSONValue.self, from: Data(first.utf8))))
    #expect(answer["id"] == .number(1))
    #expect(answer["result"] != nil)

    #expect(live.record.seen.withLock { $0 } == [ACPConnectionInfo(id: ACPConnectionId(rawValue: id), bearerToken: clientToken)])
    await live.stop()
}

@Test func anHTTPRequestWithNoOrAnUnknownConnectionIdIsRefused() async throws {
    let live = try await LiveServer()
    let session = URLSession(configuration: .ephemeral)

    let missing = try await send(session, request(live.url, "POST", body: cancelBody))
    let unknown = try await send(session, request(live.url, "POST", connectionId: "not-a-connection", body: cancelBody))

    #expect(missing.statusCode == 400)
    #expect(unknown.statusCode == 404)
    await live.stop()
}

/// The members of a JSON object.
///
/// - Parameter value: The value to read.
/// - Returns: The members, or `nil` when `value` is not an object.
private func members(of value: JSONValue) -> [String: JSONValue]? {
    guard case .object(let members) = value else { return nil }
    return members
}
