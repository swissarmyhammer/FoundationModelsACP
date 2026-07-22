import Foundation
import Synchronization
import Testing

import FoundationModelsACP

// MARK: - Recorder

/// Records each role handler's re-encoded parameters and signals delivery.
///
/// Requests are confirmed by their response, but notifications are
/// fire-and-forget, so tests await `waitForCall(_:)` to observe delivery
/// deterministically instead of sleeping.
final class RoleRecorder: Sendable {
    /// The re-encoded parameters seen for each handler, keyed by handler name.
    private let calls = Mutex<[String: JSONValue]>([:])

    /// A stream of handler names, one per invocation, for delivery waits.
    private let events: AsyncStream<String>

    /// Feeds `events` as handlers are invoked.
    private let emit: AsyncStream<String>.Continuation

    /// Creates an empty recorder.
    init() {
        (events, emit) = AsyncStream<String>.makeStream()
    }

    /// Records one handler invocation, re-encoding its parameters to a value.
    ///
    /// - Parameters:
    ///   - handler: The handler name that was invoked.
    ///   - value: The parameters the handler received.
    func record<Value: Encodable>(_ handler: String, _ value: Value) {
        let encoded = (try? encodedValue(value)) ?? .null
        calls.withLock { $0[handler] = encoded }
        emit.yield(handler)
    }

    /// The re-encoded parameters recorded for a handler, if it was invoked.
    ///
    /// - Parameter handler: The handler name to look up.
    /// - Returns: The recorded parameters, or `nil` when not yet invoked.
    func recorded(_ handler: String) -> JSONValue? {
        calls.withLock { $0[handler] }
    }

    /// Waits until the named handler has been invoked at least once.
    ///
    /// - Parameter handler: The handler name to wait for.
    func waitForCall(_ handler: String) async {
        for await event in events where event == handler {
            return
        }
    }
}

// MARK: - Spy roles

/// An agent that records every call and returns canned responses.
final class SpyAgent: Agent {
    /// The shared recorder capturing each handler's parameters.
    let recorder: RoleRecorder

    /// Creates a spy backed by the given recorder.
    ///
    /// - Parameter recorder: The recorder to report calls to.
    init(recorder: RoleRecorder) {
        self.recorder = recorder
    }

    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        recorder.record("initialize", params)
        return InitializeResponse(protocolVersion: .v1)
    }

    func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        recorder.record("newSession", params)
        return NewSessionResponse(sessionId: SessionId(rawValue: "session-1"))
    }

    func loadSession(_ params: LoadSessionRequest) async throws -> LoadSessionResponse {
        recorder.record("loadSession", params)
        return LoadSessionResponse()
    }

    func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        recorder.record("prompt", params)
        return PromptResponse(stopReason: .endTurn)
    }

    func cancel(_ params: CancelNotification) async {
        recorder.record("cancel", params)
    }

    func authenticate(_ params: AuthenticateRequest) async throws -> AuthenticateResponse {
        recorder.record("authenticate", params)
        return AuthenticateResponse()
    }

    func setSessionConfigOption(
        _ params: SetSessionConfigOptionRequest
    ) async throws -> SetSessionConfigOptionResponse {
        recorder.record("setSessionConfigOption", params)
        return SetSessionConfigOptionResponse(configOptions: [])
    }

    func setSessionMode(_ params: SetSessionModeRequest) async throws -> SetSessionModeResponse {
        recorder.record("setSessionMode", params)
        return SetSessionModeResponse()
    }

    func listSessions(_ params: ListSessionsRequest) async throws -> ListSessionsResponse {
        recorder.record("listSessions", params)
        return ListSessionsResponse(sessions: [])
    }

    func resumeSession(_ params: ResumeSessionRequest) async throws -> ResumeSessionResponse {
        recorder.record("resumeSession", params)
        return ResumeSessionResponse()
    }

    func deleteSession(_ params: DeleteSessionRequest) async throws {
        recorder.record("deleteSession", params)
    }

    func closeSession(_ params: CloseSessionRequest) async throws {
        recorder.record("closeSession", params)
    }

    func logout(_ params: LogoutRequest) async throws {
        recorder.record("logout", params)
    }
}

/// A client that records every call and returns canned responses.
final class SpyClient: Client {
    /// The shared recorder capturing each handler's parameters.
    let recorder: RoleRecorder

    /// Creates a spy backed by the given recorder.
    ///
    /// - Parameter recorder: The recorder to report calls to.
    init(recorder: RoleRecorder) {
        self.recorder = recorder
    }

    func sessionUpdate(_ notification: SessionNotification) async {
        recorder.record("sessionUpdate", notification)
    }

    func requestPermission(
        _ params: RequestPermissionRequest
    ) async throws -> RequestPermissionResponse {
        recorder.record("requestPermission", params)
        return RequestPermissionResponse(outcome: .cancelled)
    }

    func readTextFile(_ params: ReadTextFileRequest) async throws -> ReadTextFileResponse {
        recorder.record("readTextFile", params)
        return ReadTextFileResponse(content: "file-contents")
    }

    func writeTextFile(_ params: WriteTextFileRequest) async throws {
        recorder.record("writeTextFile", params)
    }

    func createTerminal(_ params: CreateTerminalRequest) async throws -> CreateTerminalResponse {
        recorder.record("createTerminal", params)
        return CreateTerminalResponse(terminalId: TerminalId(rawValue: "terminal-1"))
    }

    func terminalOutput(_ params: TerminalOutputRequest) async throws -> TerminalOutputResponse {
        recorder.record("terminalOutput", params)
        return TerminalOutputResponse(output: "terminal-output", truncated: false)
    }

    func waitForTerminalExit(
        _ params: WaitForTerminalExitRequest
    ) async throws -> WaitForTerminalExitResponse {
        recorder.record("waitForTerminalExit", params)
        return WaitForTerminalExitResponse(exitCode: 0)
    }

    func killTerminal(_ params: KillTerminalRequest) async throws {
        recorder.record("killTerminal", params)
    }

    func releaseTerminal(_ params: ReleaseTerminalRequest) async throws {
        recorder.record("releaseTerminal", params)
    }
}

/// An agent implementing only the required methods, relying on the protocol's
/// method-not-found defaults for every optional method.
final class MinimalAgent: Agent {
    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(protocolVersion: .v1)
    }

    func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: SessionId(rawValue: "session-min"))
    }

    func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        PromptResponse(stopReason: .endTurn)
    }

    func cancel(_ params: CancelNotification) async {}
}

/// A client implementing only the required methods, relying on the protocol's
/// method-not-found defaults for every gated method.
final class MinimalClient: Client {
    func sessionUpdate(_ notification: SessionNotification) async {}

    func requestPermission(
        _ params: RequestPermissionRequest
    ) async throws -> RequestPermissionResponse {
        RequestPermissionResponse(outcome: .cancelled)
    }
}

// MARK: - Fixtures

/// A canonical absolute path used across role tests.
let testCwd = AbsolutePath(rawValue: "/workspace")!

/// A canonical session id used across role tests.
let testSessionId = SessionId(rawValue: "session-1")

/// A canonical terminal id used across role tests.
let testTerminalId = TerminalId(rawValue: "terminal-1")

/// A canonical new-session request rooted at the shared test cwd.
///
/// - Parameter mcpServers: The MCP configs to carry; empty by default.
/// - Returns: A new-session request.
func newSessionRequest(mcpServers: [McpServer] = []) -> NewSessionRequest {
    NewSessionRequest(cwd: testCwd, mcpServers: mcpServers)
}

// MARK: - Capability fixtures

extension ClientCapabilities {
    /// Advertises only `fs.readTextFile`.
    static let readOnly = ClientCapabilities(fs: FileSystemCapabilities(readTextFile: true))

    /// Advertises only `fs.writeTextFile`.
    static let writeOnly = ClientCapabilities(fs: FileSystemCapabilities(writeTextFile: true))

    /// Advertises only the `terminal/*` methods.
    static let terminalOnly = ClientCapabilities(terminal: true)
}
