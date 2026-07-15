import Foundation
import Testing

@testable import FoundationModelsACP

@Test(
    "overlapping turns on one session serialize; each resolves at its own turn's end",
    .timeLimit(.minutes(1))
)
func overlappingTurnsOnOneSessionSerializeInOrder() async throws {
    let (connection, agent) = await makeBridgeAgent(provider: singleSessionProvider())
    let sessionId = try await agent.newSession(bridgeNewSessionRequest()).sessionId
    let recorder = TurnRecorder()
    let firstGate = TurnGate()
    let secondGate = TurnGate()

    async let first = agent.serializeTurn(for: sessionId) { () -> Int in
        await recorder.record("start1")
        await firstGate.wait()
        await recorder.record("end1")
        return 1
    }
    // The first turn is running (and has published its tail) before enqueuing
    // the second, so the second is strictly behind it in the chain.
    await waitUntil(recorder, records: "start1")

    async let second = agent.serializeTurn(for: sessionId) { () -> Int in
        await recorder.record("start2")
        await secondGate.wait()
        await recorder.record("end2")
        return 2
    }
    // The second turn cannot begin while the first still holds the session.
    await Task.yield()
    #expect(await !recorder.contains("start2"))

    // Releasing the first turn lets the second begin — but only after the first ends.
    await firstGate.open()
    await waitUntil(recorder, records: "start2")
    #expect(await recorder.events() == ["start1", "end1", "start2"])
    await secondGate.open()

    let firstResult = try await first
    let secondResult = try await second
    #expect(firstResult == 1)
    #expect(secondResult == 2)
    #expect(await recorder.events() == ["start1", "end1", "start2", "end2"])
    _ = connection
}

@Test(
    "turns on distinct sessions run concurrently, not globally serialized",
    .timeLimit(.minutes(1))
)
func turnsOnDistinctSessionsRunConcurrently() async throws {
    let (connection, agent) = await makeBridgeAgent(provider: countingProvider())
    let sessionA = try await agent.newSession(bridgeNewSessionRequest()).sessionId
    let sessionB = try await agent.newSession(bridgeNewSessionRequest()).sessionId
    #expect(sessionA != sessionB)

    let recorder = TurnRecorder()
    let gate = TurnGate()

    async let turnA = agent.serializeTurn(for: sessionA) { () -> Int in
        await recorder.record("startA")
        await gate.wait()
        return 1
    }
    async let turnB = agent.serializeTurn(for: sessionB) { () -> Int in
        await recorder.record("startB")
        await gate.wait()
        return 2
    }

    // Both turns reach their start before either is released. Under global
    // serialization the second start could not occur until the first turn ended,
    // so reaching both proves serialization is per-session.
    await waitUntil(recorder, records: "startA")
    await waitUntil(recorder, records: "startB")
    await gate.open()

    _ = try await turnA
    _ = try await turnB
    _ = connection
}

@Test("a prompt for an unknown session is rejected with invalid params")
func promptForUnknownSessionThrowsInvalidParams() async throws {
    let (connection, agent) = await makeBridgeAgent(provider: singleSessionProvider())
    let unknown = PromptRequest(prompt: [], sessionId: SessionId(rawValue: "never-created"))

    await #expect(throws: RequestError.invalidParams) {
        _ = try await agent.prompt(unknown)
    }
    _ = connection
}
