import Foundation

/// The agent side of an ACP connection (spec §4).
///
/// Delegates its transport wiring to a shared `RoleConnectionCore`: inbound
/// Client→Agent calls dispatch to the `Agent` the factory builds, and the
/// connection itself exposes the outbound Agent→Client calls
/// (`sessionUpdate`, `requestPermission`) so the agent can drive the client
/// mid-turn — most importantly to request permission without ever blocking
/// the read loop that keeps `session/cancel` and other traffic flowing.
public final class AgentSideConnection: Sendable {
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
    ///     forever (`requestPermission` relies on this).
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
            peerSide: .client,
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
        case "listSessions":
            return try await RoleDispatch.serveResult(params, as: ListSessionsRequest.self, agent.listSessions)
        case "resumeSession":
            return try await RoleDispatch.serveResult(params, as: ResumeSessionRequest.self, agent.resumeSession)
        case "closeSession":
            return try await RoleDispatch.serveResult(params, as: CloseSessionRequest.self, agent.closeSession)
        case "prompt":
            return try await RoleDispatch.serveResult(params, as: PromptRequest.self, agent.prompt)
        case "loginAuth":
            return try await RoleDispatch.serveResult(params, as: LoginAuthRequest.self, agent.loginAuth)
        case "logoutAuth":
            return try await RoleDispatch.serveResult(params, as: LogoutAuthRequest.self, agent.logoutAuth)
        case "deleteSession":
            return try await RoleDispatch.serveResult(params, as: DeleteSessionRequest.self, agent.deleteSession)
        case "setSessionConfigOption":
            return try await RoleDispatch.serveResult(
                params, as: SetSessionConfigOptionRequest.self, agent.setSessionConfigOption
            )
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
            guard
                let notification = try? JSONValue.decodeParams(CancelSessionNotification.self, from: params)
            else {
                return
            }
            await agent.sessionCancel(notification)
        default:
            break
        }
    }

    // MARK: - Outbound (Agent → Client)

    /// Sends a streamed session update to the client.
    ///
    /// - Parameter notification: The session-update notification.
    /// - Throws: `ConnectionError.closed` after disconnect.
    public func sessionUpdate(_ notification: UpdateSessionNotification) async throws {
        try await core.notify("sessionUpdate", notification)
    }

    /// Requests permission from the client mid-turn.
    ///
    /// The one long-lived request on the stable surface: it genuinely waits on
    /// a human, and never blocks the read loop — each inbound request the
    /// underlying connection serves runs in its own `Task`, so this call
    /// suspends only the caller, not the connection.
    ///
    /// - Parameter params: The permission request.
    /// - Returns: The user's permission decision.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func requestPermission(
        _ params: RequestPermissionRequest
    ) async throws -> RequestPermissionResponse {
        try await core.call("requestPermission", params, returning: RequestPermissionResponse.self)
    }

    /// Shuts the connection down, rejecting every pending request.
    public func close() async {
        await core.close()
    }

    // MARK: - Deferred post-response work

    /// Defers `work` until after this connection has written the response to
    /// whichever inbound request is currently being handled on the calling
    /// task — most importantly `prompt(_:)`, whose response must reach the
    /// wire before the `running` `state_update` that reports the turn it just
    /// accepted (spec §*Prompt Lifecycle*, "acknowledges acceptance").
    ///
    /// A handler cannot simply spawn a `Task` for that first `session/update`
    /// and return: the new `Task` is an independent unit of concurrency that
    /// can reach the wire before this connection's own response-writing task
    /// does, depending on scheduling — a real race, not a hypothetical one.
    /// This defers `work` to run only once the response is *provably*
    /// written, by having the request-dispatch task itself run it right after
    /// `respond`, rather than leaving the ordering to whichever task happens
    /// to reach the transport first.
    ///
    /// Must be called synchronously from within the handler — i.e., before it
    /// returns, with no intervening `await` that could hop to a different
    /// task — and the handler itself must be running on the task dispatching
    /// the request it wants to follow (true for every `Agent` method, which
    /// `RoleConnectionCore` always calls directly, never via a spawned `Task`).
    /// Calling this outside of handling an inbound request is a no-op: there
    /// is no current request to follow, so `work` is silently dropped rather
    /// than run at an arbitrary, unspecified time.
    ///
    /// - Parameter work: The deferred work, run once the current request's
    ///   response has been handed to the transport.
    public func afterRespondingToCurrentRequest(_ work: @escaping @Sendable () async -> Void) {
        Connection.currentResponseHooks?.append(work)
    }
}
