import Foundation

/// The client side of an ACP connection (spec §4).
///
/// Delegates its transport wiring to a shared `RoleConnectionCore`: inbound
/// Agent→Client calls dispatch to the `Client` the factory builds, and the
/// connection itself exposes the outbound Client→Agent calls (`initialize`,
/// `newSession`, `prompt`, and the rest of the agent surface) so a host can
/// drive the agent.
public final class ClientSideConnection: Sendable {
    /// The shared engine owning the connection and the served client.
    private let core: RoleConnectionCore<any Client>

    /// Demultiplexes `session/update` notifications into per-session streams.
    private let router: SessionUpdateRouter

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
    ///     forever.
    ///   - factory: Builds the client from this connection.
    public init(
        stream: any ACPTransport,
        logger: ACPLogger = .disabled,
        requestTimeout: Duration? = nil,
        _ factory: @Sendable (ClientSideConnection) -> any Client
    ) async {
        // The router is captured by the notification dispatcher and by the
        // connection's close handler rather than `self`, preserving the
        // initialization-cycle break the core relies on.
        let router = SessionUpdateRouter()
        core = await RoleConnectionCore(
            stream: stream,
            logger: logger,
            requestTimeout: requestTimeout,
            servedSide: .client,
            peerSide: .agent,
            dispatchRequest: { handler, params, client in
                try await Self.serve(handler, params: params, to: client)
            },
            dispatchNotification: { handler, params, client in
                await Self.serveNotification(handler, params: params, to: client, router: router)
            },
            onClose: { router.finishAll() }
        )
        self.router = router
        core.setRole(factory(self))
    }

    // MARK: - Session update streams

    /// Returns a stream of `session/update` notifications for one session.
    ///
    /// The read loop routes every notification to its session by `sessionId`,
    /// so interleaved sessions demultiplex to their own streams. A stream's
    /// lifetime runs from this call until the connection closes, deliberately
    /// independent of any prompt turn: a `tool_call_update` arriving after the
    /// prompt acknowledgement or after a `session/cancel` is still delivered,
    /// and the stream finishes only when the connection dies. Subscribe before
    /// driving a turn — updates for a session with no active subscriber are
    /// dropped.
    ///
    /// - Parameter sessionId: The session whose updates to observe.
    /// - Returns: A stream of that session's updates.
    public func updates(for sessionId: SessionId) -> AsyncStream<SessionUpdate> {
        router.updates(for: sessionId)
    }

    // MARK: - Inbound dispatch (Agent → Client)

    /// Decodes and dispatches one request to the client's typed handler.
    ///
    /// Each arm binds a wire method to a statically-typed client call; the wire
    /// method's parameter type is only known at compile time, so this typed
    /// binding cannot be replaced by a runtime table over the routing metadata.
    ///
    /// - Parameters:
    ///   - handler: The routing table's handler name for the method.
    ///   - params: The raw request parameters.
    ///   - client: The client to serve.
    /// - Returns: The encoded response value.
    /// - Throws: `RequestError.methodNotFound` for an unknown handler, or any
    ///   error the client throws.
    private static func serve(
        _ handler: String,
        params: JSONValue?,
        to client: any Client
    ) async throws -> JSONValue {
        switch handler {
        case "requestPermission":
            return try await RoleDispatch.serveResult(
                params, as: RequestPermissionRequest.self, client.requestPermission
            )
        default:
            throw RequestError.methodNotFound(handler)
        }
    }

    /// Decodes and dispatches one notification to the session streams and the
    /// client's typed handler.
    ///
    /// A decoded `session/update` is routed to its session stream first, then
    /// delivered to the client's own handler, so a host may consume updates
    /// through either surface.
    ///
    /// - Parameters:
    ///   - handler: The routing table's handler name for the notification.
    ///   - params: The raw notification parameters.
    ///   - client: The client to serve.
    ///   - router: The per-session update router to fan the notification into.
    private static func serveNotification(
        _ handler: String,
        params: JSONValue?,
        to client: any Client,
        router: SessionUpdateRouter
    ) async {
        switch handler {
        case "sessionUpdate":
            guard
                let notification = try? JSONValue.decodeParams(UpdateSessionNotification.self, from: params)
            else {
                return
            }
            router.deliver(notification)
            await client.sessionUpdate(notification)
        default:
            break
        }
    }

    // MARK: - Outbound (Client → Agent)

    /// Negotiates protocol version and capabilities with the agent.
    ///
    /// This package is v2-only by decision (`plan.md`, *Decision: v2 only*):
    /// it validates that the agent answered with exactly the protocol version
    /// this call sent, and fails loud with `ProtocolVersionMismatchError` —
    /// naming both versions — rather than silently proceeding against a peer
    /// that speaks a version this package does not implement.
    ///
    /// - Parameter params: The initialization request.
    /// - Returns: The agent's initialization response.
    /// - Throws: `RequestError` on a peer error, `ConnectionError` on
    ///   disconnect, or `ProtocolVersionMismatchError` when the agent answers
    ///   with a protocol version other than the one sent.
    public func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        let response = try await core.call("initialize", params, returning: InitializeResponse.self)
        guard response.protocolVersion == params.protocolVersion else {
            throw ProtocolVersionMismatchError(sent: params.protocolVersion, received: response.protocolVersion)
        }
        return response
    }

    /// Creates a new session on the agent.
    ///
    /// - Parameter params: The new-session request.
    /// - Returns: The new session's identity and configuration.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        try await core.call("newSession", params, returning: NewSessionResponse.self)
    }

    /// Lists sessions on the agent.
    ///
    /// - Parameter params: The list-sessions request.
    /// - Returns: The listed sessions, optionally paginated.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func listSessions(_ params: ListSessionsRequest) async throws -> ListSessionsResponse {
        try await core.call("listSessions", params, returning: ListSessionsResponse.self)
    }

    /// Resumes an existing session on the agent, optionally replaying history.
    ///
    /// - Parameter params: The resume-session request.
    /// - Returns: The resumed session's configuration.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func resumeSession(_ params: ResumeSessionRequest) async throws -> ResumeSessionResponse {
        try await core.call("resumeSession", params, returning: ResumeSessionResponse.self)
    }

    /// Closes a session on the agent.
    ///
    /// - Parameter params: The close-session request.
    /// - Returns: The close-session response.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func closeSession(_ params: CloseSessionRequest) async throws -> CloseSessionResponse {
        try await core.call("closeSession", params, returning: CloseSessionResponse.self)
    }

    /// Runs one prompt turn on the agent.
    ///
    /// Acknowledges immediately; the turn's progress and completion arrive
    /// separately, as `state_update` notifications on `updates(for:)` or the
    /// `Client`'s own `sessionUpdate` handler — not as this call's return
    /// value.
    ///
    /// - Parameter params: The prompt request.
    /// - Returns: The immediate acknowledgement.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        try await core.call("prompt", params, returning: PromptResponse.self)
    }

    /// Cancels the current turn on the agent.
    ///
    /// Cancellation is confirmed by an `idle` `state_update` carrying
    /// `stopReason: "cancelled"`, not by this notification returning.
    ///
    /// - Parameter notification: The cancellation notification.
    /// - Throws: `ConnectionError.closed` after disconnect.
    public func sessionCancel(_ notification: CancelSessionNotification) async throws {
        try await core.notify("sessionCancel", notification)
    }

    /// Authenticates with the agent.
    ///
    /// - Parameter params: The login request, naming the method to use.
    /// - Returns: The login response.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func loginAuth(_ params: LoginAuthRequest) async throws -> LoginAuthResponse {
        try await core.call("loginAuth", params, returning: LoginAuthResponse.self)
    }

    /// Logs out of the agent.
    ///
    /// - Parameter params: The logout request.
    /// - Returns: The logout response.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func logoutAuth(_ params: LogoutAuthRequest) async throws -> LogoutAuthResponse {
        try await core.call("logoutAuth", params, returning: LogoutAuthResponse.self)
    }

    /// Deletes a session outright on the agent.
    ///
    /// - Parameter params: The delete-session request.
    /// - Returns: The delete-session response.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func deleteSession(_ params: DeleteSessionRequest) async throws -> DeleteSessionResponse {
        try await core.call("deleteSession", params, returning: DeleteSessionResponse.self)
    }

    /// Sets a session configuration option on the agent.
    ///
    /// - Parameter params: The set-config-option request.
    /// - Returns: The full, updated set of configuration options.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func setSessionConfigOption(
        _ params: SetSessionConfigOptionRequest
    ) async throws -> SetSessionConfigOptionResponse {
        try await core.call("setSessionConfigOption", params, returning: SetSessionConfigOptionResponse.self)
    }

    /// Shuts the connection down, rejecting every pending request.
    public func close() async {
        await core.close()
    }
}
