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

/// Collects every frame from a decoded stream into an array.
private func collectFrames(
    _ stream: AsyncThrowingStream<NDJSONFrame, any Error>
) async throws -> [NDJSONFrame] {
    var received: [NDJSONFrame] = []
    for try await frame in stream {
        received.append(frame)
    }
    return received
}

/// Collects only the successfully decoded messages from a frame stream,
/// dropping malformed frames.
private func collectMessages(
    _ stream: AsyncThrowingStream<NDJSONFrame, any Error>
) async throws -> [JSONValue] {
    try await collectFrames(stream).compactMap {
        if case .message(let value) = $0 { return value }
        return nil
    }
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

extension NDJSONFrame: Equatable {
    public static func == (lhs: NDJSONFrame, rhs: NDJSONFrame) -> Bool {
        switch (lhs, rhs) {
        case (.message(let l), .message(let r)):
            return l == r
        case (.malformed(let l), .malformed(let r)):
            return l == r
        default:
            return false
        }
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

// MARK: - NDJSONCodec.decode (line -> frame)

@Test func decodeParsesEscapedSlashMethodName() throws {
    let capture = LogCapture()
    let line = Data(#"{"jsonrpc":"2.0","method":"session\/update"}"#.utf8)
    let frame = try #require(NDJSONCodec.decode(line: line, logger: capture.logger))
    #expect(frame == .message(.object(["jsonrpc": .string("2.0"), "method": .string("session/update")])))
    #expect(capture.messages.isEmpty)
}

@Test func decodeReturnsMalformedForGarbageLine() {
    let capture = LogCapture()
    let frame = NDJSONCodec.decode(line: Data("not json at all".utf8), logger: capture.logger)
    guard case .malformed(let preview) = frame else {
        Issue.record("expected a malformed frame")
        return
    }
    #expect(preview.contains("not json at all"))
    #expect(capture.messages.count == 1)
}

@Test func decodeSkipsBlankLinesSilently() {
    let capture = LogCapture()
    #expect(NDJSONCodec.decode(line: Data(), logger: capture.logger) == nil)
    #expect(NDJSONCodec.decode(line: Data("   ".utf8), logger: capture.logger) == nil)
    #expect(capture.messages.isEmpty)
}

@Test func decodeToleratesTrailingCarriageReturn() throws {
    let frame = try #require(NDJSONCodec.decode(line: Data("{\"a\":1}\r".utf8), logger: .disabled))
    #expect(frame == .message(.object(["a": .number(1)])))
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
    let frame = try #require(NDJSONCodec.decode(line: line, logger: .disabled))
    #expect(frame == .message(message))
}

// MARK: - NDJSONCodec.frames (byte stream -> frame stream)

@Test func framesReassembleAcrossEverySplitPoint() async throws {
    let wire = Data("{\"method\":\"ping\",\"emoji\":\"\u{1F389}\"}\n".utf8)
    let expected = JSONValue.object(["method": .string("ping"), "emoji": .string("\u{1F389}")])
    for split in 1..<wire.count {
        let stream = chunkStream([Data(wire.prefix(split)), Data(wire.dropFirst(split))])
        let received = try await collectMessages(stream)
        #expect(received == [expected], "split at byte \(split)")
    }
}

@Test func framesSurfaceMalformedLinesWithoutDroppingSurroundingValidOnes() async throws {
    let capture = LogCapture()
    let stream = chunkStream([Data("{\"a\":1}\n{oops\n{\"b\":2}\n".utf8)])
    let received = try await collectFrames(stream, logger: capture.logger)
    #expect(
        received == [
            .message(.object(["a": .number(1)])),
            .malformed("{oops"),
            .message(.object(["b": .number(2)])),
        ]
    )
    #expect(capture.messages.count == 1)
}

@Test func framesDeliverFinalUnterminatedLineAtEndOfStream() async throws {
    let stream = chunkStream([Data("{\"a\":1}\n{\"b\":2}".utf8)])
    let received = try await collectMessages(stream)
    #expect(received == [.object(["a": .number(1)]), .object(["b": .number(2)])])
}

@Test func framesPropagateStreamFailure() async {
    struct Boom: Error {}
    let stream = AsyncThrowingStream<Data, any Error> { continuation in
        continuation.yield(Data("{\"a\":1}\n".utf8))
        continuation.finish(throwing: Boom())
    }
    await #expect(throws: Boom.self) {
        _ = try await collectFrames(stream)
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
    let received = try await collectMessages(NDJSONCodec.frames(from: transport.bytes, logger: .disabled))
    #expect(received == [first, second])
}

// MARK: - Overloads binding the default `.disabled` logger for brevity

private func collectFrames(_ stream: AsyncThrowingStream<Data, any Error>) async throws -> [NDJSONFrame] {
    try await collectFrames(NDJSONCodec.frames(from: stream, logger: .disabled))
}

private func collectFrames(
    _ stream: AsyncThrowingStream<Data, any Error>,
    logger: ACPLogger
) async throws -> [NDJSONFrame] {
    try await collectFrames(NDJSONCodec.frames(from: stream, logger: logger))
}

private func collectMessages(_ stream: AsyncThrowingStream<Data, any Error>) async throws -> [JSONValue] {
    try await collectMessages(NDJSONCodec.frames(from: stream, logger: .disabled))
}
