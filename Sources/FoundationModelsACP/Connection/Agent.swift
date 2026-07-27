/// The agent role a client drives (spec §4).
///
/// `initialize` and the session baseline carry **no default implementation**:
/// any conforming type must implement them directly, so the promise behind
/// `capabilities.session` — that an agent advertising it serves `session/new`,
/// `session/list`, `session/resume`, `session/close`, `session/prompt`,
/// `session/cancel`, and (via its `Client` peer) `session/update` — cannot be
/// silently half-kept. That is the session baseline; the rest of this
/// protocol is capability-gated and defaults to method-not-found below, so a
/// conformer implements only what it actually advertises.
///
/// Method names are exactly the generated routing table's handler names
/// (`ACPMethodTable.methods`) — never a second, hand-wired mapping from wire
/// method to Swift name.
public protocol Agent: Sendable {
    /// Negotiates protocol version and capabilities with the client.
    ///
    /// Always required: the first call on every connection.
    ///
    /// - Parameter params: The client's initialization request.
    /// - Returns: The agent's initialization response.
    /// - Throws: A `RequestError` when initialization fails.
    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse

    /// Creates a new session.
    ///
    /// Session baseline: required whenever `capabilities.session` is
    /// advertised.
    ///
    /// - Parameter params: The new-session request.
    /// - Returns: The new session's identity and initial configuration.
    /// - Throws: A `RequestError` when the session cannot be created.
    func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse

    /// Lists existing sessions.
    ///
    /// Session baseline: required whenever `capabilities.session` is
    /// advertised.
    ///
    /// - Parameter params: The list-sessions request.
    /// - Returns: The listed sessions, optionally paginated.
    /// - Throws: A `RequestError` when the sessions cannot be listed.
    func listSessions(_ params: ListSessionsRequest) async throws -> ListSessionsResponse

    /// Resumes an existing session, optionally replaying its history.
    ///
    /// Session baseline: required whenever `capabilities.session` is
    /// advertised.
    ///
    /// - Parameter params: The resume-session request.
    /// - Returns: The resumed session's configuration.
    /// - Throws: A `RequestError` when the session cannot be resumed.
    func resumeSession(_ params: ResumeSessionRequest) async throws -> ResumeSessionResponse

    /// Closes a session.
    ///
    /// Session baseline: required whenever `capabilities.session` is
    /// advertised. Distinct from `session/delete` (`deleteSession`), which
    /// removes the session outright rather than merely closing it.
    ///
    /// - Parameter params: The close-session request.
    /// - Returns: The close-session response.
    /// - Throws: A `RequestError` when the session cannot be closed.
    func closeSession(_ params: CloseSessionRequest) async throws -> CloseSessionResponse

    /// Runs one prompt turn.
    ///
    /// Acknowledges immediately; the turn's progress and completion arrive
    /// separately, as `state_update` session updates sent to the `Client`
    /// peer, not as this call's return value. Session baseline: required
    /// whenever `capabilities.session` is advertised.
    ///
    /// - Parameter params: The prompt request.
    /// - Returns: The immediate acknowledgement.
    /// - Throws: A `RequestError` when the turn cannot be started.
    func prompt(_ params: PromptRequest) async throws -> PromptResponse

    /// Handles a client's request to cancel the current turn.
    ///
    /// Cancellation is confirmed by an `idle` `state_update` carrying
    /// `stopReason: "cancelled"`, not by this notification returning. Session
    /// baseline: required whenever `capabilities.session` is advertised.
    ///
    /// - Parameter params: The cancellation notification.
    func sessionCancel(_ params: CancelSessionNotification) async

    /// Authenticates with the agent.
    ///
    /// Required only when this agent's `initialize` response advertises at
    /// least one `authMethods` entry; clients must not call it otherwise.
    ///
    /// - Parameter params: The login request, naming the method to use.
    /// - Returns: The login response.
    /// - Throws: `RequestError.methodNotFound` unless overridden.
    func loginAuth(_ params: LoginAuthRequest) async throws -> LoginAuthResponse

    /// Logs out of the agent.
    ///
    /// Required only when this agent's `initialize` response advertises at
    /// least one `authMethods` entry; clients must not call it otherwise.
    ///
    /// - Parameter params: The logout request.
    /// - Returns: The logout response.
    /// - Throws: `RequestError.methodNotFound` unless overridden.
    func logoutAuth(_ params: LogoutAuthRequest) async throws -> LogoutAuthResponse

    /// Deletes a session outright.
    ///
    /// Gated by `capabilities.session.delete`; distinct from `session/close`
    /// (`closeSession`), which merely closes the session rather than removing
    /// it.
    ///
    /// - Parameter params: The delete-session request.
    /// - Returns: The delete-session response.
    /// - Throws: `RequestError.methodNotFound` unless overridden.
    func deleteSession(_ params: DeleteSessionRequest) async throws -> DeleteSessionResponse

    /// Sets a session configuration option.
    ///
    /// The vendored schema declares no dedicated capability flag for this
    /// method — an agent that reports any `configOptions` from `session/new`
    /// or `session/resume` is expected to serve it; one that reports none
    /// need not override this default.
    ///
    /// - Parameter params: The set-config-option request.
    /// - Returns: The full, updated set of configuration options.
    /// - Throws: `RequestError.methodNotFound` unless overridden.
    func setSessionConfigOption(
        _ params: SetSessionConfigOptionRequest
    ) async throws -> SetSessionConfigOptionResponse
}

/// Default implementations for every capability-gated `Agent` method, so a
/// conformer implements only what it advertises. The session baseline has no
/// default here on purpose — see the protocol's documentation above.
extension Agent {
    /// Default implementation; throws method-not-found unless overridden.
    public func loginAuth(_ params: LoginAuthRequest) async throws -> LoginAuthResponse {
        try throwMethodNotFound("auth/login")
    }

    /// Default implementation; throws method-not-found unless overridden.
    public func logoutAuth(_ params: LogoutAuthRequest) async throws -> LogoutAuthResponse {
        try throwMethodNotFound("auth/logout")
    }

    /// Default implementation; throws method-not-found unless overridden.
    public func deleteSession(_ params: DeleteSessionRequest) async throws -> DeleteSessionResponse {
        try throwMethodNotFound("session/delete")
    }

    /// Default implementation; throws method-not-found unless overridden.
    public func setSessionConfigOption(
        _ params: SetSessionConfigOptionRequest
    ) async throws -> SetSessionConfigOptionResponse {
        try throwMethodNotFound("session/set_config_option")
    }

    /// Throws `RequestError.methodNotFound` naming `methodName`.
    ///
    /// Shared by every capability-gated default above, so each one differs
    /// from its siblings only by the wire method name it passes here.
    ///
    /// - Parameter methodName: The wire method name to report as unfound.
    /// - Throws: `RequestError.methodNotFound(methodName)`, always.
    private func throwMethodNotFound<T>(_ methodName: String) throws -> T {
        throw RequestError.methodNotFound(methodName)
    }
}
