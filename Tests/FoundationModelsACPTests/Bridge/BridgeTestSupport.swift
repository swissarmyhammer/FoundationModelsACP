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
/// - Parameter sessionID: The identity every `session/new` returns.
/// - Returns: A single-session provider.
func singleSessionProvider(
    sessionID: SessionId = SessionId(rawValue: "session-1")
) -> SessionProvider {
    let session = makeModelSession()
    return SessionProvider(makeSession: { _, _ in (sessionID, session) })
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
