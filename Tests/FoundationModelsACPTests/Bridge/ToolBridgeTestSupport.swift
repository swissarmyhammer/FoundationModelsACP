import Foundation
import Synchronization
import Testing

@testable import FoundationModelsACP

// MARK: - Recording client

/// A ``Client`` that records the ordered sequence of reverse-direction calls a
/// ``ClientEnvironment`` makes and returns configurable canned responses.
///
/// The ordered ``recordedCalls`` log is the wire sequence a tool-bridge test
/// asserts against; per-method captures expose the exact requests, and
/// ``recordedUpdates`` captures the `session/update` payloads the bridge emits
/// (such as an embedded terminal).
final class RecordingEnvironmentClient: Client {
    /// The canned responses the recording client returns.
    struct Configuration: Sendable {
        /// The content `fs/read_text_file` returns.
        var fileContent = "file contents"

        /// The outcome `session/request_permission` returns.
        var permissionOutcome = RequestPermissionOutcome.cancelled

        /// The terminal id `terminal/create` returns.
        var terminalId = TerminalId(rawValue: "terminal-created")

        /// The output `terminal/output` returns.
        var terminalOutput = "command output"

        /// Whether `terminal/output` reports truncation.
        var truncated = false

        /// The exit code `terminal/wait_for_exit` returns.
        var exitCode: Int? = 0

        /// The signal `terminal/wait_for_exit` returns.
        var exitSignal: String?

        /// Creates a configuration; every field defaults to a benign value.
        init(
            fileContent: String = "file contents",
            permissionOutcome: RequestPermissionOutcome = .cancelled,
            terminalId: TerminalId = TerminalId(rawValue: "terminal-created"),
            terminalOutput: String = "command output",
            truncated: Bool = false,
            exitCode: Int? = 0,
            exitSignal: String? = nil
        ) {
            self.fileContent = fileContent
            self.permissionOutcome = permissionOutcome
            self.terminalId = terminalId
            self.terminalOutput = terminalOutput
            self.truncated = truncated
            self.exitCode = exitCode
            self.exitSignal = exitSignal
        }
    }

    /// The canned responses this client returns.
    private let configuration: Configuration

    /// The ordered handler names invoked, forming the observed wire sequence.
    private let callLog = Mutex<[String]>([])

    /// The `session/update` payloads received, in order.
    private let updateLog = Mutex<[SessionUpdate]>([])

    /// The read, write, permission, and create requests received, in order.
    private let requestLog = Mutex<ReceivedRequests>(ReceivedRequests())

    /// The typed requests captured for assertions.
    private struct ReceivedRequests: Sendable {
        /// Read requests received, in order.
        var reads: [ReadTextFileRequest] = []

        /// Write requests received, in order.
        var writes: [WriteTextFileRequest] = []

        /// Permission requests received, in order.
        var permissions: [RequestPermissionRequest] = []

        /// Create-terminal requests received, in order.
        var creates: [CreateTerminalRequest] = []
    }

    /// Creates a recording client with the given canned responses.
    ///
    /// - Parameter configuration: The responses to return; benign by default.
    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// The ordered handler names invoked so far.
    var recordedCalls: [String] {
        callLog.withLock { $0 }
    }

    /// The `session/update` payloads received so far.
    var recordedUpdates: [SessionUpdate] {
        updateLog.withLock { $0 }
    }

    /// The most recent read request, if any.
    var lastRead: ReadTextFileRequest? {
        requestLog.withLock { $0.reads.last }
    }

    /// The most recent write request, if any.
    var lastWrite: WriteTextFileRequest? {
        requestLog.withLock { $0.writes.last }
    }

    /// The most recent permission request, if any.
    var lastPermission: RequestPermissionRequest? {
        requestLog.withLock { $0.permissions.last }
    }

    /// The most recent create-terminal request, if any.
    var lastCreate: CreateTerminalRequest? {
        requestLog.withLock { $0.creates.last }
    }

    /// Records one handler invocation by name.
    ///
    /// - Parameter handler: The handler name to append to the sequence.
    private func note(_ handler: String) {
        callLog.withLock { $0.append(handler) }
    }

    func sessionUpdate(_ notification: SessionNotification) async {
        note("sessionUpdate")
        updateLog.withLock { $0.append(notification.update) }
    }

    func requestPermission(_ params: RequestPermissionRequest) async throws -> RequestPermissionResponse {
        note("requestPermission")
        requestLog.withLock { $0.permissions.append(params) }
        return RequestPermissionResponse(outcome: configuration.permissionOutcome)
    }

    func readTextFile(_ params: ReadTextFileRequest) async throws -> ReadTextFileResponse {
        note("readTextFile")
        requestLog.withLock { $0.reads.append(params) }
        return ReadTextFileResponse(content: configuration.fileContent)
    }

    func writeTextFile(_ params: WriteTextFileRequest) async throws {
        note("writeTextFile")
        requestLog.withLock { $0.writes.append(params) }
    }

    func createTerminal(_ params: CreateTerminalRequest) async throws -> CreateTerminalResponse {
        note("createTerminal")
        requestLog.withLock { $0.creates.append(params) }
        return CreateTerminalResponse(terminalId: configuration.terminalId)
    }

    func terminalOutput(_ params: TerminalOutputRequest) async throws -> TerminalOutputResponse {
        note("terminalOutput")
        return TerminalOutputResponse(output: configuration.terminalOutput, truncated: configuration.truncated)
    }

    func waitForTerminalExit(_ params: WaitForTerminalExitRequest) async throws -> WaitForTerminalExitResponse {
        note("waitForTerminalExit")
        return WaitForTerminalExitResponse(exitCode: configuration.exitCode, signal: configuration.exitSignal)
    }

    func killTerminal(_ params: KillTerminalRequest) async throws {
        note("killTerminal")
    }

    func releaseTerminal(_ params: ReleaseTerminalRequest) async throws {
        note("releaseTerminal")
    }
}

// MARK: - Wiring

/// A ``ClientEnvironment`` wired to a ``RecordingEnvironmentClient`` over an
/// in-memory transport, plus the connections keeping it alive.
struct WiredEnvironment {
    /// The handle under test, driving the recording client's environment.
    let environment: ClientEnvironment

    /// The agent side the environment issues reverse calls over.
    let agentConnection: AgentSideConnection

    /// The client side serving the recording client.
    let clientConnection: ClientSideConnection
}

/// Wires a ``ClientEnvironment`` to a recording client back-to-back, so a test
/// can call the handle and assert the reverse-direction requests it emits.
///
/// - Parameters:
///   - capabilities: The capabilities the environment gates against.
///   - sessionId: The session the environment scopes requests to.
///   - client: The recording client to serve and assert on.
/// - Returns: The wired environment and its connections.
func makeWiredEnvironment(
    capabilities: ClientCapabilities,
    sessionId: SessionId = testSessionId,
    client: RecordingEnvironmentClient
) async -> WiredEnvironment {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agentConnection = await AgentSideConnection(stream: agentEnd) { _ in MinimalAgent() }
    let clientConnection = await ClientSideConnection(stream: clientEnd) { _ in client }
    let environment = ClientEnvironment(
        connection: agentConnection,
        sessionId: sessionId,
        capabilities: capabilities
    )
    return WiredEnvironment(
        environment: environment,
        agentConnection: agentConnection,
        clientConnection: clientConnection
    )
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
