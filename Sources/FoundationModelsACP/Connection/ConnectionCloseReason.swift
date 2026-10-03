/// Why a connection closed.
///
/// A connection closes one time. The first event that closes it sets the
/// reason, and a later event does not change it. For example, a `close()`
/// call after the end of input does not change the reason `endOfInput`.
///
/// Read the reason from `closed` on `AgentSideConnection`,
/// `ClientSideConnection` or `Connection`.
public enum ConnectionCloseReason: Sendable {
    /// The peer closed its side: the input stream of the transport finished.
    ///
    /// For a stdio agent, the client closed the standard input of the agent.
    case endOfInput

    /// The input stream of the transport failed with an error.
    ///
    /// A failed write does not close the connection. It fails only the
    /// request that the write sent.
    case transportFailed(any Error)

    /// The owner of the connection called `close()`.
    case closedLocally
}
