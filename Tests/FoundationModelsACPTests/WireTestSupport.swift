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

/// Steps through framed messages arriving at a raw transport end, one call
/// at a time, retaining stream position between calls.
final class WireReader {
    private var iterator: AsyncThrowingStream<JSONValue, any Error>.Iterator

    /// Creates a reader over the transport's incoming bytes.
    ///
    /// - Parameter transport: The transport end whose messages to read.
    init(_ transport: some ACPTransport) {
        iterator = NDJSONCodec.messages(from: transport.bytes, logger: .disabled)
            .makeAsyncIterator()
    }

    /// Returns the next framed message, or `nil` at EOF.
    ///
    /// - Returns: The decoded message, or `nil` when the stream finished.
    /// - Throws: Rethrows any transport stream failure.
    func next() async throws -> JSONValue? {
        try await iterator.next()
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
