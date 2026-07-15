import Foundation
import Testing

import FoundationModelsACP

// MARK: - Helpers

/// Collects every framed message from a transport until its byte stream finishes.
///
/// - Parameter transport: The transport whose incoming bytes to decode.
/// - Returns: The decoded messages in arrival order.
/// - Throws: Rethrows any transport stream failure.
private func collectMessages(from transport: some ACPTransport) async throws -> [JSONValue] {
    var received: [JSONValue] = []
    for try await message in NDJSONCodec.messages(from: transport.bytes, logger: .disabled) {
        received.append(message)
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
