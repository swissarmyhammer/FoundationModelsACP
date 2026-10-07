import Foundation

/// One end of an in-process bidirectional transport pair (spec §8).
///
/// `pair()` wires a `Client` and an `Agent` back-to-back in a single process —
/// no pipes, no subprocess: each end's writes surface on the other end's
/// `bytes` stream. This is **production** machinery, not only a test fixture:
/// it is how a SwiftUI host runs an agent in the same process while still
/// speaking the real ACP wire, rather than reaching for an ad hoc in-process
/// API that would drift from what a subprocess agent sees.
///
/// Semantics mirror a pipe half-close: `close()` ends this end's outgoing
/// direction, finishing the peer's `bytes` stream, while the opposite
/// direction stays open until the peer closes too.
///
/// Semantics also mirror a pipe with no reader: when the reader of one end
/// stops (its `bytes` stream is cancelled, for example because a connection
/// on that end closed), the outgoing direction of that end finishes too, so
/// the peer's `bytes` stream ends. A normal end of `bytes` (the peer closed)
/// does not do this.
public struct InMemoryTransport: ACPTransport {
    /// Thrown by `write(_:)` once the outgoing direction is gone — either
    /// this end was closed or the peer stopped consuming.
    public struct ClosedError: Error, Equatable {}

    /// Incoming chunks written by the peer, finishing when the peer closes
    /// its outgoing direction.
    public let bytes: AsyncThrowingStream<Data, any Error>

    /// Feeds the peer's `bytes` stream; finished by `close()`.
    private let outgoing: AsyncThrowingStream<Data, any Error>.Continuation

    /// Creates two connected ends: whatever one writes, the other reads.
    ///
    /// When the reader of one end is cancelled, the outgoing direction of
    /// that end finishes, and the `bytes` stream of the other end ends. Only
    /// cancellation does this; a normal finish keeps the half-close.
    ///
    /// - Returns: The two ends of the pair; assign either role to either end.
    public static func pair() -> (InMemoryTransport, InMemoryTransport) {
        let (firstBytes, firstContinuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let (secondBytes, secondContinuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        // The first end reads firstBytes and writes through secondContinuation.
        firstContinuation.onTermination = { termination in
            if case .cancelled = termination { secondContinuation.finish() }
        }
        secondContinuation.onTermination = { termination in
            if case .cancelled = termination { firstContinuation.finish() }
        }
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
