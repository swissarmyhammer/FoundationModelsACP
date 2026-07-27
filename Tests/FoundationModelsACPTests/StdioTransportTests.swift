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
        try await client.initialize(handshakeInitializeRequest())
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
        params: handshakeInitializeRequest()
    )
    try stdin.fileHandleForWriting.write(contentsOf: NDJSONCodec.encode(request))

    // Wait until a full response line has arrived, then reap the child so its
    // stdout hits EOF and the collector finishes.
    try await waitUntil(timeout: .seconds(10)) {
        collected.withLock { $0.contains(newline) }
    }
    await terminateAndAwaitExit(process)

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

@Test func malformedFrameOverStdioGetsACleanParseErrorNotACrash() async throws {
    let process = Process()
    process.executableURL = TransportTestSupport.helperAgentURL
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()

    let collected = Mutex<Data>(Data())
    let stdoutBytes = ByteReader.stream(from: stdout.fileHandleForReading.fileDescriptor)
    let collector = Task {
        for try await chunk in stdoutBytes {
            collected.withLock { $0.append(chunk) }
        }
    }

    // A garbage line, followed by a well-formed request: the read loop must
    // survive the first and still answer the second.
    try stdin.fileHandleForWriting.write(contentsOf: Data("not json at all\n".utf8))
    let request = RequestEnvelope(id: 1, method: "initialize", params: handshakeInitializeRequest())
    try stdin.fileHandleForWriting.write(contentsOf: NDJSONCodec.encode(request))

    try await waitUntil(timeout: .seconds(10)) {
        collected.withLock { data in
            // Two lines expected: the parse-error response, then the real one.
            data.filter { $0 == newline }.count >= 2
        }
    }
    await terminateAndAwaitExit(process)
    collector.cancel()

    let lines = collected.withLock { $0 }.split(separator: newline)
    #expect(lines.count == 2)

    let parseErrorLine = try JSONDecoder().decode(JSONValue.self, from: Data(lines[0]))
    guard case .object(let fields) = parseErrorLine, case .object(let error) = fields["error"] ?? .null else {
        Issue.record("expected a parse-error envelope")
        return
    }
    #expect(fields["id"] == .null)
    #expect(error["code"] == .number(-32700))

    let responseLine = try JSONDecoder().decode(JSONValue.self, from: Data(lines[1]))
    guard case .object(let responseFields) = responseLine else {
        Issue.record("expected the initialize response")
        return
    }
    #expect(responseFields["id"] == .number(1))
    #expect(responseFields["result"] != nil)
}
