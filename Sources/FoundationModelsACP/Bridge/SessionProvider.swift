import Foundation
import FoundationModels

/// An MCP server configuration as delivered on a `session/new` request.
///
/// Aliased to the generated ``McpServer`` — the element type
/// ``NewSessionRequest/mcpServers`` actually carries — so a provider's
/// ``SessionProvider/makeSession`` receives exactly what crossed the wire, with
/// no lossy re-shaping.
public typealias MCPServerConfig = McpServer

/// A summary of a stored session, as reported by `session/list`.
///
/// Aliased to the generated ``SessionInfo`` (the element type of
/// ``ListSessionsResponse/sessions``) so a provider's
/// ``SessionProvider/listSessions`` hook returns values the session-management
/// forwarding can surface directly.
public typealias SessionSummary = SessionInfo

/// Where a ``FoundationModelsAgent``'s sessions come from (spec §7.1).
///
/// There is deliberately no engine protocol: the bridge always drives a real
/// ``LanguageModelSession``, and only the *origin* of sessions varies. A
/// provider supplies the required ``makeSession`` factory and, optionally,
/// store hooks whose presence gates the agent's session-management
/// capabilities.
public struct SessionProvider: Sendable {
    /// Builds and names the session for a `session/new` request.
    ///
    /// The working directory arrives in `session/new`; the provider builds the
    /// session for it (config, tools, instructions) and returns the identity to
    /// track it under.
    ///
    /// - Parameters:
    ///   - cwd: The session's working directory; always absolute.
    ///   - mcpServers: The MCP servers the session should connect to.
    /// - Returns: The new session's identity and its live ``LanguageModelSession``.
    /// - Throws: Any error that prevents building the session.
    public var makeSession:
        @Sendable (_ cwd: AbsolutePath, _ mcpServers: [MCPServerConfig]) async throws
        -> (SessionId, LanguageModelSession)

    /// Lists stored sessions; presence gates the `session/list` capability.
    public var listSessions: (@Sendable () async throws -> [SessionSummary])?

    /// Restores a stored session; presence gates the `session/resume` capability.
    ///
    /// Typically reconstructs the session from a stored transcript via
    /// `LanguageModelSession(model:transcript:)`.
    public var restoreSession: (@Sendable (SessionId) async throws -> LanguageModelSession)?

    /// Deletes a stored session; presence gates the `session/delete` capability.
    public var deleteSession: (@Sendable (SessionId) async throws -> Void)?

    /// Invoked when a prompt turn completes, with the session's final transcript.
    ///
    /// Providers use it for turn-boundary work the bridge can see but they
    /// cannot. Absence changes nothing.
    public var onTurnEnded: (@Sendable (SessionId, Transcript) async -> Void)?

    /// Creates a provider from its factory and optional store hooks.
    ///
    /// - Parameters:
    ///   - makeSession: The required session factory.
    ///   - listSessions: Optional list hook; presence advertises `session/list`.
    ///   - restoreSession: Optional restore hook; presence advertises `session/resume`.
    ///   - deleteSession: Optional delete hook; presence advertises `session/delete`.
    ///   - onTurnEnded: Optional turn-boundary hook.
    public init(
        makeSession: @escaping @Sendable (
            _ cwd: AbsolutePath, _ mcpServers: [MCPServerConfig]
        ) async throws -> (SessionId, LanguageModelSession),
        listSessions: (@Sendable () async throws -> [SessionSummary])? = nil,
        restoreSession: (@Sendable (SessionId) async throws -> LanguageModelSession)? = nil,
        deleteSession: (@Sendable (SessionId) async throws -> Void)? = nil,
        onTurnEnded: (@Sendable (SessionId, Transcript) async -> Void)? = nil
    ) {
        self.makeSession = makeSession
        self.listSessions = listSessions
        self.restoreSession = restoreSession
        self.deleteSession = deleteSession
        self.onTurnEnded = onTurnEnded
    }
}

extension SessionProvider {
    /// Creates a single-session provider: every `session/new` yields the same
    /// pre-built session under a freshly minted identity, and no store hooks are
    /// advertised.
    ///
    /// Backs the flagship one-liner
    /// ``FoundationModelsAgent/init(connection:session:)``.
    ///
    /// - Parameter session: The pre-built session to hand out.
    public init(session: LanguageModelSession) {
        let identity = SessionId(rawValue: UUID().uuidString)
        self.init(makeSession: { _, _ in (identity, session) })
    }
}
