import Foundation

/// The agent side of an ACP connection (spec §4).
///
/// Wraps one full-duplex `Connection`: inbound Client→Agent calls dispatch to
/// the `Agent` the factory builds, and the connection itself exposes the
/// outbound Agent→Client calls (`sessionUpdate`, `requestPermission`, the
/// `fs/*` and `terminal/*` methods) so the agent can drive the client mid-turn.
public final class AgentSideConnection: Sendable {
    /// The side this connection serves inbound: the agent-side methods.
    private static let servedSide: MethodSide = .agent

    /// The side this connection calls outbound: the client-side methods.
    private static let peerSide: MethodSide = .client

    /// The agent-side methods this connection serves, keyed by wire name.
    private static let served = RoleRouting.served(on: servedSide)

    /// The underlying full-duplex JSON-RPC engine.
    private let connection: Connection

    /// Creates the connection, wires the factory's agent, and starts serving.
    ///
    /// The factory receives this connection so the agent it builds can capture
    /// it and issue reverse Agent→Client calls. The agent is stored before the
    /// read loop can dispatch, so the first inbound call always finds it.
    ///
    /// - Parameters:
    ///   - stream: The bidirectional transport to run over.
    ///   - logger: Diagnostic sink; never stdout.
    ///   - requestTimeout: Default outbound request timeout; `nil` waits
    ///     forever (long-lived calls rely on this).
    ///   - factory: Builds the agent from this connection.
    public init(
        stream: any ACPTransport,
        logger: ACPLogger = .disabled,
        requestTimeout: Duration? = nil,
        _ factory: @Sendable (AgentSideConnection) -> any Agent
    ) async {
        let holder = RoleHolder<any Agent>()
        connection = await Connection(
            transport: stream,
            logger: logger,
            requestTimeout: requestTimeout,
            requestHandler: { method, params in
                try await Self.serveRequest(method: method, params: params, agent: holder)
            },
            notificationHandler: { method, params in
                await Self.serveNotification(method: method, params: params, agent: holder)
            }
        )
        holder.set(factory(self))
    }

    // MARK: - Inbound (Client → Agent)

    /// Serves one inbound request by routing it to the held agent.
    ///
    /// - Parameters:
    ///   - method: The wire method name.
    ///   - params: The raw request parameters.
    ///   - holder: The cell holding the agent to serve.
    /// - Returns: The encoded response value.
    /// - Throws: `RequestError.methodNotFound` for an unrouted method, or any
    ///   error the agent throws.
    private static func serveRequest(
        method: String,
        params: JSONValue?,
        agent holder: RoleHolder<any Agent>
    ) async throws -> JSONValue {
        guard let info = served[method], info.kind == .request, let agent = holder.role else {
            throw RequestError.methodNotFound(method)
        }
        return try await dispatch(info.handlerName, params: params, to: agent)
    }

    /// Decodes and dispatches one request to the agent's typed handler.
    ///
    /// - Parameters:
    ///   - handler: The routing table's handler name for the method.
    ///   - params: The raw request parameters.
    ///   - agent: The agent to serve.
    /// - Returns: The encoded response value.
    /// - Throws: `RequestError.methodNotFound` for an unknown handler, or any
    ///   error the agent throws.
    private static func dispatch(
        _ handler: String,
        params: JSONValue?,
        to agent: any Agent
    ) async throws -> JSONValue {
        switch handler {
        case "initialize":
            return try await RoleDispatch.serveResult(params, as: InitializeRequest.self, agent.initialize)
        case "newSession":
            return try await RoleDispatch.serveResult(params, as: NewSessionRequest.self, agent.newSession)
        case "loadSession":
            return try await RoleDispatch.serveResult(params, as: LoadSessionRequest.self, agent.loadSession)
        case "prompt":
            return try await RoleDispatch.serveResult(params, as: PromptRequest.self, agent.prompt)
        case "authenticate":
            return try await RoleDispatch.serveResult(params, as: AuthenticateRequest.self, agent.authenticate)
        case "setSessionConfigOption":
            return try await RoleDispatch.serveResult(
                params, as: SetSessionConfigOptionRequest.self, agent.setSessionConfigOption
            )
        case "setSessionMode":
            let router: any DeprecatedRouting = DeprecatedRouter()
            return try await router.routeSetSessionMode(agent, params: params)
        case "listSessions":
            return try await RoleDispatch.serveResult(params, as: ListSessionsRequest.self, agent.listSessions)
        case "resumeSession":
            return try await RoleDispatch.serveResult(params, as: ResumeSessionRequest.self, agent.resumeSession)
        case "deleteSession":
            return try await RoleDispatch.serveEmpty(params, as: DeleteSessionRequest.self, agent.deleteSession)
        case "closeSession":
            return try await RoleDispatch.serveEmpty(params, as: CloseSessionRequest.self, agent.closeSession)
        case "logout":
            return try await RoleDispatch.serveEmpty(params, as: LogoutRequest.self, agent.logout)
        default:
            throw RequestError.methodNotFound(handler)
        }
    }

    /// Serves one inbound notification by routing it to the held agent.
    ///
    /// - Parameters:
    ///   - method: The wire method name.
    ///   - params: The raw notification parameters.
    ///   - holder: The cell holding the agent to serve.
    private static func serveNotification(
        method: String,
        params: JSONValue?,
        agent holder: RoleHolder<any Agent>
    ) async {
        guard let info = served[method], info.kind == .notification, let agent = holder.role else {
            return
        }
        switch info.handlerName {
        case "sessionCancel":
            guard let notification = try? JSONValue.decodeParams(CancelNotification.self, from: params) else {
                return
            }
            await agent.cancel(notification)
        default:
            break
        }
    }

    // MARK: - Outbound (Agent → Client)

    /// Sends a streamed session update to the client.
    ///
    /// - Parameter notification: The session-update notification.
    /// - Throws: `ConnectionError.closed` after disconnect.
    public func sessionUpdate(_ notification: SessionNotification) async throws {
        try await RoleDispatch.notify(connection, handler: "sessionUpdate", on: Self.peerSide, notification)
    }

    /// Requests permission from the client mid-turn.
    ///
    /// - Parameter params: The permission request.
    /// - Returns: The user's permission decision.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func requestPermission(
        _ params: RequestPermissionRequest
    ) async throws -> RequestPermissionResponse {
        try await RoleDispatch.callResult(
            connection, handler: "requestPermission", on: Self.peerSide,
            params, returning: RequestPermissionResponse.self
        )
    }

    /// Reads a text file through the client.
    ///
    /// - Parameter params: The read request.
    /// - Returns: The file contents.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func readTextFile(_ params: ReadTextFileRequest) async throws -> ReadTextFileResponse {
        try await RoleDispatch.callResult(
            connection, handler: "readTextFile", on: Self.peerSide,
            params, returning: ReadTextFileResponse.self
        )
    }

    /// Writes a text file through the client.
    ///
    /// - Parameter params: The write request.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func writeTextFile(_ params: WriteTextFileRequest) async throws {
        try await RoleDispatch.callEmpty(connection, handler: "writeTextFile", on: Self.peerSide, params)
    }

    /// Creates a terminal on the client.
    ///
    /// - Parameter params: The create-terminal request.
    /// - Returns: The created terminal's identity.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func createTerminal(_ params: CreateTerminalRequest) async throws -> CreateTerminalResponse {
        try await RoleDispatch.callResult(
            connection, handler: "createTerminal", on: Self.peerSide,
            params, returning: CreateTerminalResponse.self
        )
    }

    /// Reads a bounded snapshot of a terminal's output from the client.
    ///
    /// - Parameter params: The output request.
    /// - Returns: The output snapshot.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func terminalOutput(_ params: TerminalOutputRequest) async throws -> TerminalOutputResponse {
        try await RoleDispatch.callResult(
            connection, handler: "terminalOutput", on: Self.peerSide,
            params, returning: TerminalOutputResponse.self
        )
    }

    /// Waits for a terminal's process to exit on the client.
    ///
    /// - Parameter params: The wait request.
    /// - Returns: The process's exit status.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func waitForTerminalExit(
        _ params: WaitForTerminalExitRequest
    ) async throws -> WaitForTerminalExitResponse {
        try await RoleDispatch.callResult(
            connection, handler: "waitForTerminalExit", on: Self.peerSide,
            params, returning: WaitForTerminalExitResponse.self
        )
    }

    /// Kills a terminal's process on the client.
    ///
    /// - Parameter params: The kill request.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func killTerminal(_ params: KillTerminalRequest) async throws {
        try await RoleDispatch.callEmpty(connection, handler: "killTerminal", on: Self.peerSide, params)
    }

    /// Releases a terminal's resources on the client.
    ///
    /// - Parameter params: The release request.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func releaseTerminal(_ params: ReleaseTerminalRequest) async throws {
        try await RoleDispatch.callEmpty(connection, handler: "releaseTerminal", on: Self.peerSide, params)
    }

    /// Shuts the connection down, rejecting every pending request.
    public func close() async {
        await connection.close()
    }
}
