import Foundation
import Synchronization
import Testing

@testable import FoundationModelsACP

/// A JSON-RPC request envelope wrapping typed params, for hand-driving the
/// helper agent over raw pipes.
private struct RequestEnvelope<Params: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: Params
}

/// The newline byte that terminates every ndJSON frame.
private let newline: UInt8 = 0x0A

@Test func agentOverStdioCompletesInitializeHandshake() async throws {
    let transport = try SubprocessTransport(executableURL: TransportTestSupport.helperAgentURL)
    let client = await ClientSideConnection(stream: transport) { _ in HandshakeClient() }

    let response = try await withTimeout(.seconds(10)) {
        try await client.initialize(InitializeRequest(protocolVersion: .latest))
    }

    #expect(response.protocolVersion == .latest)
    await client.close()
    transport.close()
}

@Test func agentStdoutIsPureNDJSONWhileLoggingToStderr() async throws {
    let process = Process()
    process.executableURL = TransportTestSupport.helperAgentURL
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()

    // Collect the child's raw stdout on a background reader so nothing blocks.
    let collected = Mutex<Data>(Data())
    let stdoutBytes = ByteReader.stream(from: stdout.fileHandleForReading.fileDescriptor)
    let collector = Task {
        for try await chunk in stdoutBytes {
            collected.withLock { $0.append(chunk) }
        }
        return collected.withLock { $0 }
    }

    let request = RequestEnvelope(
        id: 1,
        method: "initialize",
        params: InitializeRequest(protocolVersion: .latest)
    )
    try stdin.fileHandleForWriting.write(contentsOf: NDJSONCodec.encode(request))

    // Wait until a full response line has arrived, then reap the child so its
    // stdout hits EOF and the collector finishes.
    try await waitUntil(timeout: .seconds(10)) {
        collected.withLock { $0.contains(newline) }
    }
    process.terminate()
    process.waitUntilExit()

    let capturedStdout = try await withTimeout(.seconds(10)) { try await collector.value }

    // Every non-empty stdout line must be valid JSON — nothing but ACP frames.
    let lines = capturedStdout.split(separator: newline)
    #expect(!lines.isEmpty)
    var sawInitializeResponse = false
    for line in lines {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(line))
        if case .object(let fields) = value, fields["id"] == .number(1), fields["result"] != nil {
            sawInitializeResponse = true
        }
    }
    #expect(sawInitializeResponse)

    // The agent logged internally — to stderr, never stdout.
    let capturedStderr = try stderr.fileHandleForReading.readToEnd() ?? Data()
    #expect(!capturedStderr.isEmpty)
}
