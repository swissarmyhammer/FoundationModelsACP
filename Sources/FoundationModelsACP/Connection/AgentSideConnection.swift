import Foundation

/// The agent side of an ACP connection (spec §4).
///
/// Delegates its transport wiring to a shared `RoleConnectionCore`: inbound
/// Client→Agent calls dispatch to the `Agent` the factory builds, and the
/// connection itself exposes the outbound Agent→Client calls (`sessionUpdate`,
/// `requestPermission`, the `fs/*` and `terminal/*` methods) so the agent can
/// drive the client mid-turn.
public final class AgentSideConnection: Sendable {
    /// The side this connection calls outbound: the client-side methods.
    private static let peerSide: MethodSide = .client

    /// The shared engine owning the connection and the served agent.
    private let core: RoleConnectionCore<any Agent>

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
        core = await RoleConnectionCore(
            stream: stream,
            logger: logger,
            requestTimeout: requestTimeout,
            servedSide: .agent,
            dispatchRequest: { handler, params, agent in
                try await Self.serve(handler, params: params, to: agent)
            },
            dispatchNotification: { handler, params, agent in
                await Self.serveNotification(handler, params: params, to: agent)
            }
        )
        core.setRole(factory(self))
    }

    // MARK: - Inbound dispatch (Client → Agent)

    /// Decodes and dispatches one request to the agent's typed handler.
    ///
    /// Each arm binds a wire method to a statically-typed agent call; the wire
    /// method's parameter type is only known at compile time, so this typed
    /// binding cannot be replaced by a runtime table over the routing metadata.
    ///
    /// - Parameters:
    ///   - handler: The routing table's handler name for the method.
    ///   - params: The raw request parameters.
    ///   - agent: The agent to serve.
    /// - Returns: The encoded response value.
    /// - Throws: `RequestError.methodNotFound` for an unknown handler, or any
    ///   error the agent throws.
    private static func serve(
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

    /// Decodes and dispatches one notification to the agent's typed handler.
    ///
    /// - Parameters:
    ///   - handler: The routing table's handler name for the notification.
    ///   - params: The raw notification parameters.
    ///   - agent: The agent to serve.
    private static func serveNotification(
        _ handler: String,
        params: JSONValue?,
        to agent: any Agent
    ) async {
        switch handler {
        case "sessionCancel":
            guard let notification = try? JSONValue.decodeParams(CancelNotification.self, from: params) else {
                return
            }
            await agent.cancel(notification)
        default:
            break
        }
    }

    // MARK: - Outbound helpers (Agent → Client)

    /// Issues an outbound client request and decodes its typed response.
    ///
    /// - Parameters:
    ///   - handler: The Swift handler name of the client method to call.
    ///   - params: The typed request parameters.
    ///   - responseType: The expected response model type.
    /// - Returns: The decoded response.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    private func call<Request: Encodable, Response: Decodable>(
        _ handler: String,
        _ params: Request,
        returning responseType: Response.Type
    ) async throws -> Response {
        try await RoleDispatch.callResult(
            core.connection, handler: handler, on: Self.peerSide, params, returning: responseType
        )
    }

    /// Issues an outbound client request whose response carries no value.
    ///
    /// - Parameters:
    ///   - handler: The Swift handler name of the client method to call.
    ///   - params: The typed request parameters.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    private func callEmpty<Request: Encodable>(_ handler: String, _ params: Request) async throws {
        try await RoleDispatch.callEmpty(core.connection, handler: handler, on: Self.peerSide, params)
    }

    /// Sends an outbound client notification.
    ///
    /// - Parameters:
    ///   - handler: The Swift handler name of the client notification to send.
    ///   - params: The typed notification parameters.
    /// - Throws: `ConnectionError.closed` after disconnect.
    private func notify<Params: Encodable>(_ handler: String, _ params: Params) async throws {
        try await RoleDispatch.notify(core.connection, handler: handler, on: Self.peerSide, params)
    }

    // MARK: - Outbound (Agent → Client)

    /// Sends a streamed session update to the client.
    ///
    /// - Parameter notification: The session-update notification.
    /// - Throws: `ConnectionError.closed` after disconnect.
    public func sessionUpdate(_ notification: SessionNotification) async throws {
        try await notify("sessionUpdate", notification)
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
        try await call("requestPermission", params, returning: RequestPermissionResponse.self)
    }

    /// Reads a text file through the client.
    ///
    /// - Parameter params: The read request.
    /// - Returns: The file contents.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func readTextFile(_ params: ReadTextFileRequest) async throws -> ReadTextFileResponse {
        try await call("readTextFile", params, returning: ReadTextFileResponse.self)
    }

    /// Writes a text file through the client.
    ///
    /// - Parameter params: The write request.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func writeTextFile(_ params: WriteTextFileRequest) async throws {
        try await callEmpty("writeTextFile", params)
    }

    /// Creates a terminal on the client.
    ///
    /// - Parameter params: The create-terminal request.
    /// - Returns: The created terminal's identity.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func createTerminal(_ params: CreateTerminalRequest) async throws -> CreateTerminalResponse {
        try await call("createTerminal", params, returning: CreateTerminalResponse.self)
    }

    /// Reads a bounded snapshot of a terminal's output from the client.
    ///
    /// - Parameter params: The output request.
    /// - Returns: The output snapshot.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func terminalOutput(_ params: TerminalOutputRequest) async throws -> TerminalOutputResponse {
        try await call("terminalOutput", params, returning: TerminalOutputResponse.self)
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
        try await call("waitForTerminalExit", params, returning: WaitForTerminalExitResponse.self)
    }

    /// Kills a terminal's process on the client.
    ///
    /// - Parameter params: The kill request.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func killTerminal(_ params: KillTerminalRequest) async throws {
        try await callEmpty("killTerminal", params)
    }

    /// Releases a terminal's resources on the client.
    ///
    /// - Parameter params: The release request.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func releaseTerminal(_ params: ReleaseTerminalRequest) async throws {
        try await callEmpty("releaseTerminal", params)
    }

    /// Shuts the connection down, rejecting every pending request.
    public func close() async {
        await core.close()
    }
}
