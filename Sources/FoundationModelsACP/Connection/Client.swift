import Foundation

/// The client role that drives an agent (spec §4).
///
/// A conformer implements only the reverse-direction methods its advertised
/// capabilities cover: every capability-gated method has a default
/// implementation that answers method-not-found, so a minimal client
/// implements just `sessionUpdate` and `requestPermission`.
public protocol Client: Sendable {
    /// Receives a streamed session update from the agent.
    ///
    /// - Parameter notification: The session-update notification.
    func sessionUpdate(_ notification: SessionNotification) async

    /// Answers the agent's request for permission mid-turn.
    ///
    /// - Parameter params: The permission request.
    /// - Returns: The user's permission decision.
    /// - Throws: A `RequestError` when the request cannot be answered.
    func requestPermission(
        _ params: RequestPermissionRequest
    ) async throws -> RequestPermissionResponse

    /// Reads a text file; gated by the `fs.readTextFile` capability.
    ///
    /// - Parameter params: The read request.
    /// - Returns: The file contents.
    /// - Throws: `RequestError.methodNotFound` unless overridden.
    func readTextFile(_ params: ReadTextFileRequest) async throws -> ReadTextFileResponse

    /// Writes a text file; gated by the `fs.writeTextFile` capability.
    ///
    /// - Parameter params: The write request.
    /// - Throws: `RequestError.methodNotFound` unless overridden.
    func writeTextFile(_ params: WriteTextFileRequest) async throws

    /// Creates a terminal; gated by the `terminal` capability.
    ///
    /// - Parameter params: The create-terminal request.
    /// - Returns: The created terminal's identity.
    /// - Throws: `RequestError.methodNotFound` unless overridden.
    func createTerminal(_ params: CreateTerminalRequest) async throws -> CreateTerminalResponse

    /// Returns a snapshot of a terminal's output; gated by `terminal`.
    ///
    /// - Parameter params: The output request.
    /// - Returns: The bounded output snapshot.
    /// - Throws: `RequestError.methodNotFound` unless overridden.
    func terminalOutput(_ params: TerminalOutputRequest) async throws -> TerminalOutputResponse

    /// Waits for a terminal's process to exit; gated by `terminal`.
    ///
    /// - Parameter params: The wait request.
    /// - Returns: The process's exit status.
    /// - Throws: `RequestError.methodNotFound` unless overridden.
    func waitForTerminalExit(
        _ params: WaitForTerminalExitRequest
    ) async throws -> WaitForTerminalExitResponse

    /// Kills a terminal's process; gated by `terminal`.
    ///
    /// - Parameter params: The kill request.
    /// - Throws: `RequestError.methodNotFound` unless overridden.
    func killTerminal(_ params: KillTerminalRequest) async throws

    /// Releases a terminal's resources; gated by `terminal`.
    ///
    /// - Parameter params: The release request.
    /// - Throws: `RequestError.methodNotFound` unless overridden.
    func releaseTerminal(_ params: ReleaseTerminalRequest) async throws
}

/// Default implementations that answer method-not-found for every gated
/// method, so a conformer implements only what its capabilities advertise.
extension Client {
    public func readTextFile(_ params: ReadTextFileRequest) async throws -> ReadTextFileResponse {
        throw RequestError.methodNotFound(RoleRouting.wire(handler: "readTextFile", on: .client))
    }

    public func writeTextFile(_ params: WriteTextFileRequest) async throws {
        throw RequestError.methodNotFound(RoleRouting.wire(handler: "writeTextFile", on: .client))
    }

    public func createTerminal(_ params: CreateTerminalRequest) async throws -> CreateTerminalResponse {
        throw RequestError.methodNotFound(RoleRouting.wire(handler: "createTerminal", on: .client))
    }

    public func terminalOutput(_ params: TerminalOutputRequest) async throws -> TerminalOutputResponse {
        throw RequestError.methodNotFound(RoleRouting.wire(handler: "terminalOutput", on: .client))
    }

    public func waitForTerminalExit(
        _ params: WaitForTerminalExitRequest
    ) async throws -> WaitForTerminalExitResponse {
        throw RequestError.methodNotFound(RoleRouting.wire(handler: "waitForTerminalExit", on: .client))
    }

    public func killTerminal(_ params: KillTerminalRequest) async throws {
        throw RequestError.methodNotFound(RoleRouting.wire(handler: "killTerminal", on: .client))
    }

    public func releaseTerminal(_ params: ReleaseTerminalRequest) async throws {
        throw RequestError.methodNotFound(RoleRouting.wire(handler: "releaseTerminal", on: .client))
    }
}
