import Foundation
import Testing

import FoundationModelsACP

// MARK: - Helpers

/// Collects every framed message from a transport until its byte stream
/// finishes, dropping any malformed frame.
///
/// - Parameter transport: The transport whose incoming bytes to decode.
/// - Returns: The decoded messages in arrival order.
/// - Throws: Rethrows any transport stream failure.
private func collectMessages(from transport: some ACPTransport) async throws -> [JSONValue] {
    var received: [JSONValue] = []
    for try await frame in NDJSONCodec.frames(from: transport.bytes, logger: .disabled) {
        if case .message(let value) = frame {
            received.append(value)
        }
    }
    return received
}

// MARK: - InMemoryTransport

@Test func pairExchangesFramedMessagesInBothDirectionsConcurrently() async throws {
    let (client, agent) = InMemoryTransport.pair()
    let clientToAgent = (0..<25).map { JSONValue.object(["method": .string("client/\($0)")]) }
    let agentToClient = (0..<25).map { JSONValue.object(["method": .string("agent/\($0)")]) }

    async let agentReceived = collectMessages(from: agent)
    async let clientReceived = collectMessages(from: client)

    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            for message in clientToAgent {
                try await client.write(NDJSONCodec.encode(message))
            }
            client.close()
        }
        group.addTask {
            for message in agentToClient {
                try await agent.write(NDJSONCodec.encode(message))
            }
            agent.close()
        }
        try await group.waitForAll()
    }

    #expect(try await agentReceived == clientToAgent)
    #expect(try await clientReceived == agentToClient)
}

@Test func closeDeliversPendingWritesThenFinishesPeerStream() async throws {
    let (a, b) = InMemoryTransport.pair()
    try await a.write(Data("{\"a\":1}\n".utf8))
    a.close()
    // Returning at all proves b's stream finished; the buffered write still arrives.
    let received = try await collectMessages(from: b)
    #expect(received == [.object(["a": .number(1)])])
}

@Test func closeLeavesOppositeDirectionOpen() async throws {
    let (a, b) = InMemoryTransport.pair()
    a.close()
    // Half-close: a can no longer send, but b -> a still works.
    try await b.write(Data("{\"b\":2}\n".utf8))
    b.close()
    let received = try await collectMessages(from: a)
    #expect(received == [.object(["b": .number(2)])])
}

@Test func writeAfterCloseThrowsClosedError() async throws {
    let (a, _) = InMemoryTransport.pair()
    a.close()
    await #expect(throws: InMemoryTransport.ClosedError.self) {
        try await a.write(Data("late".utf8))
    }
}

@Test(.timeLimit(.minutes(1))) func aReaderThatStopsEndsThePeerStream() async throws {
    let (a, b) = InMemoryTransport.pair()
    let reader = Task { try await collectMessages(from: a) }
    reader.cancel()
    _ = try? await reader.value
    // Returning at all proves b's stream finished when a's reader stopped.
    let received = try await collectMessages(from: b)
    #expect(received.isEmpty)
}

@Test(.timeLimit(.minutes(1))) func closeIsStillAHalfClose() async throws {
    let (a, b) = InMemoryTransport.pair()
    a.close()
    // b's stream finishes, but a's stream stays open: b -> a still works.
    #expect(try await collectMessages(from: b).isEmpty)
    try await b.write(Data("{\"b\":2}\n".utf8))
    b.close()
    let received = try await collectMessages(from: a)
    #expect(received == [.object(["b": .number(2)])])
}

@Test(.timeLimit(.minutes(1))) func aNormalEndDoesNotCloseTheOtherDirection() async throws {
    let (a, b) = InMemoryTransport.pair()
    b.close()
    // a's stream ends normally. That must not close the a -> b direction.
    #expect(try await collectMessages(from: a).isEmpty)
    try await a.write(Data("{\"a\":1}\n".utf8))
    a.close()
    let received = try await collectMessages(from: b)
    #expect(received == [.object(["a": .number(1)])])
}

@Test(.timeLimit(.minutes(1))) func closingTheClientConnectionEndsTheAgentConnection() async {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agent = await AgentSideConnection(stream: agentEnd) { _ in StubAgent() }
    let client = await ClientSideConnection(stream: clientEnd) { _ in HandshakeClient() }

    await client.close()

    let reason = await agent.closed
    guard case .endOfInput = reason else {
        Issue.record("expected endOfInput, got \(reason)")
        return
    }
}
