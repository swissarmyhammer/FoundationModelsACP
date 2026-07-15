import Foundation

/// Shared machinery for the two role connections.
///
/// Owns the full-duplex `Connection` and the write-once role holder, and
/// routes every inbound request and notification through the served-methods
/// table to a role-specific dispatcher. Both `AgentSideConnection` and
/// `ClientSideConnection` delegate to one instance, so the transport wiring,
/// the initialization-cycle break, the served-table guard, and shutdown live
/// in a single place rather than duplicated per role.
final class RoleConnectionCore<Role: Sendable>: Sendable {
    /// Dispatches one inbound request, by handler name, to the role.
    typealias RequestDispatch =
        @Sendable (_ handler: String, _ params: JSONValue?, _ role: Role) async throws -> JSONValue

    /// Dispatches one inbound notification, by handler name, to the role.
    typealias NotificationDispatch =
        @Sendable (_ handler: String, _ params: JSONValue?, _ role: Role) async -> Void

    /// The underlying full-duplex JSON-RPC engine.
    private let connection: Connection

    /// The side this connection calls outbound: the peer role's methods.
    private let peerSide: MethodSide

    /// The write-once cell holding the served role.
    private let holder: RoleHolder<Role>

    /// Creates the engine and starts its read loop with the role unset.
    ///
    /// The owner calls `setRole(_:)` from its factory before the read loop can
    /// dispatch; until then, inbound calls answer method-not-found.
    ///
    /// - Parameters:
    ///   - stream: The bidirectional transport to run over.
    ///   - logger: Diagnostic sink; never stdout.
    ///   - requestTimeout: Default outbound request timeout; `nil` waits
    ///     forever.
    ///   - servedSide: The side whose methods this connection serves inbound.
    ///   - peerSide: The side whose methods this connection calls outbound.
    ///   - dispatchRequest: Routes an inbound request to the role's handler.
    ///   - dispatchNotification: Routes an inbound notification to the role's
    ///     handler.
    ///   - onClose: Invoked once when the connection shuts down; lets the owner
    ///     finish streams it derives from the connection.
    init(
        stream: any ACPTransport,
        logger: ACPLogger,
        requestTimeout: Duration?,
        servedSide: MethodSide,
        peerSide: MethodSide,
        dispatchRequest: @escaping RequestDispatch,
        dispatchNotification: @escaping NotificationDispatch,
        onClose: Connection.CloseHandler? = nil
    ) async {
        self.peerSide = peerSide
        let holder = RoleHolder<Role>()
        let served = RoleRouting.served(on: servedSide)
        connection = await Connection(
            transport: stream,
            logger: logger,
            requestTimeout: requestTimeout,
            requestHandler: { method, params in
                guard let info = served[method], info.kind == .request, let role = holder.role else {
                    throw RequestError.methodNotFound(method)
                }
                return try await dispatchRequest(info.handlerName, params, role)
            },
            notificationHandler: { method, params in
                guard let info = served[method], info.kind == .notification, let role = holder.role else {
                    return
                }
                await dispatchNotification(info.handlerName, params, role)
            },
            onClose: onClose
        )
        self.holder = holder
    }

    /// Stores the served role; called once before the read loop dispatches.
    ///
    /// - Parameter role: The role object to serve inbound calls.
    func setRole(_ role: Role) {
        holder.set(role)
    }

    /// Issues an outbound peer request and decodes its typed response.
    ///
    /// - Parameters:
    ///   - handler: The Swift handler name of the peer method to call.
    ///   - params: The typed request parameters.
    ///   - responseType: The expected response model type.
    /// - Returns: The decoded response.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    func call<Request: Encodable, Response: Decodable>(
        _ handler: String,
        _ params: Request,
        returning responseType: Response.Type
    ) async throws -> Response {
        try await RoleDispatch.callResult(
            connection, handler: handler, on: peerSide, params, returning: responseType
        )
    }

    /// Issues an outbound peer request whose response carries no value.
    ///
    /// - Parameters:
    ///   - handler: The Swift handler name of the peer method to call.
    ///   - params: The typed request parameters.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    func callEmpty<Request: Encodable>(_ handler: String, _ params: Request) async throws {
        try await RoleDispatch.callEmpty(connection, handler: handler, on: peerSide, params)
    }

    /// Sends an outbound peer notification.
    ///
    /// - Parameters:
    ///   - handler: The Swift handler name of the peer notification to send.
    ///   - params: The typed notification parameters.
    /// - Throws: `ConnectionError.closed` after disconnect.
    func notify<Params: Encodable>(_ handler: String, _ params: Params) async throws {
        try await RoleDispatch.notify(connection, handler: handler, on: peerSide, params)
    }

    /// Shuts the connection down, rejecting every pending request.
    func close() async {
        await connection.close()
    }
}
