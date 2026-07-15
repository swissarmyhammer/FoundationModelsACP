import Foundation
import FoundationModels
import Synchronization

@testable import FoundationModelsACP

/// One tool call observed on the wire during an eval turn.
struct ObservedToolCall: Sendable, Hashable {
    /// The called tool's name, from the `tool_call` update's title.
    let name: String

    /// The call's id, from the `tool_call` update's `toolCallId`.
    let toolCallId: String

    /// The call's raw input, as it crossed the wire.
    let rawInput: JSONValue?
}

/// What a single live eval turn produced: the tool calls the agent emitted and
/// whether any tool completed with a result.
struct TurnObservation: Sendable {
    /// The `tool_call` updates the agent emitted, in order.
    let toolCalls: [ObservedToolCall]

    /// Whether the turn emitted a completed `tool_call_update` (a structured
    /// result flowed back).
    let producedResult: Bool
}

/// A ``Client`` that records the agent's `session/update` stream and serves the
/// reverse `fs/read_text_file` and permission requests an eval tool may issue.
///
/// It advertises read-only filesystem access, so the ``ReaderEvalTool`` reaches
/// canned content; a permission request is granted so a consenting tool
/// proceeds.
private final class EvalRecordingClient: Client {
    /// The canned file content served for any `fs/read_text_file`.
    private let fileContent: String

    /// The `session/update` payloads received, in order.
    private let updateLog = Mutex<[SessionUpdate]>([])

    /// Creates a recording client serving fixed file content.
    ///
    /// - Parameter fileContent: The content every read returns.
    init(fileContent: String) {
        self.fileContent = fileContent
    }

    /// The `session/update` payloads received so far.
    var updates: [SessionUpdate] {
        updateLog.withLock { $0 }
    }

    func sessionUpdate(_ notification: SessionNotification) async {
        updateLog.withLock { $0.append(notification.update) }
    }

    func requestPermission(
        _ params: RequestPermissionRequest
    ) async throws -> RequestPermissionResponse {
        let optionId = params.options.first?.optionId ?? PermissionOptionId(rawValue: "allow")
        return RequestPermissionResponse(
            outcome: .selected(SelectedPermissionOutcome(optionId: optionId))
        )
    }

    func readTextFile(_ params: ReadTextFileRequest) async throws -> ReadTextFileResponse {
        ReadTextFileResponse(content: fileContent)
    }
}

/// Drives eval cases through the real bridge over the live on-device model
/// (spec §8).
///
/// Each case runs its own single-turn session, serialized by the caller: one
/// ``LanguageModelSession`` runs one turn at a time, so cases never overlap and
/// the process never traps on concurrent turns. The harness wires a real
/// ``FoundationModelsAgent`` to an ``EvalRecordingClient`` over an in-memory
/// transport, runs `initialize` → `session/new` → `session/prompt`, and reports
/// the tool calls the turn produced.
enum EvalHarness {
    /// The read-only client capabilities every eval session advertises, so a
    /// selected file read reaches the client.
    private static let capabilities = ClientCapabilities(
        fs: FileSystemCapabilities(readTextFile: true)
    )

    /// The working directory every eval session is created in.
    private static let workingDirectory = AbsolutePath(rawValue: "/workspace")!

    /// The content the recording client serves for any file read.
    private static let cannedFileContent = "This file contains the project notes."

    /// A generous per-turn timeout, so a wedged turn fails the sample rather
    /// than hanging the suite.
    private static let turnTimeout = Duration.seconds(120)

    /// Runs one live turn for a case and reports what the agent emitted.
    ///
    /// - Parameter evalCase: The case whose prompt to drive.
    /// - Returns: The turn's observed tool calls and result flag.
    /// - Throws: Any connection error, or a timeout, driving the turn.
    static func run(_ evalCase: EvalCase) async throws -> TurnObservation {
        let sessionId = SessionId(rawValue: "eval-\(evalCase.name)")
        let provider = liveProvider(sessionId: sessionId)
        let client = EvalRecordingClient(fileContent: cannedFileContent)

        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agentConnection = await AgentSideConnection(stream: agentEnd) { connection in
            FoundationModelsAgent(connection: connection, provider: provider)
        }
        let clientConnection = await ClientSideConnection(
            stream: clientEnd,
            requestTimeout: turnTimeout
        ) { _ in client }

        _ = try await clientConnection.initialize(
            InitializeRequest(protocolVersion: .latest, clientCapabilities: capabilities)
        )
        let session = try await clientConnection.newSession(
            NewSessionRequest(cwd: workingDirectory, mcpServers: [])
        )
        _ = try await clientConnection.prompt(
            PromptRequest(prompt: evalCase.prompt, sessionId: session.sessionId)
        )

        // Keep the connections alive until the turn's updates are recorded.
        withExtendedLifetime((agentConnection, clientConnection)) {}
        return observation(from: client.updates)
    }

    /// Builds a single-session provider whose session is backed by the live
    /// on-device model with every eval tool registered.
    ///
    /// - Parameter sessionId: The identity to assign the session.
    /// - Returns: A provider yielding the live-model session.
    private static func liveProvider(sessionId: SessionId) -> SessionProvider {
        SessionProvider(makeSession: { _, _ in
            let session = LanguageModelSession(
                tools: EvalToolRegistry.all,
                instructions: "You are a helpful assistant. Use the provided tools when the request calls for them."
            )
            return (sessionId, session)
        })
    }

    /// Reduces a recorded update stream to the turn's observation.
    ///
    /// - Parameter updates: The `session/update` payloads received.
    /// - Returns: The observed tool calls and whether a result completed.
    private static func observation(from updates: [SessionUpdate]) -> TurnObservation {
        var toolCalls: [ObservedToolCall] = []
        var producedResult = false
        for update in updates {
            switch update {
            case .toolCall(let call):
                toolCalls.append(
                    ObservedToolCall(
                        name: call.title,
                        toolCallId: call.toolCallId.rawValue,
                        rawInput: call.rawInput
                    )
                )
            case .toolCallUpdate(let update) where update.status == .completed:
                producedResult = true
            default:
                break
            }
        }
        return TurnObservation(toolCalls: toolCalls, producedResult: producedResult)
    }
}
