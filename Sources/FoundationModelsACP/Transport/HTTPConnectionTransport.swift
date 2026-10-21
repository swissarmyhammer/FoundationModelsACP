import Foundation
import Synchronization

/// One ACP connection of an ``HTTPServerTransport``.
///
/// The server gives the host one value for each `initialize` that opens a
/// connection. The host serves it like any other transport, for example
/// with `AgentSideConnection(stream:)`. Each `POST` of the client that names
/// this connection arrives on ``bytes``; each ``write(_:)`` goes, in order,
/// to the one agent-to-client stream that the client reads with `GET`.
/// Writes before the client opens that stream wait in a buffer.
///
/// ``connectionInfo`` holds the `Acp-Connection-Id` that the server issued
/// and the bearer token of the `initialize` request. The server refuses each
/// later request with another bearer token, so the credential of the
/// connection does not change.
///
/// The connection ends when the client sends `DELETE`, when the
/// agent-to-client stream of the client closes, when the server stops, or
/// when ``close()`` runs. Then ``bytes`` finishes, ``write(_:)`` throws
/// ``ClosedError``, and the server forgets the connection id.
public final class HTTPConnectionTransport: ACPTransport {
    /// Thrown by ``write(_:)`` after the connection ended.
    public struct ClosedError: Error, Equatable {}

    /// The messages of the client, one `POST` body for each chunk.
    public let bytes: AsyncThrowingStream<Data, any Error>

    /// The id and the credential of the connection; never `nil`.
    public var connectionInfo: ACPConnectionInfo? { info }

    /// The id and the credential of the connection.
    let info: ACPConnectionInfo

    /// The agent-to-client messages, one write for each element, that the
    /// server sends on the stream of the client.
    let outgoing: AsyncStream<Data>

    /// Feeds ``bytes``.
    private let incoming: AsyncThrowingStream<Data, any Error>.Continuation

    /// Feeds ``outgoing``.
    private let outgoingInput: AsyncStream<Data>.Continuation

    /// Whether a client opened the agent-to-client stream. Only one stream
    /// reads ``outgoing``.
    private let isStreamOpen = Mutex(false)

    /// Creates an open connection.
    ///
    /// - Parameters:
    ///   - info: The id and the credential of the connection.
    ///   - onClose: Runs one time when the connection ends.
    init(info: ACPConnectionInfo, onClose: @escaping @Sendable () -> Void) {
        self.info = info
        let (bytes, incoming) = AsyncThrowingStream<Data, any Error>.makeStream()
        let (outgoing, outgoingInput) = AsyncStream<Data>.makeStream()
        // A reader of `bytes` that stops (the connection on this end
        // closed) ends the connection, as a pipe with no reader does.
        incoming.onTermination = { termination in
            if case .cancelled = termination { outgoingInput.finish() }
        }
        outgoingInput.onTermination = { _ in
            incoming.finish()
            onClose()
        }
        self.bytes = bytes
        self.incoming = incoming
        self.outgoing = outgoing
        self.outgoingInput = outgoingInput
    }

    /// Sends one chunk to the agent-to-client stream of the client.
    ///
    /// - Parameter data: The bytes to send, already framed by the caller.
    /// - Throws: ``ClosedError`` after the connection ended.
    public func write(_ data: Data) async throws {
        if case .terminated = outgoingInput.yield(data) {
            throw ClosedError()
        }
    }

    /// Ends the connection. The client stream gets each write before the
    /// end. Idempotent.
    public func close() {
        outgoingInput.finish()
    }

    /// Gives one message of the client to the connection.
    ///
    /// - Parameter body: The body of a `POST`. The method adds the newline
    ///   that ends the frame, when the body has none.
    /// - Returns: `false` when the connection ended.
    func deliver(_ body: Data) -> Bool {
        let newline = UInt8(ascii: "\n")
        var frame = body
        if frame.last != newline {
            frame.append(newline)
        }
        if case .terminated = incoming.yield(frame) {
            return false
        }
        return true
    }

    /// Opens the agent-to-client stream for one client.
    ///
    /// - Returns: `false` when a client opened it before.
    func openStream() -> Bool {
        isStreamOpen.withLock { isOpen in
            guard !isOpen else { return false }
            isOpen = true
            return true
        }
    }
}
