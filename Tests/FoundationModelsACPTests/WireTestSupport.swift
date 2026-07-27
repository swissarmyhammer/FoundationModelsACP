import Foundation

import FoundationModelsACP

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

/// Extracts the `id` field from a JSON-RPC envelope.
///
/// - Parameter message: The envelope to inspect, or `nil`.
/// - Returns: The `id` value, or `nil` when absent or not an object.
func requestID(of message: JSONValue?) -> JSONValue? {
    guard case .object(let fields) = message ?? .null else { return nil }
    return fields["id"]
}
