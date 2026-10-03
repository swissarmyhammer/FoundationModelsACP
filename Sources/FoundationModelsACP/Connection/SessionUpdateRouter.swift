import Foundation

/// Fans `session/update` notifications out to per-session update streams.
///
/// A `ClientSideConnection` reads one multiplexed wire but exposes each
/// session's updates as its own `AsyncStream<SessionStreamEvent>`. This router
/// owns that demultiplexing: it correlates every notification to its
/// `sessionId` and delivers the update to every stream currently subscribed
/// to that session.
///
/// The router also delivers a request-finished marker for each request of
/// the client whose params name a session. `OutgoingRequestTracker` gives the
/// marker to the router at the wire position of the response, so the marker
/// is in order with the updates of the session.
///
/// Straggler policy (spec §5). A stream's lifetime runs from subscription
/// until the connection closes — deliberately *independent* of any prompt
/// turn. A `tool_call_update` that arrives after the prompt acknowledgement,
/// or after a `session/cancel`, is therefore still delivered: the turn's
/// progress and completion are reported by `state_update` notifications, not
/// by the prompt call returning, and the session's stream stays open and
/// keeps accepting trailing updates.
///
/// Buffer policy. The router keeps the updates of a session that has no
/// subscriber, in order, up to the `SessionUpdateBufferLimits`. An agent can
/// send updates for a new session before the `session/new` response gives the
/// client the session ID, so the client cannot subscribe in time. The first
/// subscriber gets the kept updates first, then the live updates. When the
/// router discards kept updates because of a limit, it marks the session and
/// logs a warning; the first subscriber reads the mark as
/// `SessionUpdateSubscription.hasMissedUpdates`.
///
/// The subscribers of each session and the kept updates are in one
/// `EventBroadcaster`, keyed by session, so one lock guards both.
final class SessionUpdateRouter: Sendable {
    /// The subscribers of each session, and the kept updates as the context,
    /// guarded so delivery, subscription, and shutdown are safe across the
    /// read loop and subscribing tasks.
    private let broadcaster: EventBroadcaster<SessionId, SessionStreamEvent, PendingSessionUpdates>

    /// The limits on the updates kept for sessions with no subscriber.
    private let limits: SessionUpdateBufferLimits

    /// The sink for the warning that the router logs when it discards kept
    /// updates.
    private let logger: ACPLogger

    /// Creates a router with no subscribers and no kept updates.
    ///
    /// - Parameters:
    ///   - limits: The limits on the updates kept for sessions with no
    ///     subscriber.
    ///   - logger: The sink for the warning that the router logs when it
    ///     discards kept updates.
    init(limits: SessionUpdateBufferLimits = .default, logger: ACPLogger = .disabled) {
        self.limits = limits
        self.logger = logger
        broadcaster = EventBroadcaster(context: PendingSessionUpdates(limits: limits))
    }

    /// Attaches a new subscriber to one session.
    ///
    /// Each call registers a fresh subscriber, so several consumers of the
    /// same session each receive every live update. The first subscriber also
    /// gets the kept updates and the overflow mark of the session, and then
    /// the router clears both. A subscription made after the connection has
    /// closed yields an immediately-finished stream.
    ///
    /// - Parameter sessionId: The session whose updates to observe.
    /// - Returns: The subscription. Its stream finishes when the connection
    ///   closes.
    func subscribe(to sessionId: SessionId) -> SessionUpdateSubscription {
        let subscription = broadcaster.subscribe(to: sessionId) { pending in
            let kept = pending.take(for: sessionId)
            return (kept.events, kept.hasMissedUpdates)
        }
        return SessionUpdateSubscription(
            updates: subscription.events,
            hasMissedUpdates: subscription.attachment ?? false
        )
    }

    /// Delivers one notification to every subscriber of its session.
    ///
    /// A notification for a session with no active subscriber is kept for the
    /// first subscriber, up to the buffer limits. When a limit makes the
    /// router discard kept updates, the router logs a warning.
    ///
    /// - Parameter notification: The session update to route.
    func deliver(_ notification: UpdateSessionNotification) {
        deliver(.update(notification.update), for: notification.sessionId)
    }

    /// Delivers the marker of one finished session request to every
    /// subscriber of its session.
    ///
    /// A marker for a session with no active subscriber is kept for the first
    /// subscriber, in order with the kept updates, and counts as one update
    /// toward the buffer limits.
    ///
    /// - Parameter finished: The finished request.
    func deliver(_ finished: FinishedSessionRequest) {
        deliver(
            .requestFinished(id: finished.id, method: finished.method, outcome: finished.outcome),
            for: finished.sessionId
        )
    }

    /// Delivers one event to every subscriber of a session, or keeps it for
    /// the first subscriber.
    ///
    /// - Parameters:
    ///   - event: The event to deliver.
    ///   - sessionId: The session of the event.
    private func deliver(_ event: SessionStreamEvent, for sessionId: SessionId) {
        let overflow = broadcaster.withState { state -> PendingSessionUpdates.Overflow? in
            guard !state.isFinished else { return nil }
            guard !state.publish(event, to: sessionId) else { return nil }
            return state.context.keep(event, for: sessionId)
        }
        if let overflow {
            logger.log(overflow.warning(limits: limits))
        }
    }

    /// Discards the kept updates and the overflow mark of one session.
    ///
    /// The connection calls this when the client closes the session, because
    /// no subscriber will need them.
    ///
    /// - Parameter sessionId: The session whose kept updates to discard.
    func discardPendingUpdates(for sessionId: SessionId) {
        broadcaster.withState { state in
            state.context.discard(for: sessionId)
        }
    }

    /// Finishes every subscribed stream, discards every kept update and
    /// overflow mark, and refuses future subscriptions.
    ///
    /// Called once when the connection closes (EOF, stream failure, or an
    /// explicit close), which is the signal that no further updates can arrive.
    func finishAll() {
        broadcaster.finishAll { state in
            state.context.removeAll()
        }
    }
}

/// The updates kept for sessions that have no subscriber, and the overflow
/// marks of sessions whose kept updates were discarded.
///
/// An overflow mark is only a session ID, and it stays until a subscriber
/// takes it, the client closes the session, or the connection closes.
struct PendingSessionUpdates {
    /// The reason that kept updates were discarded.
    enum Overflow {
        /// The session had more updates than the per-session limit.
        case sessionFull(SessionId)

        /// More sessions than the session limit had kept updates, and this
        /// session was the oldest.
        case oldestSessionEvicted(SessionId)

        /// The warning to log for this overflow.
        ///
        /// - Parameter limits: The limits that caused the overflow.
        /// - Returns: The warning text.
        func warning(limits: SessionUpdateBufferLimits) -> String {
            switch self {
            case .sessionFull(let sessionId):
                return "Discarded the kept session/update notifications of session \(sessionId.rawValue): "
                    + "it has more than \(limits.maximumUpdatesPerSession) updates and no subscriber."
            case .oldestSessionEvicted(let sessionId):
                return "Discarded the kept session/update notifications of session \(sessionId.rawValue): "
                    + "more than \(limits.maximumSessions) sessions have kept updates, "
                    + "and this session is the oldest."
            }
        }
    }

    /// The limits on the kept updates.
    private let limits: SessionUpdateBufferLimits

    /// The kept events of each session, in arrival order. Each event counts
    /// as one update toward the per-session limit: an update, and also a
    /// request-finished marker.
    private var buffers: [SessionId: [SessionStreamEvent]] = [:]

    /// The sessions in `buffers`, from the oldest buffer to the newest.
    private var bufferOrder: [SessionId] = []

    /// The sessions whose kept updates were discarded.
    private var overflowed: Set<SessionId> = []

    /// Creates an empty store.
    ///
    /// - Parameter limits: The limits on the kept updates.
    init(limits: SessionUpdateBufferLimits) {
        self.limits = limits
    }

    /// Keeps one event for a session, and applies the limits.
    ///
    /// When the buffer of the session is full, the store discards the buffer
    /// and the new event, and marks the session. When the event needs a new
    /// buffer and the session limit is reached, the store first discards the
    /// oldest buffer and marks its session.
    ///
    /// - Parameters:
    ///   - event: The event to keep: an update or a request-finished marker.
    ///   - sessionId: The session of the event.
    /// - Returns: The overflow that discarded kept events, or `nil` when
    ///   nothing was discarded.
    mutating func keep(_ event: SessionStreamEvent, for sessionId: SessionId) -> Overflow? {
        if let count = buffers[sessionId]?.count {
            guard count < limits.maximumUpdatesPerSession else {
                markOverflowed(sessionId)
                return .sessionFull(sessionId)
            }
            buffers[sessionId, default: []].append(event)
            return nil
        }
        let eviction = evictOldestBufferWhenFull()
        buffers[sessionId] = [event]
        bufferOrder.append(sessionId)
        return eviction
    }

    /// Removes and returns the kept events and the overflow mark of a
    /// session.
    ///
    /// - Parameter sessionId: The session to take.
    /// - Returns: The kept events, in order, and whether the session was
    ///   marked.
    mutating func take(for sessionId: SessionId) -> (events: [SessionStreamEvent], hasMissedUpdates: Bool) {
        let events = removeBuffer(of: sessionId)
        let hasMissedUpdates = overflowed.remove(sessionId) != nil
        return (events, hasMissedUpdates)
    }

    /// Discards the kept updates and the overflow mark of a session.
    ///
    /// - Parameter sessionId: The session to discard.
    mutating func discard(for sessionId: SessionId) {
        _ = take(for: sessionId)
    }

    /// Discards every kept update and every overflow mark.
    mutating func removeAll() {
        buffers.removeAll()
        bufferOrder.removeAll()
        overflowed.removeAll()
    }

    /// Discards the oldest buffer when the session limit is reached.
    ///
    /// - Returns: The eviction, or `nil` when the limit is not reached.
    private mutating func evictOldestBufferWhenFull() -> Overflow? {
        guard bufferOrder.count >= limits.maximumSessions, let oldest = bufferOrder.first else {
            return nil
        }
        markOverflowed(oldest)
        return .oldestSessionEvicted(oldest)
    }

    /// Discards the buffer of a session and marks the session.
    ///
    /// - Parameter sessionId: The session to mark.
    private mutating func markOverflowed(_ sessionId: SessionId) {
        _ = removeBuffer(of: sessionId)
        overflowed.insert(sessionId)
    }

    /// Removes the buffer of a session.
    ///
    /// - Parameter sessionId: The session whose buffer to remove.
    /// - Returns: The removed events, or an empty array when the session had
    ///   no buffer.
    private mutating func removeBuffer(of sessionId: SessionId) -> [SessionStreamEvent] {
        guard let events = buffers.removeValue(forKey: sessionId) else { return [] }
        bufferOrder.removeAll { $0 == sessionId }
        return events
    }
}
