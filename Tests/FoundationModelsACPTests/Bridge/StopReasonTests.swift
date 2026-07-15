import FoundationModels
import Testing

@testable import FoundationModelsACP

// MARK: - Stop-reason derivation

@Test("a turn that ends normally reports end_turn")
func stopReasonEndTurnOnSuccess() throws {
    #expect(try FoundationModelsAgent.stopReason(error: nil, cancelled: false) == .endTurn)
}

@Test("a context-window overflow reports max_tokens")
func stopReasonMaxTokensOnContextOverflow() throws {
    let error = LanguageModelError.contextSizeExceeded(
        .init(contextSize: 4096, tokenCount: 5000, debugDescription: "over")
    )
    #expect(try FoundationModelsAgent.stopReason(error: error, cancelled: false) == .maxTokens)
}

@Test("a refusal reports refusal")
func stopReasonRefusalOnRefusal() throws {
    let error = LanguageModelError.refusal(.init(explanation: "declined", debugDescription: "declined"))
    #expect(try FoundationModelsAgent.stopReason(error: error, cancelled: false) == .refusal)
}

@Test("a guardrail violation reports refusal")
func stopReasonRefusalOnGuardrailViolation() throws {
    let error = LanguageModelError.guardrailViolation(.init(debugDescription: "blocked"))
    #expect(try FoundationModelsAgent.stopReason(error: error, cancelled: false) == .refusal)
}

@Test("a cancelled turn reports cancelled, even when an error also surfaced")
func stopReasonCancelledOverridesError() throws {
    #expect(try FoundationModelsAgent.stopReason(error: nil, cancelled: true) == .cancelled)
    #expect(try FoundationModelsAgent.stopReason(error: CancellationError(), cancelled: true) == .cancelled)
}

@Test("a cancellation error alone reports cancelled")
func stopReasonCancelledFromCancellationError() throws {
    #expect(try FoundationModelsAgent.stopReason(error: CancellationError(), cancelled: false) == .cancelled)
}

@Test("an unexpected error propagates rather than becoming a stop reason")
func stopReasonPropagatesUnexpectedError() {
    struct Boom: Error {}
    #expect(throws: Boom.self) {
        _ = try FoundationModelsAgent.stopReason(error: Boom(), cancelled: false)
    }
}

// MARK: - Turn end to end

@Test("a normal turn delivers its updates and answers end_turn", .timeLimit(.minutes(1)))
func normalTurnDeliversUpdatesAndEndsWithEndTurn() async throws {
    let sessionId = SessionId(rawValue: "stop-normal")
    let (client, connection, agent) = await makeWiredBridgeAgent(
        provider: singleSessionProvider(sessionId: sessionId)
    )
    _ = try await agent.newSession(bridgeNewSessionRequest())
    var updates = client.updates(for: sessionId).makeAsyncIterator()

    let response = try await agent.runTurn(for: sessionId) { deliver in
        await deliver([responseEntry("hello")])
        return Transcript(entries: [responseEntry("hello")])
    }

    #expect(response.stopReason == .endTurn)
    #expect(await updates.next() == messageChunkUpdate("hello"))
    await client.close()
    _ = connection
}

@Test("a refused turn answers refusal", .timeLimit(.minutes(1)))
func refusedTurnEndsWithRefusal() async throws {
    let sessionId = SessionId(rawValue: "stop-refusal")
    let (connection, agent) = await makeBridgeAgent(provider: singleSessionProvider(sessionId: sessionId))
    _ = try await agent.newSession(bridgeNewSessionRequest())

    let response = try await agent.runTurn(for: sessionId) { _ in
        throw LanguageModelError.refusal(.init(explanation: "declined", debugDescription: "declined"))
    }
    #expect(response.stopReason == .refusal)
    _ = connection
}

@Test("a context-overflow turn answers max_tokens", .timeLimit(.minutes(1)))
func overflowTurnEndsWithMaxTokens() async throws {
    let sessionId = SessionId(rawValue: "stop-max")
    let (connection, agent) = await makeBridgeAgent(provider: singleSessionProvider(sessionId: sessionId))
    _ = try await agent.newSession(bridgeNewSessionRequest())

    let response = try await agent.runTurn(for: sessionId) { _ in
        throw LanguageModelError.contextSizeExceeded(
            .init(contextSize: 4096, tokenCount: 5000, debugDescription: "over")
        )
    }
    #expect(response.stopReason == .maxTokens)
    _ = connection
}

@Test("cancel mid-turn stops generation, lands trailing updates, then answers cancelled", .timeLimit(.minutes(1)))
func cancelMidTurnYieldsTrailingUpdateThenCancelled() async throws {
    let sessionId = SessionId(rawValue: "stop-cancel")
    let (client, connection, agent) = await makeWiredBridgeAgent(
        provider: singleSessionProvider(sessionId: sessionId)
    )
    _ = try await agent.newSession(bridgeNewSessionRequest())
    var updates = client.updates(for: sessionId).makeAsyncIterator()

    let progress = TurnRecorder()
    let release = TurnGate()

    let turn = Task {
        try await agent.runTurn(for: sessionId) { deliver in
            await deliver([reasoningEntry("thinking")])
            await progress.record("first-delivered")
            await release.wait()
            await deliver([reasoningEntry("thinking"), responseEntry("stopped")])
            return Transcript(entries: [reasoningEntry("thinking"), responseEntry("stopped")])
        }
    }

    // The first update lands, then we cancel while the turn is held open.
    #expect(await updates.next() == thoughtChunkUpdate("thinking"))
    await waitUntil(progress, records: "first-delivered")
    await agent.cancel(CancelNotification(sessionId: sessionId))
    await release.open()

    let response = try await turn.value
    #expect(response.stopReason == .cancelled)
    // The update delivered after cancellation still reaches the client.
    #expect(await updates.next() == messageChunkUpdate("stopped"))
    await client.close()
    _ = connection
}
