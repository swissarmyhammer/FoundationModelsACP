import Foundation
import Synchronization

/// The HTTP methods of the ACP HTTP transport. A method name matches in
/// its exact case, as HTTP requires.
enum HTTPMethod: String {
    /// Sends one client-to-agent message, or opens a connection.
    case post = "POST"

    /// Opens the agent-to-client stream.
    case get = "GET"

    /// Ends the connection.
    case delete = "DELETE"
}

/// What the server does with one request.
enum HTTPRoute {
    /// Send this response, and read the next request.
    case respond(HTTPResponse)

    /// Send the agent-to-client messages of this connection as a chunked
    /// response, until the connection ends.
    case stream(HTTPConnectionTransport)
}

/// The connection table of an ``HTTPServerTransport``: it opens a
/// connection at `initialize`, and it sends each later request to the
/// connection that its `Acp-Connection-Id` names.
///
/// The router reads whole requests and gives routes; it touches no socket,
/// so each rule of the wire runs in a unit test.
final class HTTPConnectionRouter: Sendable {
    /// The JSON-RPC method that opens a connection.
    private static let initializeMethod = "initialize"

    /// The open connections, keyed by their id.
    private struct Table {
        /// The open connections.
        var connections: [ACPConnectionId: HTTPConnectionTransport] = [:]

        /// Whether ``HTTPConnectionRouter/closeAll()`` ran; then the router
        /// opens no connection.
        var isClosed = false
    }

    /// Each connection that an `initialize` opened, in order.
    let connections: AsyncStream<HTTPConnectionTransport>

    /// Feeds ``connections``.
    private let accepted: AsyncStream<HTTPConnectionTransport>.Continuation

    /// The open connections.
    private let table = Mutex(Table())

    /// The diagnostic sink.
    private let logger: ACPLogger

    /// Creates a router with no connection.
    ///
    /// - Parameter logger: Gets a diagnostic for each refused request. It
    ///   never gets a bearer token.
    init(logger: ACPLogger) {
        (connections, accepted) = AsyncStream<HTTPConnectionTransport>.makeStream()
        self.logger = logger
    }

    /// Routes one request.
    ///
    /// - A request with no `Acp-Connection-Id` must be a `POST` of
    ///   `initialize`: it opens a connection, and the `202` response names
    ///   the new id. Any other request with no id gets `400`.
    /// - A request with an id that names no open connection gets `404`.
    /// - A request with another bearer token than the `initialize` of the
    ///   connection gets `403`.
    /// - Then `POST` gives the body to the connection (`202`), `GET` opens
    ///   the agent-to-client stream (one for each connection, else `409`),
    ///   and `DELETE` ends the connection (`204`). Other methods get `405`.
    ///
    /// - Parameter request: The request of a client.
    /// - Returns: The route of the request.
    func route(_ request: HTTPRequest) -> HTTPRoute {
        guard let rawId = request.header(named: HTTPServerTransport.connectionIdHeader) else {
            return .respond(open(request))
        }
        guard let connection = table.withLock({ $0.connections[ACPConnectionId(rawValue: rawId)] }) else {
            return refuse(.notFound, "no open connection has this \(HTTPServerTransport.connectionIdHeader)")
        }
        guard request.bearerToken == connection.info.bearerToken else {
            return refuse(.forbidden, "the credential is not the credential of the connection")
        }
        return route(request, to: connection)
    }

    /// Ends each open connection, and opens no more.
    func closeAll() {
        let open = table.withLock { table in
            table.isClosed = true
            return Array(table.connections.values)
        }
        for connection in open {
            connection.close()
        }
        accepted.finish()
    }

    /// Opens a connection for an `initialize` request with no connection id.
    ///
    /// - Parameter request: The request.
    /// - Returns: `202` with the new id, or the refusal.
    private func open(_ request: HTTPRequest) -> HTTPResponse {
        guard HTTPMethod(rawValue: request.method) == .post, Self.isInitialize(request.body) else {
            logger.log("HTTPConnectionRouter: refused a request with no \(HTTPServerTransport.connectionIdHeader)")
            return .refusal(.badRequest, "send \(HTTPServerTransport.connectionIdHeader), or POST initialize")
        }
        let info = ACPConnectionInfo(id: ACPConnectionId(rawValue: UUID().uuidString), bearerToken: request.bearerToken)
        let connection = HTTPConnectionTransport(info: info) { [weak self] in self?.forget(info.id) }
        let isOpen = table.withLock { table in
            guard !table.isClosed else { return false }
            table.connections[info.id] = connection
            return true
        }
        guard isOpen, case .enqueued = accepted.yield(connection) else {
            connection.close()
            return .refusal(.serviceUnavailable, "the server stopped")
        }
        _ = connection.deliver(request.body)
        return HTTPResponse(status: .accepted, headers: [HTTPServerTransport.connectionIdHeader: info.id.rawValue])
    }

    /// Routes a request of an open connection by its method.
    ///
    /// - Parameters:
    ///   - request: The request.
    ///   - connection: The connection that the request names.
    /// - Returns: The route.
    private func route(_ request: HTTPRequest, to connection: HTTPConnectionTransport) -> HTTPRoute {
        switch HTTPMethod(rawValue: request.method) {
        case .post:
            guard connection.deliver(request.body) else {
                return refuse(.notFound, "the connection ended")
            }
            return .respond(HTTPResponse(status: .accepted))
        case .get:
            guard connection.openStream() else {
                return refuse(.conflict, "the stream of the connection is already open")
            }
            return .stream(connection)
        case .delete:
            connection.close()
            return .respond(HTTPResponse(status: .noContent))
        case nil:
            return refuse(.methodNotAllowed, "use POST, GET or DELETE")
        }
    }

    /// Refuses a request, and logs why.
    ///
    /// - Parameters:
    ///   - status: The status of the refusal.
    ///   - reason: Why the request is refused.
    /// - Returns: The route that sends the refusal.
    private func refuse(_ status: HTTPStatus, _ reason: String) -> HTTPRoute {
        logger.log("HTTPConnectionRouter: \(status.rawValue) \(reason)")
        return .respond(.refusal(status, reason))
    }

    /// Removes an ended connection from the table.
    ///
    /// - Parameter id: The id of the connection.
    private func forget(_ id: ACPConnectionId) {
        _ = table.withLock { $0.connections.removeValue(forKey: id) }
    }

    /// Whether a body is a JSON-RPC `initialize` request.
    ///
    /// - Parameter body: The body of a `POST`.
    /// - Returns: `true` when the body is an object whose method is
    ///   `initialize`.
    private static func isInitialize(_ body: Data) -> Bool {
        let message = try? JSONDecoder().decode(JSONValue.self, from: body)
        return message?.string(member: "method") == initializeMethod
    }
}
