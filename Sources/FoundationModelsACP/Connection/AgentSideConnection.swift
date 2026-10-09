import Foundation

/// The agent side of an ACP connection (spec §4).
///
/// Delegates its transport wiring to a shared `RoleConnectionCore`: inbound
/// Client→Agent calls dispatch to the `Agent` the factory builds, and the
/// connection itself exposes the outbound Agent→Client calls
/// (`sessionUpdate`, `requestPermission`, `createElicitation`,
/// `elicitationComplete`) so the agent can drive the client mid-turn — most
/// importantly to request permission or user input without ever blocking the
/// read loop that keeps `session/cancel` and other traffic flowing.
public final class AgentSideConnection: Sendable {
    /// The prefix of each diagnostic that this type writes to the logger.
    private static let logPrefix = "AgentSideConnection: "

    /// The shared engine owning the connection and the served agent.
    private let core: RoleConnectionCore<any Agent>

    /// The diagnostic sink that the caller gave to `init`.
    private let logger: ACPLogger

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
    ///     forever (`requestPermission` and `createElicitation` rely on
    ///     this).
    ///   - factory: Builds the agent from this connection.
    public init(
        stream: any ACPTransport,
        logger: ACPLogger = .disabled,
        requestTimeout: Duration? = nil,
        _ factory: @Sendable (AgentSideConnection) -> any Agent
    ) async {
        self.logger = logger
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
    /// Before it sends the update, the method makes sure that the update
    /// obeys the schema rules that its Swift types do not state:
    ///
    /// - A stop reason is an ACP value, or a custom value that starts with
    ///   `_`. ACP keeps other values for future versions.
    /// - The `size` and `used` counts of a `usage_update` are 0 or more.
    /// - The currency of a `usage_update` cost is an ISO 4217 code of three
    ///   upper-case letters.
    ///
    /// An update that breaks a rule does not go to the client. A received
    /// update is not checked: the client decodes such values.
    ///
    /// - Parameter notification: The session-update notification.
    /// - Throws: `EncodingError.invalidValue` when the update breaks a rule
    ///   above, or `ConnectionError.closed` after disconnect.
    public func sessionUpdate(_ notification: UpdateSessionNotification) async throws {
        try notification.update.validateForSending()
        try await core.notify("sessionUpdate", notification)
    }

    /// Requests permission from the client mid-turn.
    ///
    /// A long-lived request on the stable surface: it genuinely waits on
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

    /// Requests structured user input from the client.
    ///
    /// Long-lived like `requestPermission`: it genuinely waits on a human —
    /// filling a form or finishing a flow behind a URL — and never blocks the
    /// read loop, because each inbound request the underlying connection
    /// serves runs in its own `Task`, so this call suspends only the caller.
    ///
    /// - Parameter params: The elicitation request.
    /// - Returns: The user's response — accept with content, decline, or
    ///   cancel — as raw JSON (`CreateElicitationResponse`).
    /// - Throws: `RequestError` on a peer error, or `ConnectionError` on
    ///   disconnect.
    public func createElicitation(
        _ params: CreateElicitationRequest
    ) async throws -> CreateElicitationResponse {
        try await core.call("createElicitation", params, returning: CreateElicitationResponse.self)
    }

    /// Notifies the client that a URL-based elicitation finished.
    ///
    /// - Parameter notification: The completion notification.
    /// - Throws: `ConnectionError.closed` after disconnect.
    public func elicitationComplete(_ notification: CompleteElicitationNotification) async throws {
        try await core.notify("elicitationComplete", notification)
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
    /// Use this value to release the state of the agent when the client goes
    /// away without `session/close`. For example, the client closes the
    /// standard input of a stdio agent, and the value is
    /// ``ConnectionCloseReason/endOfInput``:
    ///
    /// ```swift
    /// Task {
    ///     let reason = await connection.closed
    ///     // Log the reason. Finish the streams, stop the tools, and save
    ///     // the sessions.
    /// }
    /// ```
    ///
    /// The value comes one time for each connection, and each waiter gets
    /// the same reason. A waiter that starts after the close gets the reason
    /// at once. The first event that closes the connection sets the reason:
    /// the end of input, a failure of the input stream, or ``close()``.
    ///
    /// The value comes only after each inbound handler of the agent ended,
    /// finished or cancelled. This includes the work that a handler deferred
    /// with ``afterRespondingToCurrentRequest(_:)``. Thus the agent can
    /// release its state with no race against a handler that still runs.
    ///
    /// Do not wait for this value in an agent method: the value waits for
    /// that method to end. The wait does not stop when the waiting task is
    /// cancelled.
    public var closed: ConnectionCloseReason {
        get async { await core.closed }
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
    /// A task that the handler starts inherits the current request. A call
    /// from that task after the deferred work of the request started to run
    /// does not run `work`, and does not keep it: the connection drops `work`
    /// and logs a warning to its logger. The connection does not run `work`
    /// at once, because then `work` has no order with the deferred work that
    /// still runs. The same occurs when the connection closed before it wrote
    /// the response: the deferred work does not run, and the connection
    /// releases it. Thus, after the deferred work runs or is released, the
    /// connection keeps no reference to it or to the values it captures, also
    /// while a task that the handler started is alive.
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

    // MARK: - Inserting the user message of a prompt

    /// Inserts the prompt as a user message, echoes the message to the
    /// client, and returns the identifier of the message.
    ///
    /// The ACP prompt lifecycle has three steps for each accepted prompt:
    ///
    /// 1. The agent adds the user message to the conversation and gives it a
    ///    `messageId`.
    /// 2. The agent echoes the message as a `user_message` session update
    ///    with that identifier.
    /// 3. The `session/prompt` response names the same identifier.
    ///
    /// This method does steps 1 and 2. The handler does step 3 with the
    /// returned identifier:
    ///
    /// ```swift
    /// func prompt(_ params: PromptRequest) async throws -> PromptResponse {
    ///     let messageId = connection.insertUserMessage(params)
    ///     connection.afterRespondingToCurrentRequest { /* run the turn */ }
    ///     return PromptResponse(messageId: messageId)
    /// }
    /// ```
    ///
    /// The echo goes to the client after the response, with
    /// ``afterRespondingToCurrentRequest(_:)``. Thus, call this method
    /// synchronously in the handler of the request, before the handler
    /// returns. Outside a request handler, the method stops a debug build
    /// with an assertion, logs the error, and does not send the echo.
    ///
    /// Call it before you defer other work, because deferred work runs in the
    /// order of registration.
    ///
    /// After this call, the prompt is accepted. A `$/cancel_request` that
    /// cancels the handler after this call does not give a `-32800` error:
    /// the connection sends a success response that names the returned
    /// identifier, and then the echo. The deferred work of the request does
    /// not see that cancellation.
    ///
    /// If the handler throws an error that is not a cancellation after this
    /// call, the connection sends the error response and does not send the
    /// echo. Other work that the handler deferred still runs after the error
    /// response.
    ///
    /// If the connection closes before the echo goes out, the connection logs
    /// the failure. A call from a task that the handler started, after the
    /// deferred work of the request started to run, does not send the echo:
    /// the connection drops it and logs a warning, as
    /// ``afterRespondingToCurrentRequest(_:)`` tells.
    ///
    /// To also keep the message in a retained history, use
    /// ``insertUserMessage(_:messageId:into:)``.
    ///
    /// - Parameters:
    ///   - request: The prompt request. The echo carries its session and its
    ///     content.
    ///   - messageId: The identifier of the user message. When it is `nil`,
    ///     the method makes a new unique identifier.
    /// - Returns: The identifier of the user message. Return it in
    ///   ``PromptResponse/messageId``.
    @discardableResult
    public func insertUserMessage(_ request: PromptRequest, messageId: MessageId? = nil) -> MessageId {
        insert(request, messageId: messageId) { _ in }
    }

    /// Inserts the prompt as a user message, applies the echo to a retained
    /// history, echoes the message to the client, and returns the identifier
    /// of the message.
    ///
    /// This method does the same steps as ``insertUserMessage(_:messageId:)``.
    /// It also applies the `user_message` echo to `history` before it
    /// returns. Thus, the transcript of the history has the message with the
    /// same identifier, and a later `session/resume` replay keeps that
    /// identifier.
    ///
    /// The method is synchronous, so an agent can give it the history in a
    /// lock or in actor-isolated state:
    ///
    /// ```swift
    /// let messageId = history.withLock { connection.insertUserMessage(params, into: &$0) }
    /// ```
    ///
    /// - Parameters:
    ///   - request: The prompt request. The echo carries its session and its
    ///     content.
    ///   - messageId: The identifier of the user message. When it is `nil`,
    ///     the method makes a new unique identifier.
    ///   - history: The retained history of the session. The method applies
    ///     the echo to it.
    /// - Returns: The identifier of the user message. Return it in
    ///   ``PromptResponse/messageId``.
    @discardableResult
    public func insertUserMessage(
        _ request: PromptRequest,
        messageId: MessageId? = nil,
        into history: inout SessionMergeEngine
    ) -> MessageId {
        insert(request, messageId: messageId) { history.apply($0) }
    }

    /// Makes the `user_message` echo of a prompt, gives it to `record`,
    /// accepts the current request, and sends the echo after the response to
    /// the current request.
    ///
    /// - Parameters:
    ///   - request: The prompt request.
    ///   - messageId: The identifier of the user message, or `nil` for a new
    ///     unique identifier.
    ///   - record: Gets the echo update before the method returns.
    /// - Returns: The identifier of the user message.
    private func insert(
        _ request: PromptRequest,
        messageId: MessageId?,
        recording record: (SessionUpdate) -> Void
    ) -> MessageId {
        let insertedId = messageId ?? MessageId(rawValue: UUID().uuidString)
        let echo = UpdateSessionNotification(
            sessionId: request.sessionId,
            update: .userMessage(UserMessage(messageId: insertedId, content: .value(request.prompt)))
        )
        record(echo.update)
        acceptPrompt(naming: insertedId, echoing: echo)
        return insertedId
    }

    /// Accepts the current request with a response that names the inserted
    /// message, and sends a `user_message` echo after that response.
    ///
    /// After this call, a cancellation of the handler does not give a
    /// `-32800` error: the connection sends the accepted response. After an
    /// error response, the connection does not send the echo.
    ///
    /// With no current request, the echo cannot follow a response. This is
    /// an error of the caller: the method stops a debug build, logs the
    /// error, and does not send the echo.
    ///
    /// - Parameters:
    ///   - messageId: The identifier of the inserted user message.
    ///   - echo: The echo notification.
    private func acceptPrompt(naming messageId: MessageId, echoing echo: UpdateSessionNotification) {
        guard let hooks = Connection.currentResponseHooks else {
            assertionFailure("insertUserMessage must run in the handler of a request")
            logger.log(
                Self.logPrefix + "insertUserMessage ran outside a request handler; "
                    + "the user_message echo for session \(echo.sessionId.rawValue) was not sent"
            )
            return
        }
        accept(PromptResponse(messageId: messageId), in: hooks)
        hooks.appendSuccessOnly { [self] in
            do {
                try await sessionUpdate(echo)
            } catch {
                logger.log(Self.logPrefix + "the user_message echo was not sent: \(error)")
            }
        }
    }

    /// Records `response` as the accepted result of the current request.
    ///
    /// A `PromptResponse` always encodes. If it does not, the method stops a
    /// debug build and logs the error. Then a cancellation of the handler
    /// gives the `-32800` error, as before this method.
    ///
    /// - Parameters:
    ///   - response: The response that names the inserted user message.
    ///   - hooks: The collector of the current request.
    private func accept(_ response: PromptResponse, in hooks: ResponseHooks) {
        do {
            hooks.accept(try JSONValue.encode(result: response))
        } catch {
            assertionFailure("a PromptResponse did not encode: \(error)")
            logger.log(
                Self.logPrefix + "the prompt response did not encode, "
                    + "so a cancellation of the handler gives -32800: \(error)"
            )
        }
    }
}
