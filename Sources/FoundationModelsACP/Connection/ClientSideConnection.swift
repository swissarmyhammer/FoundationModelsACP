import Foundation

/// The client side of an ACP connection (spec §4).
///
/// Delegates its transport wiring to a shared `RoleConnectionCore`: inbound
/// Agent→Client calls dispatch to the `Client` the factory builds, and the
/// connection itself exposes the outbound Client→Agent calls (`initialize`,
/// `newSession`, `prompt`, and the rest of the agent surface) so a host can
/// drive the agent.
public final class ClientSideConnection: Sendable {
    /// The prefix of each diagnostic that this type writes to the logger.
    private static let logPrefix = "ClientSideConnection: "

    /// The `session/update` params member that holds the update.
    private static let updateMemberKey = "update"

    /// The update member that names the variant of a `session/update`.
    private static let updateDiscriminatorKey = "sessionUpdate"

    /// The text that a warning shows for a value that the params do not hold.
    private static let absentValueText = "<absent>"

    /// The shared engine owning the connection and the served client.
    private let core: RoleConnectionCore<any Client>

    /// Demultiplexes `session/update` notifications into per-session streams.
    private let router: SessionUpdateRouter

    /// The inbound `session/request_permission` requests that wait for an
    /// answer, by session. ``sessionCancel(_:)`` answers them.
    private let permissions: PendingPermissionRequests

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
    ///   - bufferLimits: The limits on the `session/update` notifications that
    ///     the connection keeps for sessions with no subscriber. See
    ///     ``subscribe(to:)``.
    ///   - factory: Builds the client from this connection.
    public init(
        stream: any ACPTransport,
        logger: ACPLogger = .disabled,
        requestTimeout: Duration? = nil,
        bufferLimits: SessionUpdateBufferLimits = .default,
        _ factory: @Sendable (ClientSideConnection) -> any Client
    ) async {
        // The router is captured by the notification dispatcher and by the
        // connection's close handler rather than `self`, preserving the
        // initialization-cycle break the core relies on.
        let router = SessionUpdateRouter(limits: bufferLimits, logger: logger)
        let permissions = PendingPermissionRequests()
        // The tracker gives each finished session request to the router at
        // the wire position of its response, before the caller resumes.
        let outgoingRequests = OutgoingRequestTracker { finished in router.deliver(finished) }
        core = await RoleConnectionCore(
            stream: stream,
            logger: logger,
            requestTimeout: requestTimeout,
            servedSide: .client,
            peerSide: .agent,
            dispatchRequest: { handler, params, client in
                try await Self.serve(handler, params: params, to: client, permissions: permissions)
            },
            dispatchNotification: { handler, params, client in
                await Self.serveNotification(handler, params: params, to: client, router: router, logger: logger)
            },
            onClose: { router.finishAll() },
            outgoingRequests: outgoingRequests
        )
        self.router = router
        self.permissions = permissions
        core.setRole(factory(self))
    }

    // MARK: - Session update streams

    /// Subscribes to the `session/update` notifications of one session.
    ///
    /// The read loop routes every notification to its session by `sessionId`,
    /// so interleaved sessions demultiplex to their own streams. A stream's
    /// lifetime runs from this call until the connection closes, deliberately
    /// independent of any prompt turn: a `tool_call_update` arriving after the
    /// prompt acknowledgement or after a `session/cancel` is still delivered,
    /// and the stream finishes only when the connection dies.
    ///
    /// The connection keeps the updates of a session that has no subscriber,
    /// up to the `bufferLimits` given to the initializer. The first
    /// subscription to the session gets these kept updates first, in order,
    /// and then the live updates. A subsequent subscription gets only the live
    /// updates. Thus an update that the agent sends before the `session/new`
    /// response is not lost: subscribe when the response gives the session ID.
    ///
    /// When a limit makes the connection discard kept updates, the connection
    /// logs a warning and marks the session. The first subscription reads the
    /// mark in ``SessionUpdateSubscription/hasMissedUpdates``. The connection
    /// discards the kept updates and the mark of a session when
    /// ``closeSession(_:)`` closes it, and discards all of them when the
    /// connection closes.
    ///
    /// The stream also gets one
    /// ``SessionStreamEvent/requestFinished(id:method:outcome:)`` marker for
    /// each request of this connection whose params name the session, at the
    /// wire position of the response. The connection yields the marker before
    /// the call returns or throws. A failed request (an error response, a
    /// cancelled call, a timeout, a failed write, or connection close) gives
    /// a marker with ``OutgoingRequestOutcome/failed``.
    ///
    /// To resume a session, subscribe before you call ``resumeSession(_:)``:
    /// the session ID is known, and the replayed updates then go to your
    /// subscription in order. The `session/resume` marker comes after the
    /// last replayed update. Thus, when your task reads that marker, it
    /// applied all of the replay.
    ///
    /// - Parameter sessionId: The session whose updates to observe.
    /// - Returns: The subscription: the stream of the session's updates and
    ///   request markers, and the mark that tells if updates were discarded
    ///   before it.
    public func subscribe(to sessionId: SessionId) -> SessionUpdateSubscription {
        router.subscribe(to: sessionId)
    }

    // MARK: - Outgoing requests

    /// Subscribes to the start and the finish of each request that this
    /// connection sends to the agent.
    ///
    /// Use the events to match an ID that the agent names to a request of the
    /// client. For example, a request-scoped elicitation names the ID of a
    /// client request in ``ElicitationRequestScope/requestId``. A client can
    /// show the elicitation while that request is in flight, and remove it on
    /// ``OutgoingRequestEvent/finished(id:)``.
    ///
    /// The stream first gets one ``OutgoingRequestEvent/started(id:method:)``
    /// for each request that is in flight when you subscribe, in start order.
    /// Then it gets the live events. Each subscription gets every event. The
    /// connection sends `started` before it writes the request, and sends
    /// `finished` before the call returns or throws. The request finishes on
    /// a result, an error, a cancelled call, a timeout, a failed write, or
    /// connection close. When the connection closes, the stream gets
    /// `finished` for each request that is in flight, and then the stream
    /// finishes. A subscription after close gets a stream that is already
    /// finished.
    ///
    /// The stream keeps all events until you read them. Read the stream, or
    /// stop the iteration, so that it does not keep events that you do not
    /// need.
    ///
    /// - Returns: A stream of the outgoing-request events.
    public func subscribeToOutgoingRequests() -> AsyncStream<OutgoingRequestEvent> {
        core.outgoingRequests.subscribe()
    }

    /// Gives the wire method of one request that this connection sent to the
    /// agent and that has not finished.
    ///
    /// The lookup is synchronous. It agrees with
    /// ``subscribeToOutgoingRequests()``: it gives the method after
    /// ``OutgoingRequestEvent/started(id:method:)`` and `nil` after
    /// ``OutgoingRequestEvent/finished(id:)``. For example, when a
    /// request-scoped elicitation arrives during `loginAuth(_:)`,
    /// `inFlightMethod(for: scope.requestId)` gives `auth/login`.
    ///
    /// - Parameter requestId: The JSON-RPC ID of the request.
    /// - Returns: The wire method of the request, or `nil` when no in-flight
    ///   request of this connection has this ID.
    public func inFlightMethod(for requestId: RequestId) -> String? {
        core.outgoingRequests.method(for: requestId)
    }

    // MARK: - Inbound dispatch (Agent → Client)

    /// Decodes and dispatches one request to the client's typed handler.
    ///
    /// Each arm binds a wire method to a statically-typed client call; the wire
    /// method's parameter type is only known at compile time, so this typed
    /// binding cannot be replaced by a runtime table over the routing metadata.
    ///
    /// A permission request goes through `permissions`, so that
    /// ``sessionCancel(_:)`` can answer it before the handler returns.
    ///
    /// - Parameters:
    ///   - handler: The routing table's handler name for the method.
    ///   - params: The raw request parameters.
    ///   - client: The client to serve.
    ///   - permissions: The permission requests that wait for an answer.
    /// - Returns: The encoded response value.
    /// - Throws: `RequestError.methodNotFound` for an unknown handler, or any
    ///   error the client throws.
    private static func serve(
        _ handler: String,
        params: JSONValue?,
        to client: any Client,
        permissions: PendingPermissionRequests
    ) async throws -> JSONValue {
        switch handler {
        case "requestPermission":
            return try await RoleDispatch.serveResult(params, as: RequestPermissionRequest.self) { request in
                try await permissions.answer(request) { try await client.requestPermission($0) }
            }
        case "createElicitation":
            return try await RoleDispatch.serveResult(
                params, as: CreateElicitationRequest.self, client.createElicitation
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
    /// through either surface. A `session/update` that does not decode goes
    /// to `logger` as a warning (see `serveSessionUpdate`).
    ///
    /// - Parameters:
    ///   - handler: The routing table's handler name for the notification.
    ///   - params: The raw notification parameters.
    ///   - client: The client to serve.
    ///   - router: The per-session update router to fan the notification into.
    ///   - logger: The connection logger.
    private static func serveNotification(
        _ handler: String,
        params: JSONValue?,
        to client: any Client,
        router: SessionUpdateRouter,
        logger: ACPLogger
    ) async {
        switch handler {
        case "sessionUpdate":
            await serveSessionUpdate(handler, params: params, to: client, router: router, logger: logger)
        case "elicitationComplete":
            guard
                let notification = try? JSONValue.decodeParams(CompleteElicitationNotification.self, from: params)
            else {
                return
            }
            await client.elicitationComplete(notification)
        default:
            break
        }
    }

    /// Decodes one `session/update` and gives it to the session streams and
    /// to the client's handler.
    ///
    /// The schema keeps an unknown `sessionUpdate` variant as raw data, but a
    /// known variant with a malformed payload does not decode. The connection
    /// then drops the notification, writes one warning to `logger`, and
    /// continues to read. The warning names the session (when the params
    /// hold a string `sessionId`), the `sessionUpdate` discriminator, and the
    /// decoding error, so that a schema difference with the agent is visible.
    ///
    /// - Parameters:
    ///   - handler: The routing table's handler name for the notification.
    ///   - params: The raw notification parameters.
    ///   - client: The client to serve.
    ///   - router: The per-session update router to fan the notification into.
    ///   - logger: The connection logger.
    private static func serveSessionUpdate(
        _ handler: String,
        params: JSONValue?,
        to client: any Client,
        router: SessionUpdateRouter,
        logger: ACPLogger
    ) async {
        let notification: UpdateSessionNotification
        do {
            notification = try JSONValue.decodeParamsKeepingCause(UpdateSessionNotification.self, from: params)
        } catch {
            logger.log(undecodableUpdateWarning(handler, params: params, error: error))
            return
        }
        router.deliver(notification)
        await client.sessionUpdate(notification)
    }

    /// The warning for a `session/update` notification that does not decode.
    ///
    /// - Parameters:
    ///   - handler: The routing table's handler name for the notification.
    ///   - params: The raw notification parameters.
    ///   - error: The decoding error.
    /// - Returns: The warning text.
    private static func undecodableUpdateWarning(_ handler: String, params: JSONValue?, error: any Error) -> String {
        let method = RoleRouting.wireMethod(for: handler, on: .client)
        let session = SessionId(namedIn: params)?.rawValue ?? absentValueText
        let variant = updateDiscriminator(namedIn: params) ?? absentValueText
        return logPrefix
            + "dropped a \(method) notification that does not decode "
            + "(sessionId: \(session), sessionUpdate: \(variant)): \(error)"
    }

    /// Reads the `sessionUpdate` discriminator that the raw params of a
    /// `session/update` name.
    ///
    /// - Parameter params: The raw notification parameters.
    /// - Returns: The discriminator, or `nil` when the params do not hold an
    ///   `update` object with a string `sessionUpdate` member.
    private static func updateDiscriminator(namedIn params: JSONValue?) -> String? {
        guard
            case .object(let members) = params,
            case .object(let update) = members[updateMemberKey],
            case .string(let discriminator) = update[updateDiscriminatorKey]
        else {
            return nil
        }
        return discriminator
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
    /// When the call completes, with or without an error, the connection
    /// discards the `session/update` notifications that it kept for the
    /// session and the overflow mark of the session. Subscriptions to the
    /// session stay open.
    ///
    /// - Parameter params: The close-session request.
    /// - Returns: The close-session response.
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func closeSession(_ params: CloseSessionRequest) async throws -> CloseSessionResponse {
        defer { router.discardPendingUpdates(for: params.sessionId) }
        return try await core.call("closeSession", params, returning: CloseSessionResponse.self)
    }

    /// Runs one prompt turn on the agent.
    ///
    /// Acknowledges immediately; the turn's progress and completion arrive
    /// separately, as `state_update` notifications on `subscribe(to:)` or the
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
    /// The spec says that the client MUST answer each pending
    /// `session/request_permission` of the session with the `cancelled`
    /// outcome. This method does that for you: after it writes the
    /// notification, it answers each permission request of the session that
    /// waits for ``Client/requestPermission(_:)``. It does not wait for the
    /// handler. The connection cancels the task of the handler and ignores
    /// its late result. Deferred work that the handler registered before the
    /// answer runs after the `cancelled` response. Deferred work that it
    /// registers later does not run (see
    /// ``afterRespondingToCurrentRequest(_:)``). The connection answers the
    /// requests also when the write of the notification fails. A permission
    /// request that arrives after this call goes to the handler as usual.
    ///
    /// The spec also says that the client SHOULD mark the unfinished tool
    /// calls of the session as `cancelled` at once. Call
    /// ``SessionMergeEngine/cancelUnfinishedToolCalls()`` on the engine of
    /// the session after this method returns. The updates that the agent
    /// sends after the cancel still arrive, and the engine applies them as
    /// usual.
    ///
    /// - Parameter notification: The cancellation notification.
    /// - Throws: `ConnectionError.closed` after disconnect.
    public func sessionCancel(_ notification: CancelSessionNotification) async throws {
        defer { permissions.cancelAll(in: notification.sessionId) }
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
    ///
    /// When the connection is open, the close reason becomes
    /// ``ConnectionCloseReason/closedLocally``. When it already closed, the
    /// call has no effect, and ``closed`` keeps the first reason.
    public func close() async {
        await core.close()
    }

    /// Waits until the connection closed, and gives the reason.
    ///
    /// Use this value to show the state of the connection. For example, the
    /// agent process stops, and the value is
    /// ``ConnectionCloseReason/endOfInput``, or the read from the agent
    /// fails, and the value is ``ConnectionCloseReason/transportFailed(_:)``
    /// with the error.
    ///
    /// The value comes one time for each connection, and each waiter gets
    /// the same reason. A waiter that starts after the close gets the reason
    /// at once. The first event that closes the connection sets the reason:
    /// the end of input, a failure of the input stream, or ``close()``.
    ///
    /// The value comes only after each inbound handler of the client ended,
    /// finished or cancelled, and after the session update streams finished.
    /// Thus the client can release its state with no race against a handler
    /// that still runs.
    ///
    /// Do not wait for this value in a client method: the value waits for
    /// that method to end. The wait does not stop when the waiting task is
    /// cancelled.
    public var closed: ConnectionCloseReason {
        get async { await core.closed }
    }

    // MARK: - Deferred post-response work

    /// Defers `work` until after this connection has written the response to
    /// the inbound request that the calling task handles: the
    /// `session/request_permission` response in ``Client/requestPermission(_:)``,
    /// or the `elicitation/create` response in ``Client/createElicitation(_:)``.
    ///
    /// Use this when a later client action must follow the answer on the
    /// wire. For example, the user selects a permission option, and the host
    /// then sends a new `session/prompt`. If the handler resumes the caller
    /// before it returns, the new request can reach the wire before the
    /// permission response. Work deferred with this method runs on the
    /// dispatch task of the request, only after the connection wrote the
    /// response. Thus a request that the work starts (or that a caller sends
    /// after the work resumed it) always follows the response.
    ///
    /// Call this synchronously in the handler, before it returns. The
    /// connection calls each `Client` request handler on the task that
    /// dispatches the request, or (for ``Client/requestPermission(_:)``) on
    /// a task that inherits the request of that task, so the handler finds
    /// its request. A call outside an inbound request does nothing: there is
    /// no response to follow, so the connection drops `work`.
    ///
    /// A task that the handler starts inherits the current request. A call
    /// from that task after the deferred work of the request started to run
    /// does not run `work`: the connection drops `work` and logs a warning.
    /// When the connection closed before it wrote the response, the deferred
    /// work does not run, and the connection releases it. After the deferred
    /// work runs or is released, the connection keeps no reference to it.
    ///
    /// To learn when `work` will never run, use
    /// ``afterRespondingToCurrentRequest(_:onDiscard:)``.
    ///
    /// - Parameter work: The deferred work, run once the current request's
    ///   response has been handed to the transport.
    public func afterRespondingToCurrentRequest(_ work: @escaping @Sendable () async -> Void) {
        Connection.deferAfterCurrentResponse(work, onDiscard: nil)
    }

    /// Defers `work` until after this connection has written the response to
    /// the inbound request that the calling task handles, and calls
    /// `onDiscard` when `work` will never run.
    ///
    /// The rules for `work` are the same as for
    /// ``afterRespondingToCurrentRequest(_:)``. The connection calls
    /// `onDiscard` exactly one time when `work` will never run, and never when
    /// `work` runs. Thus a caller that waits for `work` (for example, with a
    /// continuation) can resume from `onDiscard`, and never stays suspended.
    /// `onDiscard` is synchronous. The cases:
    ///
    /// 1. The connection closed before it wrote the response. The connection
    ///    releases `work`, then calls `onDiscard`.
    /// 2. The call comes after the deferred work of the request ran or was
    ///    released. The connection logs a warning, drops `work`, and calls
    ///    `onDiscard`.
    /// 3. The call comes outside an inbound request. `work` does not run, and
    ///    `onDiscard` runs at once, before this method returns.
    ///
    /// After `work` runs or is released, the connection keeps no reference to
    /// `work` or to `onDiscard`.
    ///
    /// - Parameters:
    ///   - work: The deferred work, run once the current request's response
    ///     has been handed to the transport.
    ///   - onDiscard: Called exactly one time when `work` will never run.
    public func afterRespondingToCurrentRequest(
        _ work: @escaping @Sendable () async -> Void,
        onDiscard: @escaping @Sendable () -> Void
    ) {
        Connection.deferAfterCurrentResponse(work, onDiscard: onDiscard)
    }
}
