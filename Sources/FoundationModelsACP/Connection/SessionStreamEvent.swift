/// One event in the stream of a ``SessionUpdateSubscription``.
///
/// The stream of a session holds two kinds of event, in the order that the
/// connection read them from the wire:
///
/// - ``update(_:)``: one `session/update` notification of the session.
/// - ``requestFinished(id:method:outcome:)``: a request that the client sent
///   for the session finished.
///
/// The connection yields one ``requestFinished(id:method:outcome:)`` marker
/// for each request that `ClientSideConnection` sends whose params name a
/// `sessionId`, for example `session/resume`, `session/prompt`,
/// `session/close` and `session/set_config_option`. A request whose params
/// name no session, for example `initialize`, yields no marker.
///
/// When the agent sends a response, the connection yields the marker at the
/// position of that response on the wire: after each update that the agent
/// sent before the response, and before each update that the agent sent after
/// it. The connection yields the marker before the call returns or throws.
/// Thus, when ``ClientSideConnection/resumeSession(_:)`` returns, the marker
/// of that request is already in the stream, after the replayed updates. A
/// consumer that reads the stream in its own task knows that it applied all
/// of the replay when it reads the marker.
public enum SessionStreamEvent: Hashable, Sendable {
    /// One `session/update` notification of the session.
    ///
    /// - Parameter update: The update.
    case update(SessionUpdate)

    /// A request that the client sent for the session finished.
    ///
    /// - Parameters:
    ///   - id: The JSON-RPC ID of the request. It is the same ID as in
    ///     ``OutgoingRequestEvent/started(id:method:)``.
    ///   - method: The wire method of the request, for example
    ///     `session/resume`.
    ///   - outcome: How the request finished.
    case requestFinished(id: RequestId, method: String, outcome: OutgoingRequestOutcome)
}

/// How a request that a connection sent to its peer finished.
public enum OutgoingRequestOutcome: Hashable, Sendable {
    /// The peer sent a result.
    case succeeded

    /// The request did not get a result. The peer sent an error, the caller
    /// cancelled the task that waited for the response, the request timeout
    /// elapsed, the connection could not write the request, or the connection
    /// closed. The caller of the request gets the error.
    case failed
}
