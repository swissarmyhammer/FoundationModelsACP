import Foundation

/// The agent role an editor or host drives (spec §4).
///
/// A conformer implements only the methods its advertised capabilities cover:
/// every optional method has a default implementation that answers
/// method-not-found, so a minimal agent implements just `initialize`,
/// `newSession`, `prompt`, and `cancel`.
public protocol Agent: Sendable {
    /// Negotiates protocol version and capabilities with the client.
    ///
    /// - Parameter params: The client's initialization request.
    /// - Returns: The agent's initialization response.
    /// - Throws: A `RequestError` when initialization fails.
    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse

    /// Creates a new session.
    ///
    /// - Parameter params: The new-session request.
    /// - Returns: The new session's identity and configuration.
    /// - Throws: A `RequestError` when the session cannot be created.
    func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse

    /// Loads an existing session; gated by the `loadSession` capability.
    ///
    /// - Parameter params: The load-session request.
    /// - Returns: The loaded session's configuration.
    /// - Throws: `RequestError.methodNotFound` unless overridden.
    func loadSession(_ params: LoadSessionRequest) async throws -> LoadSessionResponse

    /// Runs one prompt turn, returning only when the turn stops.
    ///
    /// - Parameter params: The prompt request.
    /// - Returns: The turn's outcome, carrying its `StopReason`.
    /// - Throws: A `RequestError` when the turn fails.
    func prompt(_ params: PromptRequest) async throws -> PromptResponse

    /// Handles a client's request to cancel the current turn.
    ///
    /// - Parameter params: The cancellation notification.
    func cancel(_ params: CancelNotification) async

    /// Authenticates with the agent; gated by advertised auth methods.
    ///
    /// - Parameter params: The authentication request.
    /// - Returns: The authentication response.
    /// - Throws: `RequestError.methodNotFound` unless overridden.
    func authenticate(_ params: AuthenticateRequest) async throws -> AuthenticateResponse

    /// Sets a session configuration option; supersedes `setSessionMode`.
    ///
    /// - Parameter params: The set-config-option request.
    /// - Returns: The updated configuration options.
    /// - Throws: `RequestError.methodNotFound` unless overridden.
    func setSessionConfigOption(
        _ params: SetSessionConfigOptionRequest
    ) async throws -> SetSessionConfigOptionResponse

    /// Sets the session mode.
    ///
    /// - Parameter params: The set-mode request.
    /// - Returns: The set-mode response.
    /// - Throws: `RequestError.methodNotFound` unless overridden.
    @available(*, deprecated, message: "Use setSessionConfigOption; session/set_mode is being removed")
    func setSessionMode(_ params: SetSessionModeRequest) async throws -> SetSessionModeResponse

    /// Lists sessions; gated by the session-list capability.
    ///
    /// - Parameter params: The list-sessions request.
    /// - Returns: The listed sessions.
    /// - Throws: `RequestError.methodNotFound` unless overridden.
    func listSessions(_ params: ListSessionsRequest) async throws -> ListSessionsResponse

    /// Resumes a session; gated by the session-resume capability.
    ///
    /// - Parameter params: The resume-session request.
    /// - Returns: The resumed session's configuration.
    /// - Throws: `RequestError.methodNotFound` unless overridden.
    func resumeSession(_ params: ResumeSessionRequest) async throws -> ResumeSessionResponse

    /// Deletes a session; gated by the session-delete capability.
    ///
    /// - Parameter params: The delete-session request.
    /// - Throws: `RequestError.methodNotFound` unless overridden.
    func deleteSession(_ params: DeleteSessionRequest) async throws

    /// Closes a session; gated by the session-close capability.
    ///
    /// - Parameter params: The close-session request.
    /// - Throws: `RequestError.methodNotFound` unless overridden.
    func closeSession(_ params: CloseSessionRequest) async throws

    /// Logs out of the agent.
    ///
    /// - Parameter params: The logout request.
    /// - Throws: `RequestError.methodNotFound` unless overridden.
    func logout(_ params: LogoutRequest) async throws
}

/// Default implementations that answer method-not-found for every optional
/// method, so a conformer implements only what its capabilities advertise.
extension Agent {
    /// Default implementation; throws method-not-found unless overridden.
    public func loadSession(_ params: LoadSessionRequest) async throws -> LoadSessionResponse {
        throw RoleRouting.methodNotFound(handler: "loadSession", on: .agent)
    }

    /// Default implementation; throws method-not-found unless overridden.
    public func authenticate(_ params: AuthenticateRequest) async throws -> AuthenticateResponse {
        throw RoleRouting.methodNotFound(handler: "authenticate", on: .agent)
    }

    /// Default implementation; throws method-not-found unless overridden.
    public func setSessionConfigOption(
        _ params: SetSessionConfigOptionRequest
    ) async throws -> SetSessionConfigOptionResponse {
        throw RoleRouting.methodNotFound(handler: "setSessionConfigOption", on: .agent)
    }

    /// Default implementation; throws method-not-found unless overridden.
    @available(*, deprecated, message: "Use setSessionConfigOption; session/set_mode is being removed")
    public func setSessionMode(_ params: SetSessionModeRequest) async throws -> SetSessionModeResponse {
        throw RoleRouting.methodNotFound(handler: "setSessionMode", on: .agent)
    }

    /// Default implementation; throws method-not-found unless overridden.
    public func listSessions(_ params: ListSessionsRequest) async throws -> ListSessionsResponse {
        throw RoleRouting.methodNotFound(handler: "listSessions", on: .agent)
    }

    /// Default implementation; throws method-not-found unless overridden.
    public func resumeSession(_ params: ResumeSessionRequest) async throws -> ResumeSessionResponse {
        throw RoleRouting.methodNotFound(handler: "resumeSession", on: .agent)
    }

    /// Default implementation; throws method-not-found unless overridden.
    public func deleteSession(_ params: DeleteSessionRequest) async throws {
        throw RoleRouting.methodNotFound(handler: "deleteSession", on: .agent)
    }

    /// Default implementation; throws method-not-found unless overridden.
    public func closeSession(_ params: CloseSessionRequest) async throws {
        throw RoleRouting.methodNotFound(handler: "closeSession", on: .agent)
    }

    /// Default implementation; throws method-not-found unless overridden.
    public func logout(_ params: LogoutRequest) async throws {
        throw RoleRouting.methodNotFound(handler: "logout", on: .agent)
    }
}
