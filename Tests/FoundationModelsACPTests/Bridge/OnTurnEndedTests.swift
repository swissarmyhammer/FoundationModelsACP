import FoundationModels
import Synchronization
import Testing

@testable import FoundationModelsACP

@Test("onTurnEnded receives the turn's final transcript exactly once", .timeLimit(.minutes(1)))
func onTurnEndedReceivesFinalTranscriptOnce() async throws {
    let sessionId = SessionId(rawValue: "hook-1")
    let recorded = Mutex<[(SessionId, Int)]>([])
    let provider = SessionProvider(
        makeSession: { _, _ in (sessionId, makeModelSession()) },
        onTurnEnded: { session, transcript in
            recorded.withLock { $0.append((session, transcript.count)) }
        }
    )
    let (connection, agent) = await makeBridgeAgent(provider: provider)
    _ = try await agent.newSession(bridgeNewSessionRequest())

    // The generator delivers one entry but returns a two-entry transcript; the
    // hook must see the returned final transcript, not the delivered entries.
    let response = try await agent.runTurn(for: sessionId) { deliver in
        await deliver([responseEntry("answer")])
        return Transcript(entries: [reasoningEntry("thinking"), responseEntry("answer")])
    }

    #expect(response.stopReason == .endTurn)
    let seen = recorded.withLock { $0 }
    #expect(seen.count == 1)
    #expect(seen.first?.0 == sessionId)
    #expect(seen.first?.1 == 2)
    _ = connection
}

@Test("a nil onTurnEnded hook is a no-op and the turn still completes", .timeLimit(.minutes(1)))
func nilOnTurnEndedHookIsNoOp() async throws {
    let sessionId = SessionId(rawValue: "hook-nil")
    let (connection, agent) = await makeBridgeAgent(provider: singleSessionProvider(sessionId: sessionId))
    _ = try await agent.newSession(bridgeNewSessionRequest())

    let response = try await agent.runTurn(for: sessionId) { deliver in
        await deliver([responseEntry("done")])
        return Transcript(entries: [responseEntry("done")])
    }
    #expect(response.stopReason == .endTurn)
    _ = connection
}
