import Foundation
import FoundationModels

/// The client's environment, handed to a FoundationModels `Tool` so its work
/// reaches the *client's* filesystem, terminals, and consent (spec §7).
///
/// A FoundationModels tool runs in-process, but when its work needs the client's
/// world — read or write a file, run a command, ask permission — it must not
/// touch the host the agent runs on. Instead it uses this handle, which turns
/// each operation into the matching reverse-direction ACP request (`fs/*`,
/// `terminal/*`, `session/request_permission`) over the agent's connection, so
/// an Apple-native tool transparently drives the editor's environment.
///
/// The bridge injects one handle per session and turn: ``current`` is bound for
/// the duration of a prompt turn, so a tool reads `ClientEnvironment.current`
/// without threading the handle through its own construction (FoundationModels
/// builds tools, so the bridge cannot inject through their initializers).
///
/// Every operation gated by a client capability checks the negotiated
/// ``ClientCapabilities`` first and throws ``ClientEnvironmentError`` locally
/// when the capability was not advertised, so an un-advertised call never
/// reaches the wire.
public struct ClientEnvironment: Sendable {
    /// The environment bound for the FoundationModels tool call running on the
    /// current task, or `nil` outside a bridged turn.
    @TaskLocal public static var current: ClientEnvironment?

    /// A capability a ``ClientEnvironment`` operation depends on.
    public enum Capability: Hashable, Sendable {
        /// Reading text files (`fs/read_text_file`).
        case readTextFile

        /// Writing text files (`fs/write_text_file`).
        case writeTextFile

        /// The `terminal/*` methods.
        case terminal
    }

    /// Why a permission request did not grant.
    public enum PermissionDenial: Hashable, Sendable {
        /// The user chose a rejecting option, identified by its id.
        case rejected(PermissionOptionId)

        /// The turn was cancelled before the user answered.
        case cancelled
    }

    /// The result of running a command in a client terminal.
    public struct CommandResult: Hashable, Sendable {
        /// The terminal the command ran in, embedded in the tool call.
        public var terminalId: TerminalId

        /// The command's captured output, bounded by the requested byte limit.
        public var output: String

        /// Whether the output was truncated to stay within the byte limit.
        public var truncated: Bool

        /// How the command's process terminated.
        public var exitStatus: TerminalExitStatus

        /// Creates a command result.
        ///
        /// - Parameters:
        ///   - terminalId: The terminal the command ran in.
        ///   - output: The command's captured output.
        ///   - truncated: Whether the output was truncated.
        ///   - exitStatus: How the process terminated.
        public init(
            terminalId: TerminalId,
            output: String,
            truncated: Bool,
            exitStatus: TerminalExitStatus
        ) {
            self.terminalId = terminalId
            self.output = output
            self.truncated = truncated
            self.exitStatus = exitStatus
        }
    }

    /// The connection carrying reverse Agent→Client requests.
    private let connection: AgentSideConnection

    /// The session every request is scoped to.
    private let sessionId: SessionId

    /// The capabilities the client advertised during initialization.
    private let capabilities: ClientCapabilities

    /// Creates a handle onto one session's client environment.
    ///
    /// - Parameters:
    ///   - connection: The connection carrying reverse Agent→Client requests.
    ///   - sessionId: The session every request is scoped to.
    ///   - capabilities: The capabilities the client advertised, used to gate
    ///     each operation before it reaches the wire.
    public init(
        connection: AgentSideConnection,
        sessionId: SessionId,
        capabilities: ClientCapabilities
    ) {
        self.connection = connection
        self.sessionId = sessionId
        self.capabilities = capabilities
    }

    // MARK: - Filesystem

    /// Reads a text file through the client's filesystem.
    ///
    /// - Parameters:
    ///   - path: The absolute path to read.
    ///   - line: The 1-based line to start at, or `nil` to start at the top.
    ///   - limit: The maximum number of lines to read, or `nil` for all.
    /// - Returns: The file's contents.
    /// - Throws: ``ClientEnvironmentError/capabilityUnavailable(_:)`` when the
    ///   client did not advertise `fs.readTextFile`, or a `RequestError` the
    ///   client raised.
    public func readTextFile(
        path: AbsolutePath,
        line: LineNumber? = nil,
        limit: Int? = nil
    ) async throws -> String {
        try require(.readTextFile)
        let request = ReadTextFileRequest(path: path, sessionId: sessionId, limit: limit, line: line)
        return try await connection.readTextFile(request).content
    }

    /// Writes a text file through the client's filesystem.
    ///
    /// - Parameters:
    ///   - path: The absolute path to write.
    ///   - content: The text to write.
    /// - Throws: ``ClientEnvironmentError/capabilityUnavailable(_:)`` when the
    ///   client did not advertise `fs.writeTextFile`, or a `RequestError` the
    ///   client raised.
    public func writeTextFile(path: AbsolutePath, content: String) async throws {
        try require(.writeTextFile)
        try await connection.writeTextFile(
            WriteTextFileRequest(content: content, path: path, sessionId: sessionId)
        )
    }

    // MARK: - Permission

    /// Asks the client to grant permission for a tool call.
    ///
    /// The outcome is mapped to consent: a selected allowing option returns that
    /// option, while a rejecting option or a cancelled turn throws
    /// ``ClientEnvironmentError/permissionDenied(_:)`` so the tool can convert
    /// the denial into a failed `tool_call_update`.
    ///
    /// - Parameters:
    ///   - toolCall: The tool call the permission is for.
    ///   - options: The options offered to the user.
    /// - Returns: The allowing option the user selected.
    /// - Throws: ``ClientEnvironmentError/permissionDenied(_:)`` on a rejecting
    ///   or cancelled outcome, or a `RequestError` the client raised.
    @discardableResult
    public func requestPermission(
        toolCall: ToolCallUpdate,
        options: [PermissionOption]
    ) async throws -> PermissionOption {
        let request = RequestPermissionRequest(options: options, sessionId: sessionId, toolCall: toolCall)
        let response = try await connection.requestPermission(request)
        return try Self.grantedOption(from: response.outcome, options: options)
    }

    /// Resolves a permission outcome to the allowing option it selected.
    ///
    /// - Parameters:
    ///   - outcome: The outcome the client returned.
    ///   - options: The options the request offered, matched by id.
    /// - Returns: The allowing option the user selected.
    /// - Throws: ``ClientEnvironmentError/permissionDenied(_:)`` when the
    ///   outcome rejects, cancels, or selects an unknown or rejecting option.
    private static func grantedOption(
        from outcome: RequestPermissionOutcome,
        options: [PermissionOption]
    ) throws -> PermissionOption {
        guard case .selected(let selection) = outcome else {
            throw ClientEnvironmentError.permissionDenied(.cancelled)
        }
        guard let option = options.first(where: { $0.optionId == selection.optionId }) else {
            throw ClientEnvironmentError.permissionDenied(.rejected(selection.optionId))
        }
        switch option.kind {
        case .allowOnce, .allowAlways:
            return option
        default:
            throw ClientEnvironmentError.permissionDenied(.rejected(option.optionId))
        }
    }

    // MARK: - Terminals

    /// Creates a terminal on the client and starts a command in it.
    ///
    /// - Parameters:
    ///   - command: The command to run.
    ///   - arguments: The command's arguments.
    ///   - workingDirectory: The command's working directory, or `nil` for the
    ///     session's default.
    ///   - environment: Environment variables to set for the command.
    ///   - outputByteLimit: The maximum output bytes the client retains, or
    ///     `nil` for the client's default.
    /// - Returns: The created terminal's id.
    /// - Throws: ``ClientEnvironmentError/capabilityUnavailable(_:)`` when the
    ///   client did not advertise `terminal`, or a `RequestError` the client
    ///   raised.
    public func createTerminal(
        command: String,
        arguments: [String] = [],
        workingDirectory: AbsolutePath? = nil,
        environment: [EnvVariable] = [],
        outputByteLimit: Int? = nil
    ) async throws -> TerminalId {
        try require(.terminal)
        let request = CreateTerminalRequest(
            command: command,
            sessionId: sessionId,
            args: arguments.isEmpty ? nil : arguments,
            cwd: workingDirectory,
            env: environment.isEmpty ? nil : environment,
            outputByteLimit: outputByteLimit
        )
        return try await connection.createTerminal(request).terminalId
    }

    /// Reads a bounded snapshot of a terminal's output from the client.
    ///
    /// - Parameter terminalId: The terminal to read.
    /// - Returns: The output snapshot, bounded by the terminal's byte limit and
    ///   flagged `truncated` when it was clipped.
    /// - Throws: ``ClientEnvironmentError/capabilityUnavailable(_:)`` when the
    ///   client did not advertise `terminal`, or a `RequestError` the client
    ///   raised.
    public func terminalOutput(_ terminalId: TerminalId) async throws -> TerminalOutputResponse {
        try require(.terminal)
        return try await connection.terminalOutput(
            TerminalOutputRequest(sessionId: sessionId, terminalId: terminalId)
        )
    }

    /// Waits for a terminal's command to exit on the client.
    ///
    /// - Parameter terminalId: The terminal to wait for.
    /// - Returns: The process's exit status.
    /// - Throws: ``ClientEnvironmentError/capabilityUnavailable(_:)`` when the
    ///   client did not advertise `terminal`, or a `RequestError` the client
    ///   raised.
    public func waitForTerminalExit(_ terminalId: TerminalId) async throws -> WaitForTerminalExitResponse {
        try require(.terminal)
        return try await connection.waitForTerminalExit(
            WaitForTerminalExitRequest(sessionId: sessionId, terminalId: terminalId)
        )
    }

    /// Kills a terminal's command on the client without releasing the terminal.
    ///
    /// - Parameter terminalId: The terminal to kill.
    /// - Throws: ``ClientEnvironmentError/capabilityUnavailable(_:)`` when the
    ///   client did not advertise `terminal`, or a `RequestError` the client
    ///   raised.
    public func killTerminal(_ terminalId: TerminalId) async throws {
        try require(.terminal)
        try await connection.killTerminal(KillTerminalRequest(sessionId: sessionId, terminalId: terminalId))
    }

    /// Releases a terminal's resources on the client.
    ///
    /// - Parameter terminalId: The terminal to release.
    /// - Throws: ``ClientEnvironmentError/capabilityUnavailable(_:)`` when the
    ///   client did not advertise `terminal`, or a `RequestError` the client
    ///   raised.
    public func releaseTerminal(_ terminalId: TerminalId) async throws {
        try require(.terminal)
        try await connection.releaseTerminal(ReleaseTerminalRequest(sessionId: sessionId, terminalId: terminalId))
    }

    /// Runs a command end-to-end in a client terminal, embedding it in the tool
    /// call so the client renders live output (spec §9).
    ///
    /// The command's terminal is created, embedded into the tool call as a
    /// `tool_call_update` carrying ``ToolCallContent/terminal(_:)`` so the
    /// client shows its output live, awaited to completion, read for its bounded
    /// output, and finally released. If a step after creation fails the terminal
    /// is still released before the error propagates, so a failure never leaks a
    /// client terminal.
    ///
    /// - Parameters:
    ///   - toolCallId: The tool call to embed the terminal into.
    ///   - command: The command to run.
    ///   - arguments: The command's arguments.
    ///   - workingDirectory: The command's working directory, or `nil` for the
    ///     session's default.
    ///   - environment: Environment variables to set for the command.
    ///   - outputByteLimit: The maximum output bytes the client retains, or
    ///     `nil` for the client's default.
    /// - Returns: The command's terminal, output, truncation flag, and exit
    ///   status.
    /// - Throws: ``ClientEnvironmentError/capabilityUnavailable(_:)`` when the
    ///   client did not advertise `terminal`, or a `RequestError` the client
    ///   raised.
    @discardableResult
    public func runCommand(
        toolCallId: ToolCallId,
        command: String,
        arguments: [String] = [],
        workingDirectory: AbsolutePath? = nil,
        environment: [EnvVariable] = [],
        outputByteLimit: Int? = nil
    ) async throws -> CommandResult {
        let terminalId = try await createTerminal(
            command: command,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            outputByteLimit: outputByteLimit
        )
        // Embed the terminal in the tool call so the client renders its output
        // live (spec §9); a closed connection is swallowed, mirroring how the
        // bridge delivers session updates.
        let embed = ToolCallUpdate(
            toolCallId: toolCallId,
            content: [.terminal(Terminal(terminalId: terminalId))],
            status: .inProgress
        )
        try? await connection.sessionUpdate(
            SessionNotification(sessionId: sessionId, update: .toolCallUpdate(embed))
        )
        do {
            let exit = try await waitForTerminalExit(terminalId)
            let snapshot = try await terminalOutput(terminalId)
            try await releaseTerminal(terminalId)
            return CommandResult(
                terminalId: terminalId,
                output: snapshot.output,
                truncated: snapshot.truncated,
                exitStatus: TerminalExitStatus(exitCode: exit.exitCode, signal: exit.signal)
            )
        } catch {
            try? await releaseTerminal(terminalId)
            throw error
        }
    }

    // MARK: - Helpers

    /// Requires that a gated capability was advertised, failing locally before
    /// any wire call when it was not.
    ///
    /// - Parameter capability: The capability the pending operation depends on.
    /// - Throws: ``ClientEnvironmentError/capabilityUnavailable(_:)`` when the
    ///   client did not advertise the capability.
    private func require(_ capability: Capability) throws {
        let advertised =
            switch capability {
            case .readTextFile: capabilities.fs.readTextFile
            case .writeTextFile: capabilities.fs.writeTextFile
            case .terminal: capabilities.terminal
            }
        guard advertised else {
            throw ClientEnvironmentError.capabilityUnavailable(capability)
        }
    }
}

/// A failure a ``ClientEnvironment`` operation raises to the tool that called
/// it, distinct from a `RequestError` the client returned.
public enum ClientEnvironmentError: Error, Hashable, Sendable {
    /// A gated operation was used without the client advertising its capability;
    /// no wire request was made.
    case capabilityUnavailable(ClientEnvironment.Capability)

    /// A permission request was rejected or cancelled rather than granted.
    case permissionDenied(ClientEnvironment.PermissionDenial)
}
