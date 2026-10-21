import Foundation

/// The handlers of the extension methods and notifications that one side of a
/// connection serves.
///
/// ACP lets a peer add methods and notifications whose names start with `_`
/// (https://agentclientprotocol.com/protocol/v2/extensibility). A host
/// registers one handler for each name it serves, and gives the handlers to
/// its connection through ``Agent/extensionHandlers`` or
/// ``Client/extensionHandlers``:
///
/// ```swift
/// var handlers = ExtensionHandlers()
/// handlers.registerMethod("_vendor/status", params: StatusRequest.self) { request in
///     StatusResponse(ready: true)
/// }
/// handlers.registerNotification("_vendor/ping", params: Ping.self) { ping in
///     pings.yield(ping)
/// }
/// ```
///
/// The connection sends each inbound `_` message to its handler:
///
/// - A `_` request with no handler gives `-32601` method-not-found, as each
///   other method that the connection does not know.
/// - A `_` notification with no handler is ignored.
/// - A request whose params do not decode gives `-32602` invalid-params. A
///   notification whose params do not decode is dropped with a warning to the
///   logger of the connection.
///
/// The connection calls a notification handler in the read loop, in arrival
/// order, as each other notification. Thus a notification handler must return
/// promptly. Each request handler runs in its own task, so it can wait.
///
/// To advertise the extensions to the peer, write them under a namespace in
/// `_meta` with ``ExtensionMeta``, for example in the `initialize` response.
public struct ExtensionHandlers: Sendable {
    /// Serves one inbound extension request: decodes the params, and gives
    /// the encoded result.
    typealias MethodHandler = @Sendable (_ params: JSONValue?) async throws -> JSONValue

    /// Serves one inbound extension notification: decodes the params, and
    /// gives them to the handler of the host. Params that do not decode give
    /// one warning to `logger`, with `logPrefix` before it.
    typealias NotificationHandler =
        @Sendable (_ params: JSONValue?, _ logPrefix: String, _ logger: ACPLogger) async -> Void

    /// The first character of the name of each extension method and
    /// notification.
    static let namePrefix = "_"

    /// The request handlers, by wire method.
    private var methods: [String: MethodHandler] = [:]

    /// The notification handlers, by wire method.
    private var notifications: [String: NotificationHandler] = [:]

    /// Makes a set with no handler.
    public init() {}

    /// Registers the handler of one extension method. A second registration
    /// for the same method replaces the first.
    ///
    /// - Parameters:
    ///   - method: The wire method. It must start with `_`.
    ///   - paramsType: The type that the params decode to. Use ``JSONValue``
    ///     for raw params.
    ///   - handler: Serves one call, and gives the result. Throw a
    ///     ``RequestError`` to answer with that JSON-RPC error.
    public mutating func registerMethod<Params: Decodable & SendableMetatype, Result: Encodable & SendableMetatype>(
        _ method: String,
        params paramsType: Params.Type,
        handler: @escaping @Sendable (Params) async throws -> Result
    ) {
        Self.requireExtensionName(method)
        methods[method] = { params in
            try await RoleDispatch.serveResult(params, as: Params.self, handler)
        }
    }

    /// Registers the handler of one extension notification. A second
    /// registration for the same notification replaces the first.
    ///
    /// - Parameters:
    ///   - method: The wire method. It must start with `_`.
    ///   - paramsType: The type that the params decode to. Use ``JSONValue``
    ///     for raw params.
    ///   - handler: Gets the params of each notification. It runs in the read
    ///     loop of the connection, so it must return promptly.
    public mutating func registerNotification<Params: Decodable & SendableMetatype>(
        _ method: String,
        params paramsType: Params.Type,
        handler: @escaping @Sendable (Params) async -> Void
    ) {
        Self.requireExtensionName(method)
        notifications[method] = { params, logPrefix, logger in
            guard
                let decoded = RoleDispatch.decodeNotification(
                    params, as: Params.self, method: method, logPrefix: logPrefix, logger: logger
                )
            else {
                return
            }
            await handler(decoded)
        }
    }

    /// The handler of one extension method.
    ///
    /// - Parameter method: The wire method.
    /// - Returns: The handler, or `nil` when no handler is registered.
    func methodHandler(for method: String) -> MethodHandler? {
        methods[method]
    }

    /// The handler of one extension notification.
    ///
    /// - Parameter method: The wire method.
    /// - Returns: The handler, or `nil` when no handler is registered.
    func notificationHandler(for method: String) -> NotificationHandler? {
        notifications[method]
    }

    /// Stops the program when `method` is not an extension name.
    ///
    /// ACP keeps each name that does not start with `_` for itself, so a call
    /// with such a name is an error of the caller.
    ///
    /// - Parameter method: The wire method.
    static func requireExtensionName(_ method: String) {
        precondition(method.hasPrefix(namePrefix), "the extension method \"\(method)\" does not start with \(namePrefix)")
    }
}
