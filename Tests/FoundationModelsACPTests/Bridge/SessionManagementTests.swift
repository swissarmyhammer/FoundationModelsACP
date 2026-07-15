import Foundation
import FoundationModels
import Synchronization
import Testing

@testable import FoundationModelsACP

// MARK: - In-memory store

/// An in-memory session store that backs a ``SessionProvider``'s optional
/// hooks, so tests exercise list/resume/delete/close end to end without
/// persistence.
///
/// Restore rebuilds a live session from the stored transcript through the real
/// `LanguageModelSession(model:transcript:)` initializer — the typical restore
/// path — verifying the FoundationModels signature the provider hook relies on.
private final class InMemorySessionStore: Sendable {
    /// One stored session: its listing summary and the transcript restore
    /// rebuilds it from.
    private struct Record: Sendable {
        var info: SessionInfo
        var transcript: Transcript
    }

    /// The stored sessions, keyed by identity.
    private let records = Mutex<[SessionId: Record]>([:])

    /// Seeds the store with one stored session.
    ///
    /// - Parameters:
    ///   - sessionId: The identity to store under.
    ///   - transcript: The transcript restore rebuilds the session from.
    func store(_ sessionId: SessionId, transcript: Transcript = Transcript(entries: [])) {
        let info = SessionInfo(cwd: testCwd, sessionId: sessionId)
        records.withLock { $0[sessionId] = Record(info: info, transcript: transcript) }
    }

    /// Whether a session is currently stored.
    ///
    /// - Parameter sessionId: The identity to look for.
    /// - Returns: `true` while the session is stored.
    func contains(_ sessionId: SessionId) -> Bool {
        records.withLock { $0[sessionId] != nil }
    }

    /// Builds a provider whose four session hooks are all backed by this store.
    ///
    /// - Returns: A provider advertising the full session-management surface.
    func provider() -> SessionProvider {
        SessionProvider(
            makeSession: { cwd, _ in
                let sessionId = SessionId(rawValue: UUID().uuidString)
                self.records.withLock {
                    $0[sessionId] = Record(
                        info: SessionInfo(cwd: cwd, sessionId: sessionId),
                        transcript: Transcript(entries: [])
                    )
                }
                return (sessionId, makeModelSession())
            },
            listSessions: {
                self.records.withLock { $0.values.map(\.info) }
            },
            restoreSession: { sessionId in
                let transcript = self.records.withLock { $0[sessionId]?.transcript }
                guard let transcript else {
                    throw RequestError.invalidParams
                }
                return LanguageModelSession(model: SystemLanguageModel.default, transcript: transcript)
            },
            deleteSession: { sessionId in
                self.records.withLock { $0[sessionId] = nil }
            }
        )
    }
}

// MARK: - Helpers

/// Asserts a throwing operation fails with JSON-RPC method-not-found (-32601).
///
/// - Parameters:
///   - operation: The operation expected to answer method-not-found.
///   - sourceLocation: The caller location, for failure reporting.
private func expectMethodNotFound(
    _ operation: () async throws -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    do {
        try await operation()
        Issue.record("expected method-not-found (-32601)", sourceLocation: sourceLocation)
    } catch let error as RequestError {
        #expect(error.code == -32601, sourceLocation: sourceLocation)
    } catch {
        Issue.record("expected RequestError, got \(error)", sourceLocation: sourceLocation)
    }
}

/// Wires a store-backed bridge behind a client connection, returning the client
/// and the serving connection so a test can close both.
///
/// - Parameter store: The in-memory store backing the agent's session hooks.
/// - Returns: The client and serving connections.
private func makeStoreBridge(
    _ store: InMemorySessionStore
) async -> (client: ClientSideConnection, agentConnection: AgentSideConnection) {
    await makeWiredBridge { connection in
        FoundationModelsAgent(connection: connection, provider: store.provider())
    }
}

// MARK: - Hook present: forwarding round-trips over the wire

@Test("session/list forwards to the provider hook and returns the stored sessions", .timeLimit(.minutes(1)))
func listSessionsForwardsToProvider() async throws {
    let store = InMemorySessionStore()
    let ids: Set<SessionId> = [SessionId(rawValue: "list-a"), SessionId(rawValue: "list-b")]
    for id in ids {
        store.store(id)
    }
    let bridge = await makeStoreBridge(store)

    let response = try await bridge.client.listSessions(ListSessionsRequest())
    #expect(Set(response.sessions.map(\.sessionId)) == ids)

    await bridge.client.close()
    await bridge.agentConnection.close()
}

@Test("session/delete forwards to the provider hook, removing the stored session", .timeLimit(.minutes(1)))
func deleteSessionForwardsToProvider() async throws {
    let store = InMemorySessionStore()
    let deleted = SessionId(rawValue: "delete-me")
    store.store(deleted)
    let bridge = await makeStoreBridge(store)

    try await bridge.client.deleteSession(DeleteSessionRequest(sessionId: deleted))
    #expect(store.contains(deleted) == false)

    await bridge.client.close()
    await bridge.agentConnection.close()
}

@Test("session/resume restores through the provider hook and returns a resume response", .timeLimit(.minutes(1)))
func resumeSessionForwardsToProvider() async throws {
    let store = InMemorySessionStore()
    let resumable = SessionId(rawValue: "resume-me")
    store.store(resumable, transcript: Transcript(entries: [responseEntry("earlier turn")]))
    let bridge = await makeStoreBridge(store)

    let response = try await bridge.client.resumeSession(
        ResumeSessionRequest(cwd: testCwd, sessionId: resumable)
    )
    #expect(response == ResumeSessionResponse())

    await bridge.client.close()
    await bridge.agentConnection.close()
}

@Test("session/close round-trips over the wire for a store-backed agent", .timeLimit(.minutes(1)))
func closeSessionRoundTripsForStoreBackedAgent() async throws {
    let store = InMemorySessionStore()
    let bridge = await makeStoreBridge(store)
    let created = try await bridge.client.newSession(bridgeNewSessionRequest())

    // Close carries no provider hook; it returns an empty ok over the wire.
    try await bridge.client.closeSession(CloseSessionRequest(sessionId: created.sessionId))

    await bridge.client.close()
    await bridge.agentConnection.close()
}

@Test("closing a session drops its live copy from the bridge's map", .timeLimit(.minutes(1)))
func closeSessionDropsLiveSessionFromMap() async throws {
    let store = InMemorySessionStore()
    let (connection, agent) = await makeBridgeAgent(provider: store.provider())
    let created = try await agent.newSession(bridgeNewSessionRequest())

    try await agent.closeSession(CloseSessionRequest(sessionId: created.sessionId))

    // The live session is gone: the turn path no longer knows it.
    await #expect(throws: RequestError.invalidParams) {
        _ = try await agent.serializeTurn(for: created.sessionId) {}
    }
    _ = connection
}

@Test("all four session-management capabilities are advertised for a full store", .timeLimit(.minutes(1)))
func fullStoreAdvertisesEverySessionCapability() async throws {
    let store = InMemorySessionStore()
    let (connection, agent) = await makeBridgeAgent(provider: store.provider())

    let capabilities = try await agent.initialize(bridgeInitializeRequest()).agentCapabilities
    #expect(capabilities.sessionCapabilities.list != nil)
    #expect(capabilities.sessionCapabilities.resume != nil)
    #expect(capabilities.sessionCapabilities.delete != nil)
    #expect(capabilities.sessionCapabilities.close != nil)
    #expect(capabilities.loadSession == true)
    _ = connection
}

// MARK: - Hook absent: capabilities off and direct calls -32601

@Test("with no store hooks, every session-management capability is off", .timeLimit(.minutes(1)))
func absentHooksLeaveCapabilitiesOff() async throws {
    let (connection, agent) = await makeBridgeAgent(provider: singleSessionProvider())

    let capabilities = try await agent.initialize(bridgeInitializeRequest()).agentCapabilities
    #expect(capabilities.sessionCapabilities.list == nil)
    #expect(capabilities.sessionCapabilities.resume == nil)
    #expect(capabilities.sessionCapabilities.delete == nil)
    #expect(capabilities.sessionCapabilities.close == nil)
    #expect(capabilities.loadSession == false)
    _ = connection
}

@Test("with no store hooks, session-management methods answer method-not-found", .timeLimit(.minutes(1)))
func absentHooksAnswerMethodNotFound() async throws {
    let (connection, agent) = await makeBridgeAgent(provider: singleSessionProvider())
    let unknown = SessionId(rawValue: "never-stored")

    await expectMethodNotFound {
        _ = try await agent.listSessions(ListSessionsRequest())
    }
    await expectMethodNotFound {
        _ = try await agent.resumeSession(ResumeSessionRequest(cwd: testCwd, sessionId: unknown))
    }
    await expectMethodNotFound {
        _ = try await agent.loadSession(
            LoadSessionRequest(cwd: testCwd, mcpServers: [], sessionId: unknown)
        )
    }
    await expectMethodNotFound {
        try await agent.deleteSession(DeleteSessionRequest(sessionId: unknown))
    }
    await expectMethodNotFound {
        try await agent.closeSession(CloseSessionRequest(sessionId: unknown))
    }
    _ = connection
}

// MARK: - Resumed session runs the normal turn path

@Test(
    "a resumed session runs the normal turn path, identical to a fresh session",
    .timeLimit(.minutes(1))
)
func resumedSessionRunsNormalTurnPath() async throws {
    let store = InMemorySessionStore()
    let resumedId = SessionId(rawValue: "resumed")
    store.store(resumedId, transcript: Transcript(entries: [responseEntry("earlier")]))
    let (client, connection, agent) = await makeWiredBridgeAgent(provider: store.provider())

    // Before resume the session is unknown, so the turn path rejects it.
    await #expect(throws: RequestError.invalidParams) {
        _ = try await agent.serializeTurn(for: resumedId) {}
    }

    // Resuming registers the restored live session under its id.
    #expect(try await agent.resumeSession(
        ResumeSessionRequest(cwd: testCwd, sessionId: resumedId)
    ) == ResumeSessionResponse())

    // A fresh session for the same scripted turn, to compare against.
    let freshId = try await agent.newSession(bridgeNewSessionRequest()).sessionId
    #expect(freshId != resumedId)

    // Each session runs the prompt turn path — serializeTurn wrapping runTurn,
    // exactly as prompt() does, with a scripted generator in place of the live
    // model — and both behave identically: end_turn plus the same update. The
    // subscribers are opened before the turns run so no update is dropped.
    var resumedUpdates = client.updates(for: resumedId).makeAsyncIterator()
    var freshUpdates = client.updates(for: freshId).makeAsyncIterator()

    let resumedStop = try await runScriptedTurn(on: agent, session: resumedId, answer: "restored answer")
    let freshStop = try await runScriptedTurn(on: agent, session: freshId, answer: "restored answer")

    #expect(resumedStop == .endTurn)
    #expect(freshStop == .endTurn)
    #expect(await resumedUpdates.next() == messageChunkUpdate("restored answer"))
    #expect(await freshUpdates.next() == messageChunkUpdate("restored answer"))

    await client.close()
    _ = connection
}

/// Runs one scripted prompt turn on a session through the production turn path —
/// ``FoundationModelsAgent/serializeTurn(for:_:)`` wrapping
/// ``FoundationModelsAgent/runTurn(for:generate:)`` — delivering a single
/// response entry rather than driving the live model.
///
/// - Parameters:
///   - agent: The bridge agent to run the turn on.
///   - session: The session the turn belongs to.
///   - answer: The response text the scripted turn emits.
/// - Returns: The turn's stop reason.
/// - Throws: Any error the turn path raises.
private func runScriptedTurn(
    on agent: FoundationModelsAgent,
    session: SessionId,
    answer: String
) async throws -> StopReason {
    try await agent.serializeTurn(for: session) {
        try await agent.runTurn(for: session) { deliver in
            await deliver([responseEntry(answer)])
            return Transcript(entries: [responseEntry(answer)])
        }
    }.stopReason
}
