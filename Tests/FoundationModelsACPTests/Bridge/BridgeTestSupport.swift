import Foundation
import FoundationModels
import Synchronization
import Testing

@testable import FoundationModelsACP

// MARK: - Model sessions

/// Builds a live `LanguageModelSession` over the system model.
///
/// Construction never runs inference, so this is safe and fast in tests; the
/// bridge skeleton under test never drives a turn against the model.
///
/// - Returns: A fresh session over `SystemLanguageModel.default`.
func makeModelSession() -> LanguageModelSession {
    LanguageModelSession(model: SystemLanguageModel.default)
}

// MARK: - Providers

/// A provider that always yields one fixed session under a fixed id, with no
/// store hooks — the shape the one-liner sugar produces.
///
/// - Parameter sessionId: The identity every `session/new` returns.
/// - Returns: A single-session provider.
func singleSessionProvider(
    sessionId: SessionId = SessionId(rawValue: "session-1")
) -> SessionProvider {
    let session = makeModelSession()
    return SessionProvider(makeSession: { _, _ in (sessionId, session) })
}

/// A multi-session provider that mints a distinct id and session per
/// `session/new`, so its sessions serialize independently.
///
/// - Returns: A provider whose sessions are all distinct.
func countingProvider() -> SessionProvider {
    let counter = Mutex(0)
    return SessionProvider { _, _ in
        let index = counter.withLock { value -> Int in
            value += 1
            return value
        }
        return (SessionId(rawValue: "session-\(index)"), makeModelSession())
    }
}

// MARK: - Agent construction

/// Builds a bridge agent and its serving connection, returning the concrete
/// actor so tests can call it directly.
///
/// The factory closure that `AgentSideConnection` runs captures the agent into a
/// box so the concrete type — not the erased `any Agent` the connection keeps —
/// is available to the test.
///
/// - Parameter provider: The session provider to build the agent from.
/// - Returns: The serving connection (kept alive by the caller) and the agent.
func makeBridgeAgent(
    provider: SessionProvider
) async -> (connection: AgentSideConnection, agent: FoundationModelsAgent) {
    let (_, agentEnd) = InMemoryTransport.pair()
    let box = Mutex<FoundationModelsAgent?>(nil)
    let connection = await AgentSideConnection(stream: agentEnd) { conn in
        let agent = FoundationModelsAgent(connection: conn, provider: provider)
        box.withLock { $0 = agent }
        return agent
    }
    return (connection, box.withLock { $0! })
}

/// Wires a bridge agent behind a client connection over an in-memory transport,
/// so a test can drive it exactly as a real client would.
///
/// - Parameter factory: Builds the agent from its connection.
/// - Returns: The client and agent connections.
func makeWiredBridge(
    _ factory: @escaping @Sendable (AgentSideConnection) -> any Agent
) async -> (client: ClientSideConnection, agentConnection: AgentSideConnection) {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agentConnection = await AgentSideConnection(stream: agentEnd, factory)
    let client = await ClientSideConnection(stream: clientEnd) { _ in MinimalClient() }
    return (client, agentConnection)
}

/// Wires a bridge agent behind a client connection and hands back the concrete
/// agent, so a test can call ``FoundationModelsAgent/runTurn(for:generate:)``
/// directly while observing the `session/update` notifications it emits over the
/// wire through ``ClientSideConnection/updates(for:)``.
///
/// - Parameter provider: The session provider to build the agent from.
/// - Returns: The client connection, the serving connection (kept alive by the
///   caller), and the concrete agent.
func makeWiredBridgeAgent(
    provider: SessionProvider
) async -> (client: ClientSideConnection, connection: AgentSideConnection, agent: FoundationModelsAgent) {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let box = Mutex<FoundationModelsAgent?>(nil)
    let connection = await AgentSideConnection(stream: agentEnd) { conn in
        let agent = FoundationModelsAgent(connection: conn, provider: provider)
        box.withLock { $0 = agent }
        return agent
    }
    let client = await ClientSideConnection(stream: clientEnd) { _ in MinimalClient() }
    return (client, connection, box.withLock { $0! })
}

// MARK: - Scripted transcript entries

/// Builds a response entry carrying one text segment.
///
/// - Parameter text: The response text.
/// - Returns: A `.response` transcript entry.
func responseEntry(_ text: String) -> Transcript.Entry {
    .response(Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: text))]))
}

/// Builds a reasoning entry carrying one text segment.
///
/// - Parameter text: The reasoning text.
/// - Returns: A `.reasoning` transcript entry.
func reasoningEntry(_ text: String) -> Transcript.Entry {
    .reasoning(Transcript.Reasoning(segments: [.text(Transcript.TextSegment(content: text))]))
}

/// Builds a single-call tool-calls entry.
///
/// - Parameters:
///   - id: The tool call's identifier, echoed to the matching output.
///   - name: The tool's name.
///   - argumentsJSON: The call's arguments as a JSON string.
/// - Returns: A `.toolCalls` transcript entry.
/// - Throws: Rethrows any failure parsing `argumentsJSON`.
func toolCallEntry(id: String, name: String, argumentsJSON: String) throws -> Transcript.Entry {
    let arguments = try GeneratedContent(json: argumentsJSON)
    return .toolCalls(Transcript.ToolCalls([Transcript.ToolCall(id: id, toolName: name, arguments: arguments)]))
}

/// Builds a tool-output entry carrying one text segment, keyed to its call.
///
/// - Parameters:
///   - id: The answered tool call's identifier.
///   - name: The tool's name.
///   - text: The output text.
/// - Returns: A `.toolOutput` transcript entry.
func toolOutputEntry(id: String, name: String, text: String) -> Transcript.Entry {
    .toolOutput(
        Transcript.ToolOutput(id: id, toolName: name, segments: [.text(Transcript.TextSegment(content: text))])
    )
}

/// Builds a response entry whose single structured segment is a plan.
///
/// - Parameter planJSON: The plan's JSON, matching the ACP ``Plan`` shape.
/// - Returns: A `.response` transcript entry carrying a plan structured segment.
/// - Throws: Rethrows any failure parsing `planJSON`.
func planResponseEntry(_ planJSON: String) throws -> Transcript.Entry {
    let content = try GeneratedContent(json: planJSON)
    let segment = Transcript.StructuredSegment(schemaName: "plan", content: content)
    return .response(Transcript.Response(assetIDs: [], segments: [.structure(segment)]))
}

/// Decodes a JSON string into a ``JSONValue`` for asserting mapped raw inputs.
///
/// - Parameter string: The JSON text to decode.
/// - Returns: The decoded value.
/// - Throws: Rethrows any decoding failure.
func jsonValue(_ string: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8))
}

/// Wraps text as an agent-message-chunk update, matching the mapper's output.
///
/// - Parameter text: The chunk text.
/// - Returns: The message-chunk update.
func messageChunkUpdate(_ text: String) -> SessionUpdate {
    .agentMessageChunk(ContentChunk(content: .text(TextContent(text: text))))
}

/// Wraps text as an agent-thought-chunk update, matching the mapper's output.
///
/// - Parameter text: The chunk text.
/// - Returns: The thought-chunk update.
func thoughtChunkUpdate(_ text: String) -> SessionUpdate {
    .agentThoughtChunk(ContentChunk(content: .text(TextContent(text: text))))
}

// MARK: - Canonical requests

/// A canonical initialize request at the latest protocol version.
func bridgeInitializeRequest() -> InitializeRequest {
    InitializeRequest(protocolVersion: .latest)
}

/// A canonical new-session request rooted at the shared test cwd.
///
/// - Parameter mcpServers: The MCP configs to carry; empty by default.
/// - Returns: A new-session request.
func bridgeNewSessionRequest(mcpServers: [MCPServerConfig] = []) -> NewSessionRequest {
    NewSessionRequest(cwd: testCwd, mcpServers: mcpServers)
}

// MARK: - Turn instrumentation

/// Records an ordered log of turn events so a test can assert the exact
/// interleaving of concurrent turns.
actor TurnRecorder {
    /// The events recorded so far, in order.
    private var log: [String] = []

    /// Appends one event to the log.
    ///
    /// - Parameter event: The event name to record.
    func record(_ event: String) {
        log.append(event)
    }

    /// The ordered events recorded so far.
    func events() -> [String] {
        log
    }

    /// Whether the given event has been recorded.
    ///
    /// - Parameter event: The event name to look for.
    /// - Returns: `true` once the event has been recorded.
    func contains(_ event: String) -> Bool {
        log.contains(event)
    }
}

/// A one-shot gate a test opens to release turns it is holding mid-body,
/// letting the test control exactly when a turn completes.
actor TurnGate {
    /// Whether the gate has been opened.
    private var isOpen = false

    /// Continuations parked in ``wait()`` until the gate opens.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Opens the gate, resuming every parked waiter.
    func open() {
        isOpen = true
        let parked = waiters
        waiters.removeAll()
        for waiter in parked {
            waiter.resume()
        }
    }

    /// Suspends until the gate is open.
    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Spins until the recorder has seen `event`, yielding between checks.
///
/// Deterministic because the awaited event is one a turn body always records;
/// bounded by the test's time limit.
///
/// - Parameters:
///   - recorder: The recorder to poll.
///   - event: The event to wait for.
func waitUntil(_ recorder: TurnRecorder, records event: String) async {
    while await !recorder.contains(event) {
        await Task.yield()
    }
}
