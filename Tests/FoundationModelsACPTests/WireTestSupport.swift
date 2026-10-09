import Foundation
import Synchronization

@testable import FoundationModelsACP

// MARK: - Diagnostic capture

/// A thread-safe sink that keeps diagnostics for assertions.
final class LogCapture: Sendable {
    /// The logged messages, guarded for the logging tasks.
    private let entries = Mutex<[String]>([])

    /// Every message logged so far, in order.
    var messages: [String] { entries.withLock { $0 } }

    /// A logger that appends each message to this capture.
    var logger: ACPLogger {
        ACPLogger { message in self.entries.withLock { $0.append(message) } }
    }
}

// MARK: - Raw-wire helpers shared by ConnectionTests and DisconnectTests

/// Sends one framed JSON message over a raw transport end.
///
/// - Parameters:
///   - message: The JSON value to frame and write.
///   - transport: The transport end to write to.
/// - Throws: Rethrows encoding or transport-write failures.
func send(_ message: JSONValue, over transport: some ACPTransport) async throws {
    try await transport.write(NDJSONCodec.encode(message))
}

/// Sends one raw, already-framed line over a transport end — for tests that
/// need to put genuinely malformed bytes on the wire, which `send(_:over:)`
/// cannot express since it always encodes valid JSON.
///
/// - Parameters:
///   - line: The line payload, without its trailing newline.
///   - transport: The transport end to write to.
/// - Throws: Rethrows the transport-write failure.
func sendRawLine(_ line: String, over transport: some ACPTransport) async throws {
    try await transport.write(Data((line + "\n").utf8))
}

/// Frames a `session/update` notification as a JSON-RPC envelope for the wire.
///
/// - Parameter notification: The notification to send.
/// - Returns: The envelope value ready to write over a transport.
/// - Throws: Rethrows any encoding failure.
func sessionUpdateEnvelope(_ notification: UpdateSessionNotification) throws -> JSONValue {
    sessionUpdateEnvelope(params: try JSONValue.encode(result: notification))
}

/// Frames raw `session/update` params as a JSON-RPC envelope for the wire.
///
/// Use this to send params that the notification model cannot encode, for
/// example a payload with a field of the wrong type.
///
/// - Parameter params: The raw notification params.
/// - Returns: The envelope value ready to write over a transport.
func sessionUpdateEnvelope(params: JSONValue) -> JSONValue {
    .object([
        "jsonrpc": .string("2.0"),
        "method": .string("session/update"),
        "params": params,
    ])
}

/// Frames a JSON-RPC success response keyed to a request id.
///
/// - Parameters:
///   - id: The request's wire id, echoed on the response.
///   - result: The response model to send as the result.
/// - Returns: The response envelope ready to write over a transport.
/// - Throws: Rethrows any encoding failure.
func responseEnvelope(id: JSONValue, result: some Encodable) throws -> JSONValue {
    .object([
        "jsonrpc": .string("2.0"),
        "id": id,
        "result": try JSONValue.encode(result: result),
    ])
}

/// Frames a JSON-RPC error response keyed to a request id.
///
/// - Parameters:
///   - id: The request's wire id, echoed on the response.
///   - error: The error to send.
/// - Returns: The response envelope ready to write over a transport.
func errorEnvelope(id: JSONValue, error: RequestError) -> JSONValue {
    .object([
        "jsonrpc": .string("2.0"),
        "id": id,
        "error": error.wireValue,
    ])
}

/// Transport stub whose incoming stream and outgoing writes are both driven
/// by the test: feed `bytes` via its continuation, observe writes on `written`.
struct ScriptedTransport: ACPTransport {
    let bytes: AsyncThrowingStream<Data, any Error>
    let written: AsyncStream<Data>.Continuation

    /// Records the outgoing chunk for the test to observe; never fails.
    ///
    /// - Parameter data: The framed bytes the connection wrote.
    func write(_ data: Data) async throws {
        written.yield(data)
    }
}

/// Steps through framed messages arriving at a raw transport end, one call
/// at a time, retaining stream position between calls. Malformed frames are
/// skipped — tests that care about them read `NDJSONCodec.frames` directly.
final class WireReader {
    private var iterator: AsyncThrowingStream<NDJSONFrame, any Error>.Iterator

    /// Creates a reader over the transport's incoming bytes.
    ///
    /// - Parameter transport: The transport end whose messages to read.
    init(_ transport: some ACPTransport) {
        iterator = NDJSONCodec.frames(from: transport.bytes, logger: .disabled)
            .makeAsyncIterator()
    }

    /// Returns the next framed message, or `nil` at EOF.
    ///
    /// - Returns: The decoded message, or `nil` when the stream finished.
    /// - Throws: Rethrows any transport stream failure.
    func next() async throws -> JSONValue? {
        while let frame = try await iterator.next() {
            if case .message(let value) = frame {
                return value
            }
        }
        return nil
    }
}

// MARK: - Session stream helpers

extension AsyncStream.Iterator where Element == SessionStreamEvent {
    /// Reads the next update of a session stream, and skips each
    /// request-finished marker before it.
    ///
    /// - Returns: The next update, or `nil` when the stream finished.
    mutating func nextUpdate() async -> SessionUpdate? {
        while let event = await next() {
            if case .update(let update) = event {
                return update
            }
        }
        return nil
    }
}

/// Extracts the `id` field from a JSON-RPC envelope.
///
/// - Parameter message: The envelope to inspect, or `nil`.
/// - Returns: The `id` value, or `nil` when absent or not an object.
func requestID(of message: JSONValue?) -> JSONValue? {
    guard case .object(let fields) = message ?? .null else { return nil }
    return fields["id"]
}
