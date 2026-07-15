import Foundation

/// The client side of an ACP connection (spec §4).
///
/// Wraps one full-duplex `Connection`: inbound Agent→Client calls dispatch to
/// the `Client` the factory builds, and the connection itself exposes the
/// outbound Client→Agent calls (`initialize`, `newSession`, `prompt`, and the
/// rest of the agent surface) so a host can drive the agent.
public final class ClientSideConnection: Sendable {
    /// The side this connection serves inbound: the client-side methods.
    private static let servedSide: MethodSide = .client

    /// The side this connection calls outbound: the agent-side methods.
    private static let peerSide: MethodSide = .agent

    /// The client-side methods this connection serves, keyed by wire name.
    private static let served = RoleRouting.served(on: servedSide)

    /// The underlying full-duplex JSON-RPC engine.
    private let connection: Connection

    /// Creates the connection, wires the factory's client, and starts serving.
    ///
    /// The factory receives this connection so the client it builds can capture
    /// it and drive the agent. The client is stored before the read loop can
    /// dispatch, so the first inbound call always finds it.
    ///
    /// - Parameters:
    ///   - stream: The bidirectional transport to run over.
    ///   - logger: Diagnostic sink; never stdout.
    ///   - requestTimeout: Default outbound request timeout; `nil` waits
    ///     forever (long-lived calls rely on this).
    ///   - factory: Builds the client from this connection.
    public init(
        stream: any ACPTransport,
        logger: ACPLogger = .disabled,
        requestTimeout: Duration? = nil,
        _ factory: @Sendable (ClientSideConnection) -> any Client
    ) async {
        let holder = RoleHolder<any Client>()
        connection = await Connection(
            transport: stream,
            logger: logger,
            requestTimeout: requestTimeout,
            requestHandler: { method, params in
                try await Self.serveRequest(method: method, params: params, client: holder)
            },
            notificationHandler: { method, params in
                await Self.serveNotification(method: method, params: params, client: holder)
            }
        )
        holder.set(factory(self))
    }

    // MARK: - Inbound (Agent → Client)

    /// Serves one inbound request by routing it to the held client.
    ///
    /// - Parameters:
    ///   - method: The wire method name.
    ///   - params: The raw request parameters.
    ///   - holder: The cell holding the client to serve.
    /// - Returns: The encoded response value.
    /// - Throws: `RequestError.methodNotFound` for an unrouted method, or any
    ///   error the client throws.
    private static func serveRequest(
        method: String,
        params: JSONValue?,
        client holder: RoleHolder<any Client>
    ) async throws -> JSONValue {
        guard let info = served[method], info.kind == .request, let client = holder.role else {
            throw RequestError.methodNotFound(method)
        }
        return try await dispatch(info.handlerName, params: params, to: client)
    }

    /// Decodes and dispatches one request to the client's typed handler.
    ///
    /// - Parameters:
    ///   - handler: The routing table's handler name for the method.
    ///   - params: The raw request parameters.
    ///   - client: The client to serve.
    /// - Returns: The encoded response value.
    /// - Throws: `RequestError.methodNotFound` for an unknown handler, or any
    ///   error the client throws.
    private static func dispatch(
        _ handler: String,
        params: JSONValue?,
        to client: any Client
    ) async throws -> JSONValue {
        switch handler {
        case "requestPermission":
            return try await RoleDispatch.serveResult(
                params, as: RequestPermissionRequest.self, client.requestPermission
            )
        case "readTextFile":
            return try await RoleDispatch.serveResult(params, as: ReadTextFileRequest.self, client.readTextFile)
        case "writeTextFile":
            return try await RoleDispatch.serveEmpty(params, as: WriteTextFileRequest.self, client.writeTextFile)
        case "createTerminal":
            return try await RoleDispatch.serveResult(
                params, as: CreateTerminalRequest.self, client.createTerminal
            )
        case "terminalOutput":
            return try await RoleDispatch.serveResult(
                params, as: TerminalOutputRequest.self, client.terminalOutput
            )
        case "waitForTerminalExit":
            return try await RoleDispatch.serveResult(
                params, as: WaitForTerminalExitRequest.self, client.waitForTerminalExit
            )
        case "killTerminal":
            return try await RoleDispatch.serveEmpty(params, as: KillTerminalRequest.self, client.killTerminal)
        case "releaseTerminal":
            return try await RoleDispatch.serveEmpty(
                params, as: ReleaseTerminalRequest.self, client.releaseTerminal
            )
        default:
            throw RequestError.methodNotFound(handler)
        }
    }

    /// Serves one inbound notification by routing it to the held client.
    ///
    /// - Parameters:
    ///   - method: The wire method name.
    ///   - params: The raw notification parameters.
    ///   - holder: The cell holding the client to serve.
    private static func serveNotification(
        method: String,
        params: JSONValue?,
        client holder: RoleHolder<any Client>
    ) async {
        guard let info = served[method], info.kind == .notification, let client = holder.role else {
            return
        }
        switch info.handlerName {
        case "sessionUpdate":
            guard let notification = try? JSONValue.decodeParams(SessionNotification.self, from: params) else {
                return
            }
            await client.sessionUpdate(notification)
        default:
            break
        }
    }

    // MARK: - Outbound (Client → Agent)

    /// Negotiates protocol version and capabilities with the agent.
    ///
    /// - Parameter params: The initialization request.
    /// - Returns: The agent's initialization response.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        try await RoleDispatch.callResult(
            connection, handler: "initialize", on: Self.peerSide, params, returning: InitializeResponse.self
        )
    }

    /// Creates a new session on the agent.
    ///
    /// - Parameter params: The new-session request.
    /// - Returns: The new session's identity and configuration.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        try await RoleDispatch.callResult(
            connection, handler: "newSession", on: Self.peerSide, params, returning: NewSessionResponse.self
        )
    }

    /// Loads an existing session on the agent.
    ///
    /// - Parameter params: The load-session request.
    /// - Returns: The loaded session's configuration.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func loadSession(_ params: LoadSessionRequest) async throws -> LoadSessionResponse {
        try await RoleDispatch.callResult(
            connection, handler: "loadSession", on: Self.peerSide, params, returning: LoadSessionResponse.self
        )
    }

    /// Runs one prompt turn on the agent, returning when the turn stops.
    ///
    /// - Parameter params: The prompt request.
    /// - Returns: The turn's outcome, carrying its `StopReason`.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        try await RoleDispatch.callResult(
            connection, handler: "prompt", on: Self.peerSide, params, returning: PromptResponse.self
        )
    }

    /// Cancels the current turn on the agent.
    ///
    /// - Parameter notification: The cancellation notification.
    /// - Throws: `ConnectionError.closed` after disconnect.
    public func cancel(_ notification: CancelNotification) async throws {
        try await RoleDispatch.notify(connection, handler: "sessionCancel", on: Self.peerSide, notification)
    }

    /// Authenticates with the agent.
    ///
    /// - Parameter params: The authentication request.
    /// - Returns: The authentication response.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func authenticate(_ params: AuthenticateRequest) async throws -> AuthenticateResponse {
        try await RoleDispatch.callResult(
            connection, handler: "authenticate", on: Self.peerSide, params, returning: AuthenticateResponse.self
        )
    }

    /// Sets a session configuration option on the agent.
    ///
    /// - Parameter params: The set-config-option request.
    /// - Returns: The updated configuration options.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func setSessionConfigOption(
        _ params: SetSessionConfigOptionRequest
    ) async throws -> SetSessionConfigOptionResponse {
        try await RoleDispatch.callResult(
            connection, handler: "setSessionConfigOption", on: Self.peerSide,
            params, returning: SetSessionConfigOptionResponse.self
        )
    }

    /// Sets the session mode on the agent.
    ///
    /// - Parameter params: The set-mode request.
    /// - Returns: The set-mode response.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    @available(*, deprecated, message: "Use setSessionConfigOption; session/set_mode is being removed")
    public func setSessionMode(_ params: SetSessionModeRequest) async throws -> SetSessionModeResponse {
        try await RoleDispatch.callResult(
            connection, handler: "setSessionMode", on: Self.peerSide,
            params, returning: SetSessionModeResponse.self
        )
    }

    /// Lists sessions on the agent.
    ///
    /// - Parameter params: The list-sessions request.
    /// - Returns: The listed sessions.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func listSessions(_ params: ListSessionsRequest) async throws -> ListSessionsResponse {
        try await RoleDispatch.callResult(
            connection, handler: "listSessions", on: Self.peerSide, params, returning: ListSessionsResponse.self
        )
    }

    /// Resumes a session on the agent.
    ///
    /// - Parameter params: The resume-session request.
    /// - Returns: The resumed session's configuration.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func resumeSession(_ params: ResumeSessionRequest) async throws -> ResumeSessionResponse {
        try await RoleDispatch.callResult(
            connection, handler: "resumeSession", on: Self.peerSide,
            params, returning: ResumeSessionResponse.self
        )
    }

    /// Deletes a session on the agent.
    ///
    /// - Parameter params: The delete-session request.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func deleteSession(_ params: DeleteSessionRequest) async throws {
        try await RoleDispatch.callEmpty(connection, handler: "deleteSession", on: Self.peerSide, params)
    }

    /// Closes a session on the agent.
    ///
    /// - Parameter params: The close-session request.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func closeSession(_ params: CloseSessionRequest) async throws {
        try await RoleDispatch.callEmpty(connection, handler: "closeSession", on: Self.peerSide, params)
    }

    /// Logs out of the agent.
    ///
    /// - Parameter params: The logout request.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func logout(_ params: LogoutRequest) async throws {
        try await RoleDispatch.callEmpty(connection, handler: "logout", on: Self.peerSide, params)
    }

    /// Shuts the connection down, rejecting every pending request.
    public func close() async {
        await connection.close()
    }
}
