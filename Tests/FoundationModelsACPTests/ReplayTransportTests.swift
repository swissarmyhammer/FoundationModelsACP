import Foundation
import Testing

import FoundationModelsACP

// MARK: - Fixtures

/// The `Fixtures/` directory next to this test file.
private let fixturesDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // ReplayTransportTests.swift
    .appendingPathComponent("Fixtures")

/// Loads a recorded ndJSON fixture byte-for-byte.
///
/// - Parameter name: File name inside `Fixtures/`.
/// - Returns: The raw fixture bytes.
/// - Throws: An error if the fixture is missing or unreadable.
private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: fixturesDirectory.appendingPathComponent(name))
}

/// Collects every chunk from a byte stream until it finishes.
///
/// - Parameter stream: The stream to drain.
/// - Returns: The chunks in delivery order.
/// - Throws: Rethrows any stream failure.
private func collectChunks(
    _ stream: AsyncThrowingStream<Data, any Error>
) async throws -> [Data] {
    var chunks: [Data] = []
    for try await chunk in stream {
        chunks.append(chunk)
    }
    return chunks
}

// MARK: - ReplayTransport

@Test func scriptIsFedLineByLineThenStreamFinishes() async throws {
    let transport = ReplayTransport(script: Data("{\"a\":1}\n{\"b\":2}\n".utf8))
    // Returning at all proves the stream finished after the script ran out.
    let chunks = try await collectChunks(transport.bytes)
    #expect(chunks == [Data("{\"a\":1}\n".utf8), Data("{\"b\":2}\n".utf8)])
}

@Test func unterminatedFinalScriptLineIsFedAsIs() async throws {
    let transport = ReplayTransport(script: Data("{\"a\":1}\n{\"b\":2}".utf8))
    let chunks = try await collectChunks(transport.bytes)
    #expect(chunks == [Data("{\"a\":1}\n".utf8), Data("{\"b\":2}".utf8)])
}

@Test func emptyScriptFinishesImmediately() async throws {
    let transport = ReplayTransport(script: Data())
    let chunks = try await collectChunks(transport.bytes)
    #expect(chunks.isEmpty)
}

@Test func writesAccumulateAsRawNDJSONInOrder() async throws {
    let transport = ReplayTransport(script: Data())
    #expect(transport.capturedOutput.isEmpty)
    try await transport.write(Data("{\"x\":1}\n".utf8))
    try await transport.write(Data("{\"y\":2}\n".utf8))
    #expect(transport.capturedOutput == Data("{\"x\":1}\n{\"y\":2}\n".utf8))
}

@Test func replayedFixtureCapturesEmissionsMatchingGoldenFile() async throws {
    let transport = ReplayTransport(script: try fixture("replay-script.ndjson"))
    // A toy agent loop: decode each scripted client message and emit one
    // deterministic response per message through the codec's encoder.
    for try await message in NDJSONCodec.messages(from: transport.bytes, logger: .disabled) {
        guard case .object(let fields) = message,
            let id = fields["id"],
            case .string(let method) = fields["method", default: .null]
        else {
            Issue.record("script message missing id/method: \(message)")
            continue
        }
        let response = JSONValue.object([
            "id": id,
            "result": .object(["echoedMethod": .string(method)]),
        ])
        try await transport.write(NDJSONCodec.encode(response))
    }
    #expect(transport.capturedOutput == (try fixture("replay-golden.ndjson")))
}
