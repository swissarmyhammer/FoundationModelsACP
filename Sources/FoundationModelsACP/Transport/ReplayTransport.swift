import Foundation
import Synchronization

/// Replays a recorded client→agent ndJSON script and captures every write
/// for assertion (spec §8).
///
/// The recording format is the raw ndJSON byte stream: tee the wire while a
/// live session runs and the capture is a replayable script. `bytes` feeds
/// the script one line per chunk (newline included) and finishes when the
/// script runs out; everything written back accumulates in `capturedOutput`
/// so a test can compare the emitted stream against a golden fixture.
/// Replay is deterministic: same script in, same chunks out, writes captured
/// byte-for-byte in order.
public final class ReplayTransport: ACPTransport {
    /// The replayed script, delivered one line per chunk (newline included)
    /// and finishing once the script is exhausted.
    public let bytes: AsyncThrowingStream<Data, any Error>

    /// Everything written so far, guarded for concurrent writers.
    private let captured = Mutex<Data>(Data())

    /// Creates a transport that replays `script` and captures all writes.
    ///
    /// - Parameter script: The recorded client→agent bytes, newline-delimited.
    ///   Each line (with its `\n`) becomes one chunk; an unterminated final
    ///   line is fed as-is.
    public init(script: Data) {
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        var start = script.startIndex
        while let newline = script[start...].firstIndex(of: 0x0A) {
            continuation.yield(Data(script[start...newline]))
            start = script.index(after: newline)
        }
        if start < script.endIndex {
            continuation.yield(Data(script[start...]))
        }
        continuation.finish()
        self.bytes = stream
    }

    /// Appends one outgoing chunk to the capture.
    ///
    /// - Parameter data: The bytes the peer-under-test emitted.
    public func write(_ data: Data) async throws {
        captured.withLock { $0.append(data) }
    }

    /// The raw ndJSON byte stream written so far, in write order — the same
    /// format as the script, so captures can be committed as golden fixtures.
    public var capturedOutput: Data {
        captured.withLock { $0 }
    }
}
