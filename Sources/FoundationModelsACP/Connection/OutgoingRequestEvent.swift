/// One step in the life of a request that a connection sends to its peer.
///
/// The connection makes the JSON-RPC ID of each outgoing request. It does
/// not give the ID to the caller of a typed call such as
/// `ClientSideConnection.loginAuth(_:)`. But the peer can name that ID. For
/// example, a request-scoped elicitation names it in
/// ``ElicitationRequestScope/requestId``. These events let a client match
/// such an ID to the request that it sent, and learn when that request ends.
///
/// Each request gets exactly one ``started(id:method:)`` and then exactly one
/// ``finished(id:)``. The connection sends ``started(id:method:)`` before it
/// writes the request to the wire, so the event always comes before any
/// message from the peer that names the ID. The connection sends
/// ``finished(id:)`` before the call returns or throws. A request finishes
/// when one of these occurs:
///
/// - The peer sends a result.
/// - The peer sends an error.
/// - The caller cancels the task that waits for the response.
/// - The request timeout elapses, or the connection cannot write the request.
/// - The connection closes.
///
/// `ClientSideConnection.subscribeToOutgoingRequests()` gives a stream of
/// these events.
public enum OutgoingRequestEvent: Hashable, Sendable {
    /// The connection sent a request, and waits for its response.
    ///
    /// - Parameters:
    ///   - id: The JSON-RPC ID of the request.
    ///   - method: The wire method of the request, for example `auth/login`.
    case started(id: RequestId, method: String)

    /// The request has no further response to wait for.
    ///
    /// The event does not tell why the request finished. The caller of the
    /// request gets the result or the error.
    ///
    /// - Parameter id: The JSON-RPC ID of the request.
    case finished(id: RequestId)
}
