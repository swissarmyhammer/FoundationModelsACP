import Foundation
import Synchronization
import Testing

@testable import FoundationModelsACP

/// Which optional store hook a provider carries, driving capability gating.
enum StoreHook: Sendable, CaseIterable {
    case list
    case resume
    case delete
}

/// Builds a single-session provider carrying exactly the given store hooks.
///
/// - Parameter hooks: The optional hooks to attach.
/// - Returns: A provider whose hook presence matches `hooks`.
private func provider(with hooks: Set<StoreHook>) -> SessionProvider {
    var provider = singleSessionProvider()
    if hooks.contains(.list) {
        provider.listSessions = { [] }
    }
    if hooks.contains(.resume) {
        provider.restoreSession = { _ in makeModelSession() }
    }
    if hooks.contains(.delete) {
        provider.deleteSession = { _ in }
    }
    return provider
}

@Test(
    "initialize advertises a session-management capability iff its hook is present",
    arguments: [
        Set<StoreHook>(),
        [.list],
        [.resume],
        [.delete],
        Set(StoreHook.allCases),
    ] as [Set<StoreHook>]
)
func capabilitiesGatedByHookPresence(hooks: Set<StoreHook>) async throws {
    let (connection, agent) = await makeBridgeAgent(provider: provider(with: hooks))
    let response = try await agent.initialize(bridgeInitializeRequest())
    let capabilities = response.agentCapabilities.sessionCapabilities

    #expect((capabilities.list != nil) == hooks.contains(.list))
    #expect((capabilities.resume != nil) == hooks.contains(.resume))
    #expect((capabilities.delete != nil) == hooks.contains(.delete))
    _ = connection
}

@Test("newSession hands the request's cwd and MCP configs to the provider")
func newSessionPlumbsRequestToProvider() async throws {
    let recordedCwd = Mutex<AbsolutePath?>(nil)
    let recordedServers = Mutex<[MCPServerConfig]?>(nil)
    let session = makeModelSession()
    let assignedID = SessionId(rawValue: "plumbed-session")

    let provider = SessionProvider { cwd, servers in
        recordedCwd.withLock { $0 = cwd }
        recordedServers.withLock { $0 = servers }
        return (assignedID, session)
    }
    let (connection, agent) = await makeBridgeAgent(provider: provider)

    let cwd = AbsolutePath(rawValue: "/work/dir")!
    let servers: [MCPServerConfig] = [.object(["name": .string("srv"), "command": .string("run")])]
    let response = try await agent.newSession(NewSessionRequest(cwd: cwd, mcpServers: servers))

    #expect(response.sessionId == assignedID)
    #expect(recordedCwd.withLock { $0 } == cwd)
    #expect(recordedServers.withLock { $0 } == servers)
    _ = connection
}

@Test("the one-liner behaves identically on the wire to an explicit single-session provider")
func oneLinerMatchesExplicitProvider() async throws {
    let session = makeModelSession()
    let oneLiner = await makeWiredBridge { connection in
        FoundationModelsAgent(connection: connection, session: session)
    }
    let explicitID = SessionId(rawValue: "explicit-session")
    let explicit = await makeWiredBridge { connection in
        FoundationModelsAgent(
            connection: connection,
            provider: SessionProvider(makeSession: { _, _ in (explicitID, session) })
        )
    }

    // Both advertise the same capabilities: no session management (hooks nil).
    let oneLinerInit = try await oneLiner.client.initialize(bridgeInitializeRequest())
    let explicitInit = try await explicit.client.initialize(bridgeInitializeRequest())
    #expect(oneLinerInit == explicitInit)
    #expect(oneLinerInit.agentCapabilities.sessionCapabilities.list == nil)
    #expect(oneLinerInit.agentCapabilities.sessionCapabilities.resume == nil)
    #expect(oneLinerInit.agentCapabilities.sessionCapabilities.delete == nil)

    // A single-session provider hands out one stable id for every session/new.
    let first = try await oneLiner.client.newSession(bridgeNewSessionRequest())
    let second = try await oneLiner.client.newSession(bridgeNewSessionRequest())
    #expect(first.sessionId == second.sessionId)

    // The explicit provider's id plumbs straight through to the wire response.
    let explicitSession = try await explicit.client.newSession(bridgeNewSessionRequest())
    #expect(explicitSession.sessionId == explicitID)

    // A prompt turn resolves at its own turn's end over the wire.
    let prompt = PromptRequest(
        prompt: [.text(TextContent(text: "hi"))],
        sessionId: first.sessionId
    )
    #expect(try await oneLiner.client.prompt(prompt).stopReason == .endTurn)

    await oneLiner.client.close()
    await oneLiner.agentConnection.close()
    await explicit.client.close()
    await explicit.agentConnection.close()
}
