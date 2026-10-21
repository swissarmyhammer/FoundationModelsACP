import Foundation
import Synchronization

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
    /// The owner calls `setRole(_:extensionHandlers:)` from its factory before
    /// the read loop can dispatch; until then, inbound calls answer
    /// method-not-found.
    ///
    /// - Parameters:
    ///   - stream: The bidirectional transport to run over.
    ///   - logger: Diagnostic sink; never stdout.
    ///   - logPrefix: The prefix of each diagnostic of the owner type. The
    ///     warning for an extension notification that does not decode has it.
    ///   - requestTimeout: Default outbound request timeout; `nil` waits
    ///     forever.
    ///   - servedSide: The side whose methods this connection serves inbound.
    ///   - peerSide: The side whose methods this connection calls outbound.
    ///   - dispatchRequest: Routes an inbound request to the role's handler.
    ///   - dispatchNotification: Routes an inbound notification to the role's
    ///     handler.
    ///   - onClose: Invoked once when the connection shuts down; lets the owner
    ///     finish streams it derives from the connection.
    ///   - outgoingRequests: The tracker that records the start and the finish
    ///     of each outbound request. The owner gives a tracker with a session
    ///     observer when it needs the finish of each session request.
    ///   - scheduleRequestTimeout: Starts the timeout of each outbound request
    ///     that has a time limit. Only a test gives a value that is not the
    ///     default.
    init(
        stream: any ACPTransport,
        logger: ACPLogger,
        logPrefix: String,
        requestTimeout: Duration?,
        servedSide: MethodSide,
        peerSide: MethodSide,
        dispatchRequest: @escaping RequestDispatch,
        dispatchNotification: @escaping NotificationDispatch,
        onClose: Connection.CloseHandler? = nil,
        outgoingRequests: OutgoingRequestTracker = OutgoingRequestTracker(),
        scheduleRequestTimeout: @escaping Connection.RequestTimeoutScheduler = Connection.startRequestTimeout
    ) async {
        self.peerSide = peerSide
        let holder = RoleHolder<Role>()
        let served = RoleRouting.served(on: servedSide)
        connection = await Connection(
            transport: stream,
            logger: logger,
            requestTimeout: requestTimeout,
            requestHandler: { method, params in
                try await Self.routeRequest(method, params: params, served: served, holder: holder, to: dispatchRequest)
            },
            notificationHandler: { method, params in
                await Self.routeNotification(
                    method, params: params, served: served, holder: holder, to: dispatchNotification,
                    logPrefix: logPrefix, logger: logger
                )
            },
            onClose: onClose,
            outgoingRequests: outgoingRequests,
            scheduleRequestTimeout: scheduleRequestTimeout
        )
        self.holder = holder
    }

    /// Stores the served role and its extension handlers; called once before
    /// the read loop dispatches.
    ///
    /// - Parameters:
    ///   - role: The role object to serve inbound calls.
    ///   - extensionHandlers: The handlers of the `_` methods and
    ///     notifications that the role serves.
    func setRole(_ role: Role, extensionHandlers: ExtensionHandlers) {
        holder.set(ServedRole(role: role, extensionHandlers: extensionHandlers))
    }

    // MARK: - Inbound routing

    /// Routes one inbound request to the role, or to its extension handler.
    ///
    /// A method of the routing table goes to the role. Any other method goes
    /// to the extension handler that the role registered for it.
    ///
    /// - Parameters:
    ///   - method: The wire method.
    ///   - params: The raw request parameters.
    ///   - served: The routing-table entries of the served side, by wire
    ///     method.
    ///   - holder: The cell that holds the served role.
    ///   - dispatch: Routes a routing-table request to the role's handler.
    /// - Returns: The encoded response value.
    /// - Throws: `RequestError.methodNotFound` before the role is set, or for
    ///   a method with no handler; otherwise any error the handler throws.
    private static func routeRequest(
        _ method: String,
        params: JSONValue?,
        served: [String: MethodInfo],
        holder: RoleHolder<Role>,
        to dispatch: RequestDispatch
    ) async throws -> JSONValue {
        guard let servedRole = holder.servedRole else {
            throw RequestError.methodNotFound(method)
        }
        if let info = served[method], info.kind == .request {
            return try await dispatch(info.handlerName, params, servedRole.role)
        }
        guard let handler = servedRole.extensionHandlers.methodHandler(for: method) else {
            throw RequestError.methodNotFound(method)
        }
        return try await handler(params)
    }

    /// Routes one inbound notification to the role, or to its extension
    /// handler. A notification with no handler is ignored.
    ///
    /// - Parameters:
    ///   - method: The wire method.
    ///   - params: The raw notification parameters.
    ///   - served: The routing-table entries of the served side, by wire
    ///     method.
    ///   - holder: The cell that holds the served role.
    ///   - dispatch: Routes a routing-table notification to the role's
    ///     handler.
    ///   - logPrefix: The prefix of each diagnostic of the owner type.
    ///   - logger: The connection logger.
    private static func routeNotification(
        _ method: String,
        params: JSONValue?,
        served: [String: MethodInfo],
        holder: RoleHolder<Role>,
        to dispatch: NotificationDispatch,
        logPrefix: String,
        logger: ACPLogger
    ) async {
        guard let servedRole = holder.servedRole else {
            return
        }
        if let info = served[method], info.kind == .notification {
            await dispatch(info.handlerName, params, servedRole.role)
            return
        }
        guard let handler = servedRole.extensionHandlers.notificationHandler(for: method) else {
            return
        }
        await handler(params, logPrefix, logger)
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

    /// Issues an outbound peer request, decodes its typed response, and gives
    /// the decoded response to `onResponse` in the read loop, before the read
    /// loop dispatches the next frame.
    ///
    /// - Parameters:
    ///   - handler: The Swift handler name of the peer method to call.
    ///   - params: The typed request parameters.
    ///   - responseType: The expected response model type.
    ///   - onResponse: Runs one time with the decoded response. It does not
    ///     run on an error response, a response that does not decode, a
    ///     timeout, a cancel or a close.
    /// - Returns: The decoded response.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    func call<Request: Encodable, Response: Decodable & Sendable>(
        _ handler: String,
        _ params: Request,
        returning responseType: Response.Type,
        onResponse: @escaping @Sendable (Response) -> Void
    ) async throws -> Response {
        try await RoleDispatch.callResult(
            connection, handler: handler, on: peerSide, params, returning: responseType, onResponse: onResponse
        )
    }

    /// Issues an outbound peer request and decodes its typed response. When
    /// the task of the caller is cancelled, the `$/cancel_request` carries
    /// the `_meta` of `cancellation`.
    ///
    /// - Parameters:
    ///   - handler: The Swift handler name of the peer method to call.
    ///   - params: The typed request parameters.
    ///   - responseType: The expected response model type.
    ///   - cancellation: Gives the `_meta` of the `$/cancel_request`.
    /// - Returns: The decoded response.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    func call<Request: Encodable, Response: Decodable>(
        _ handler: String,
        _ params: Request,
        returning responseType: Response.Type,
        cancellation: OutboundCancellation
    ) async throws -> Response {
        try await RoleDispatch.callResult(
            connection, handler: handler, on: peerSide, params, returning: responseType, cancellation: cancellation
        )
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

    /// Issues an outbound extension request and decodes its typed result.
    ///
    /// - Parameters:
    ///   - method: The wire method. It must start with `_`.
    ///   - params: The typed request parameters.
    ///   - resultType: The expected result model type.
    /// - Returns: The decoded result.
    /// - Throws: `RequestError` on a peer error, `ConnectionError` on
    ///   disconnect, or a decode failure on a malformed result.
    func callExtension<Params: Encodable, Result: Decodable>(
        _ method: String,
        _ params: Params,
        returning resultType: Result.Type
    ) async throws -> Result {
        ExtensionHandlers.requireExtensionName(method)
        let result = try await connection.request(method: method, params: JSONValue.encode(result: params))
        return try result.decoded(as: resultType)
    }

    /// Sends an outbound extension notification.
    ///
    /// - Parameters:
    ///   - method: The wire method. It must start with `_`.
    ///   - params: The typed notification parameters.
    /// - Throws: `ConnectionError.closed` after disconnect, or an encoding
    ///   failure.
    func notifyExtension<Params: Encodable>(_ method: String, _ params: Params) async throws {
        ExtensionHandlers.requireExtensionName(method)
        try await connection.notify(method: method, params: JSONValue.encode(result: params))
    }

    /// The outbound peer requests that wait for a response, and the events
    /// that tell when each one starts and finishes.
    var outgoingRequests: OutgoingRequestTracker {
        connection.outgoingRequests
    }

    /// Shuts the connection down, rejecting every pending request.
    func close() async {
        await connection.close()
    }

    /// Waits until the connection closed, and gives the reason. See
    /// `Connection.closed`.
    var closed: ConnectionCloseReason {
        get async { await connection.closed }
    }
}

// MARK: - Role holder

/// The role object a connection serves, and the extension handlers that the
/// role gave when the connection stored it.
struct ServedRole<Role: Sendable>: Sendable {
    /// The role object that serves the routing-table methods.
    let role: Role

    /// The handlers of the `_` methods and notifications of the role.
    let extensionHandlers: ExtensionHandlers
}

/// A write-once, thread-safe cell holding the role object a connection serves.
///
/// The connection's inbound handlers capture this holder rather than the
/// connection itself, which breaks the initialization cycle between a
/// connection and the role its own factory builds from it.
final class RoleHolder<Role: Sendable>: Sendable {
    /// The stored role, guarded for the read loop and inbound handler tasks.
    private let storage = Mutex<ServedRole<Role>?>(nil)

    /// Stores the role, called once before the read loop can dispatch.
    ///
    /// - Parameter servedRole: The role object to serve inbound calls, and
    ///   its extension handlers.
    func set(_ servedRole: ServedRole<Role>) {
        storage.withLock { $0 = servedRole }
    }

    /// The stored role, or `nil` before wiring completes.
    var servedRole: ServedRole<Role>? {
        storage.withLock { $0 }
    }
}
