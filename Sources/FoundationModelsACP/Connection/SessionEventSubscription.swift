/// One event of a session, with its place in the wire order of the whole
/// connection.
///
/// `ClientSideConnection.subscribeToAllSessions()` gives these events. The
/// ``sequence`` comes from the same counter as
/// ``ClientSideConnection/currentRequestArrival``. Thus a handler of an
/// inbound request can compare its arrival number with the sequence of the
/// events that it has applied: each event with a lower sequence came from the
/// wire before the request.
public struct SequencedSessionEvent: Hashable, Sendable {
    /// The session of the event.
    public let sessionId: SessionId

    /// The event: a `session/update` of the session, or the marker of a
    /// finished request of the client.
    public let event: SessionStreamEvent

    /// The wire sequence number of the frame that caused the event.
    ///
    /// Each frame that the connection reads gets its own number, so no two
    /// events of frames share a number, and a frame read earlier has a lower
    /// number. A request-finished marker for a response has the number of the
    /// response frame. A marker that no frame caused (a timeout, a cancelled
    /// call, a failed write, or the close of the connection) has a number
    /// above every number that the stream gave before it. That number is not a
    /// wire position.
    public let sequence: UInt64

    /// Makes a sequenced event.
    ///
    /// - Parameters:
    ///   - sessionId: The session of the event.
    ///   - event: The event.
    ///   - sequence: The wire sequence number.
    public init(sessionId: SessionId, event: SessionStreamEvent, sequence: UInt64) {
        self.sessionId = sessionId
        self.event = event
        self.sequence = sequence
    }
}

/// A subscription to the events of every session of one connection, in wire
/// order.
///
/// `ClientSideConnection.subscribeToAllSessions()` makes a subscription. The
/// first subscription gets the events that the connection kept from the start
/// of the connection, in order, and then the live events. A later
/// subscription gets only the live events.
///
/// The connection keeps the events before the first subscription only up to
/// ``SessionUpdateBufferLimits/maximumUpdatesPerSession`` events in total,
/// because a client that uses only the streams of single sessions never reads
/// this stream. When the connection discards the kept events, it puts the
/// sessions of the discarded events in ``sessionsWithMissedEvents``. It logs
/// no warning for this stream.
public struct SessionEventSubscription: Sendable {
    /// The events of all sessions: first the kept events, then the live
    /// events, in wire order. The stream finishes when the connection closes.
    /// First it gets a request-finished marker with
    /// ``OutgoingRequestOutcome/failed`` for each request of a session that
    /// did not finish.
    public let events: AsyncStream<SequencedSessionEvent>

    /// The sessions that have discarded events before this subscription was
    /// attached.
    ///
    /// For these sessions, ``events`` does not hold all of the events. The
    /// client must not trust a state that it builds only from these events.
    public let sessionsWithMissedEvents: Set<SessionId>
}
