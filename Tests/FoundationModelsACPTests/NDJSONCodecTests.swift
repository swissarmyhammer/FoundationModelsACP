import Foundation
import Synchronization
import Testing

import FoundationModelsACP

// MARK: - Helpers

/// Thread-safe sink capturing codec diagnostics for assertions.
private final class LogCapture: Sendable {
    private let entries = Mutex<[String]>([])

    /// Every message logged so far, in order.
    var messages: [String] { entries.withLock { $0 } }

    /// A logger that appends each message to this capture.
    var logger: ACPLogger {
        ACPLogger { message in self.entries.withLock { $0.append(message) } }
    }
}

/// Builds an already-finished byte stream yielding the given chunks in order.
private func chunkStream(_ chunks: [Data]) -> AsyncThrowingStream<Data, any Error> {
    AsyncThrowingStream { continuation in
        for chunk in chunks {
            continuation.yield(chunk)
        }
        continuation.finish()
    }
}

/// Collects every message from a decoded stream into an array.
private func collect(
    _ stream: AsyncThrowingStream<JSONValue, any Error>
) async throws -> [JSONValue] {
    var received: [JSONValue] = []
    for try await value in stream {
        received.append(value)
    }
    return received
}

/// An in-memory loopback proving the `ACPTransport` surface is satisfiable:
/// writes feed the transport's own byte stream.
private struct LoopbackTransport: ACPTransport {
    let bytes: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

    init() {
        (bytes, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    }

    func write(_ data: Data) async throws {
        continuation.yield(data)
    }

    /// Signals EOF to the read side.
    func close() {
        continuation.finish()
    }
}

// MARK: - NDJSONFramer (byte-level line splitting)

@Test func framerDeliversMultipleLinesFromOneChunk() {
    var framer = NDJSONFramer()
    let lines = framer.append(Data("{\"a\":1}\n{\"b\":2}\n".utf8))
    #expect(lines == [Data("{\"a\":1}".utf8), Data("{\"b\":2}".utf8)])
}

@Test func framerRetainsTrailingPartialAcrossAppends() {
    var framer = NDJSONFramer()
    var lines = framer.append(Data("{\"a\":1}\n{\"b\"".utf8))
    #expect(lines == [Data("{\"a\":1}".utf8)])
    lines = framer.append(Data(":2}\n".utf8))
    #expect(lines == [Data("{\"b\":2}".utf8)])
}

@Test func framerFinishReturnsUnterminatedTail() {
    var framer = NDJSONFramer()
    #expect(framer.append(Data("{\"a\":1}".utf8)).isEmpty)
    #expect(framer.finish() == Data("{\"a\":1}".utf8))
    #expect(framer.finish() == nil)
}

// MARK: - NDJSONCodec.decode (line -> JSONValue)

@Test func decodeParsesEscapedSlashMethodName() throws {
    let capture = LogCapture()
    let line = Data(#"{"jsonrpc":"2.0","method":"session\/update"}"#.utf8)
    let value = try #require(NDJSONCodec.decode(line: line, logger: capture.logger))
    #expect(value == .object(["jsonrpc": .string("2.0"), "method": .string("session/update")]))
    #expect(capture.messages.isEmpty)
}

@Test func decodeLogsAndSkipsGarbageLine() {
    let capture = LogCapture()
    let value = NDJSONCodec.decode(line: Data("not json at all".utf8), logger: capture.logger)
    #expect(value == nil)
    #expect(capture.messages.count == 1)
}

@Test func decodeSkipsBlankLinesSilently() {
    let capture = LogCapture()
    #expect(NDJSONCodec.decode(line: Data(), logger: capture.logger) == nil)
    #expect(NDJSONCodec.decode(line: Data("   ".utf8), logger: capture.logger) == nil)
    #expect(capture.messages.isEmpty)
}

@Test func decodeToleratesTrailingCarriageReturn() throws {
    let value = try #require(NDJSONCodec.decode(line: Data("{\"a\":1}\r".utf8), logger: .disabled))
    #expect(value == .object(["a": .number(1)]))
}

// MARK: - NDJSONCodec.encode (message -> one line)

@Test func encodeTerminatesMessageWithSingleNewline() throws {
    let message = JSONValue.object(["text": .string("line1\nline2")])
    let data = try NDJSONCodec.encode(message)
    #expect(data.last == 0x0A)
    #expect(!data.dropLast().contains(0x0A))
}

@Test func encodeThenDecodeRoundTrips() throws {
    let message = JSONValue.object([
        "jsonrpc": .string("2.0"),
        "method": .string("session/update"),
        "params": .object(["text": .string("multi\nline \u{1F389}")]),
    ])
    var framer = NDJSONFramer()
    let lines = framer.append(try NDJSONCodec.encode(message))
    #expect(lines.count == 1)
    let line = try #require(lines.first)
    let decoded = try #require(NDJSONCodec.decode(line: line, logger: .disabled))
    #expect(decoded == message)
}

// MARK: - NDJSONCodec.messages (byte stream -> message stream)

@Test func messagesReassembleAcrossEverySplitPoint() async throws {
    let wire = Data("{\"method\":\"ping\",\"emoji\":\"\u{1F389}\"}\n".utf8)
    let expected = JSONValue.object(["method": .string("ping"), "emoji": .string("\u{1F389}")])
    for split in 1..<wire.count {
        let stream = chunkStream([Data(wire.prefix(split)), Data(wire.dropFirst(split))])
        let received = try await collect(NDJSONCodec.messages(from: stream, logger: .disabled))
        #expect(received == [expected], "split at byte \(split)")
    }
}

@Test func messagesSkipGarbageBetweenValidLines() async throws {
    let capture = LogCapture()
    let stream = chunkStream([Data("{\"a\":1}\n{oops\n{\"b\":2}\n".utf8)])
    let received = try await collect(NDJSONCodec.messages(from: stream, logger: capture.logger))
    #expect(received == [.object(["a": .number(1)]), .object(["b": .number(2)])])
    #expect(capture.messages.count == 1)
}

@Test func messagesDeliverFinalUnterminatedLineAtEndOfStream() async throws {
    let stream = chunkStream([Data("{\"a\":1}\n{\"b\":2}".utf8)])
    let received = try await collect(NDJSONCodec.messages(from: stream, logger: .disabled))
    #expect(received == [.object(["a": .number(1)]), .object(["b": .number(2)])])
}

@Test func messagesPropagateStreamFailure() async {
    struct Boom: Error {}
    let stream = AsyncThrowingStream<Data, any Error> { continuation in
        continuation.yield(Data("{\"a\":1}\n".utf8))
        continuation.finish(throwing: Boom())
    }
    await #expect(throws: Boom.self) {
        _ = try await collect(NDJSONCodec.messages(from: stream, logger: .disabled))
    }
}

// MARK: - ACPTransport (framed round trip over the abstraction)

@Test func transportRoundTripsEncodedMessages() async throws {
    let transport = LoopbackTransport()
    let first = JSONValue.object(["method": .string("initialize")])
    let second = JSONValue.object(["method": .string("session/update")])
    try await transport.write(NDJSONCodec.encode(first))
    try await transport.write(NDJSONCodec.encode(second))
    transport.close()
    let received = try await collect(NDJSONCodec.messages(from: transport.bytes, logger: .disabled))
    #expect(received == [first, second])
}
