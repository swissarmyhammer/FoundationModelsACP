import Foundation

/// One end of an in-process bidirectional transport pair (spec §8).
///
/// `pair()` wires a `Client` and an `Agent` back-to-back in a single test —
/// no pipes, no subprocess: each end's writes surface on the other end's
/// `bytes` stream. Semantics mirror a pipe half-close: `close()` ends this
/// end's outgoing direction, finishing the peer's `bytes` stream, while the
/// opposite direction stays open until the peer closes too.
public struct InMemoryTransport: ACPTransport {
    /// Thrown by `write(_:)` once the outgoing direction is gone — either
    /// this end was closed or the peer stopped consuming.
    public struct ClosedError: Error, Equatable {}

    public let bytes: AsyncThrowingStream<Data, any Error>

    /// Feeds the peer's `bytes` stream; finished by `close()`.
    private let outgoing: AsyncThrowingStream<Data, any Error>.Continuation

    /// Creates two connected ends: whatever one writes, the other reads.
    ///
    /// - Returns: The two ends of the pair; assign either role to either end.
    public static func pair() -> (InMemoryTransport, InMemoryTransport) {
        let (firstBytes, firstContinuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let (secondBytes, secondContinuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        return (
            InMemoryTransport(bytes: firstBytes, outgoing: secondContinuation),
            InMemoryTransport(bytes: secondBytes, outgoing: firstContinuation)
        )
    }

    /// Delivers one chunk to the peer's `bytes` stream.
    ///
    /// - Parameter data: The bytes to send, already framed by the caller.
    /// - Throws: `ClosedError` if this end was closed or the peer is gone.
    public func write(_ data: Data) async throws {
        if case .terminated = outgoing.yield(data) {
            throw ClosedError()
        }
    }

    /// Closes the outgoing direction: the peer's `bytes` stream delivers any
    /// buffered chunks, then finishes. Idempotent; the incoming direction is
    /// unaffected (half-close).
    public func close() {
        outgoing.finish()
    }
}
