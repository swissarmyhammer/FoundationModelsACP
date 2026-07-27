import Foundation
import Synchronization

/// A transport that speaks ACP over this process's standard input and output.
///
/// ## stdout is sacred
///
/// The ACP wire owns stdout: an agent running over stdio must write **nothing**
/// to stdout but valid newline-delimited ACP frames. A stray `print`, a startup
/// banner, a `dotenv`-style dump, or a progress bar on stdout corrupts the
/// framing and silently drops messages — the single most common field failure
/// for stdio agents. Route every diagnostic to stderr or to the injected
/// `ACPLogger`, never to stdout. This transport prints nothing on its own; it
/// writes only the whole frames handed to `write(_:)`.
public final class StdioTransport: ACPTransport {
    /// Incoming byte chunks read from standard input, finishing at EOF.
    public let bytes: AsyncThrowingStream<Data, any Error>

    /// Serializes writes to standard output so overlapping whole-frame writes
    /// never interleave; the guarded value is the output descriptor.
    private let output: Mutex<Int32>

    /// Creates a transport bound to this process's standard input and output.
    public init() {
        bytes = ByteReader.stream(from: STDIN_FILENO)
        output = Mutex(STDOUT_FILENO)
    }

    /// Writes one whole frame to standard output as an indivisible unit.
    ///
    /// The write runs under a lock, so overlapping calls from the connection
    /// actor's reentrant methods serialize into non-interleaved frames.
    ///
    /// - Parameter data: The framed bytes to send.
    /// - Throws: `DescriptorError.writeFailed` when the descriptor rejects the bytes.
    public func write(_ data: Data) async throws {
        try output.withLock { descriptor in
            try fullWrite(descriptor, data)
        }
    }
}

/// Exposes `.stdio` as a leading-dot transport for the connection factories.
extension ACPTransport where Self == StdioTransport {
    /// A transport bound to this process's standard input and output.
    ///
    /// Enables `AgentSideConnection(stream: .stdio)`. See ``StdioTransport`` for
    /// the stdout-is-sacred discipline every stdio agent must follow.
    public static var stdio: StdioTransport { StdioTransport() }
}
