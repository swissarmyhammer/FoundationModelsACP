import Foundation
import Testing

import FoundationModelsACP

/// A long-lived child that stays alive until reaped: `cat` blocks reading its
/// piped stdin.
private let longLivedChild = URL(fileURLWithPath: "/bin/cat")

@Test func closingTransportReapsSpawnedChild() async throws {
    let transport = try SubprocessTransport(executableURL: longLivedChild)
    #expect(transport.isRunning)

    transport.close()

    // close() terminates and waits, so the child is collected before it returns.
    #expect(!transport.isRunning)
    #expect(transport.terminationStatus != nil)
}

@Test func closingConnectionReapsChildAgent() async throws {
    let transport = try SubprocessTransport(executableURL: TransportTestSupport.helperAgentURL)
    let client = await ClientSideConnection(stream: transport) { _ in HandshakeClient() }
    #expect(transport.isRunning)

    await client.close()

    // Closing the connection cancels its read loop, tearing down the byte
    // stream, which reaps the child — no zombie survives the connection.
    try await waitUntil(timeout: .seconds(10)) { !transport.isRunning }
    #expect(!transport.isRunning)
}
