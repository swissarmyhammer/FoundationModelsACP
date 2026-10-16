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

    // The request ends with the response, or with the close of the
    // connection when the child exits.
    let response: InitializeResponse
    do {
        response = try await client.initialize(handshakeInitializeRequest())
    } catch {
        await client.close()
        transport.close()
        throw error
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

    var stdoutBytes = ByteReader.stream(from: stdout.fileHandleForReading.fileDescriptor).makeAsyncIterator()
    var capturedStdout = Data()

    let request = RequestEnvelope(
        id: 1,
        method: "initialize",
        params: handshakeInitializeRequest()
    )
    do {
        try stdin.fileHandleForWriting.write(contentsOf: NDJSONCodec.encode(request))
        // Read until a full response line has arrived, or until the child's
        // stdout ends. Then reap the child, and read its stdout to the end.
        try await read(&stdoutBytes, into: &capturedStdout) { $0.contains(newline) }
        await terminateAndAwaitExit(process)
        try await read(&stdoutBytes, into: &capturedStdout) { _ in false }
    } catch {
        await terminateAndAwaitExit(process)
        throw error
    }

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

    var stdoutBytes = ByteReader.stream(from: stdout.fileHandleForReading.fileDescriptor).makeAsyncIterator()
    var collected = Data()

    do {
        // A garbage line, followed by a well-formed request: the read loop
        // must survive the first and still answer the second.
        try stdin.fileHandleForWriting.write(contentsOf: Data("not json at all\n".utf8))
        let request = RequestEnvelope(id: 1, method: "initialize", params: handshakeInitializeRequest())
        try stdin.fileHandleForWriting.write(contentsOf: NDJSONCodec.encode(request))

        // Two lines expected: the parse-error response, then the real one.
        // The read also ends when the child's stdout ends.
        try await read(&stdoutBytes, into: &collected) { data in
            data.filter { $0 == newline }.count >= 2
        }
    } catch {
        await terminateAndAwaitExit(process)
        throw error
    }
    await terminateAndAwaitExit(process)

    let lines = collected.split(separator: newline)
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
