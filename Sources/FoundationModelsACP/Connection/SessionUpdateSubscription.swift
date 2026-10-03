/// A subscription to the `session/update` notifications of one session.
///
/// `ClientSideConnection.subscribe(to:)` makes a subscription. The stream of
/// the subscription holds ``SessionStreamEvent`` values: the updates of the
/// session, and a ``SessionStreamEvent/requestFinished(id:method:outcome:)``
/// marker for each request that the client sent for the session.
///
/// The first subscription to a session gets the events that the connection
/// kept for that session before a subscriber was attached, in order, and then
/// the live events. A subsequent subscription gets only the live events.
///
/// The connection keeps the events of a session only up to the limits in
/// ``SessionUpdateBufferLimits``. When the connection discards kept events,
/// it marks the session. The first subscription reads that mark in
/// ``hasMissedUpdates``, and then the connection clears the mark.
public struct SessionUpdateSubscription: Sendable {
    /// The events of the session: first the kept events, then the live
    /// events, in wire order. The stream finishes when the connection closes.
    /// When the connection closes, the stream first gets a
    /// ``SessionStreamEvent/requestFinished(id:method:outcome:)`` marker with
    /// ``OutgoingRequestOutcome/failed`` for each request of the session that
    /// did not finish, and then it finishes.
    public let updates: AsyncStream<SessionStreamEvent>

    /// Whether the connection discarded updates of this session before this
    /// subscription was attached.
    ///
    /// When this value is `true`, ``updates`` does not hold all of the updates
    /// of the session. The client must not trust a state that it builds only
    /// from these updates.
    public let hasMissedUpdates: Bool
}

/// The limits on the `session/update` notifications that a
/// `ClientSideConnection` keeps for sessions that have no subscriber.
///
/// An agent can send updates for a session before the client can subscribe
/// to that session. For example, it sends `available_commands_update` before
/// the `session/new` response that gives the session ID. The connection keeps
/// these updates until the first subscriber is attached.
///
/// The connection also keeps the
/// ``SessionStreamEvent/requestFinished(id:method:outcome:)`` markers of a
/// session that has no subscriber, in order with its updates. Each marker
/// counts as one update toward ``maximumUpdatesPerSession``.
///
/// When a session has more updates than ``maximumUpdatesPerSession``, the
/// connection discards all of the kept updates of that session. When more
/// sessions than ``maximumSessions`` have kept updates, the connection
/// discards the kept updates of the session that started to keep updates
/// first. In each case, the connection marks the session (see
/// ``SessionUpdateSubscription/hasMissedUpdates``) and logs a warning.
public struct SessionUpdateBufferLimits: Sendable {
    /// The maximum number of updates that the connection keeps for one
    /// session.
    public let maximumUpdatesPerSession: Int

    /// The maximum number of sessions for which the connection keeps updates
    /// at the same time.
    public let maximumSessions: Int

    /// Creates buffer limits.
    ///
    /// - Parameters:
    ///   - maximumUpdatesPerSession: The maximum number of updates to keep for
    ///     one session. It must be 1 or more.
    ///   - maximumSessions: The maximum number of sessions that keep updates
    ///     at the same time. It must be 1 or more.
    public init(maximumUpdatesPerSession: Int, maximumSessions: Int) {
        precondition(maximumUpdatesPerSession >= 1, "maximumUpdatesPerSession must be 1 or more")
        precondition(maximumSessions >= 1, "maximumSessions must be 1 or more")
        self.maximumUpdatesPerSession = maximumUpdatesPerSession
        self.maximumSessions = maximumSessions
    }

    /// The default limits: 1024 updates for each session, and 64 sessions.
    public static let `default` = SessionUpdateBufferLimits(
        maximumUpdatesPerSession: defaultMaximumUpdatesPerSession,
        maximumSessions: defaultMaximumSessions
    )

    /// The default number of updates that the connection keeps for one
    /// session.
    private static let defaultMaximumUpdatesPerSession = 1024

    /// The default number of sessions that keep updates at the same time.
    private static let defaultMaximumSessions = 64
}
