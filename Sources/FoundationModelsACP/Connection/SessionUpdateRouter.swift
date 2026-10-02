import Foundation
import Synchronization

/// Fans `session/update` notifications out to per-session update streams.
///
/// A `ClientSideConnection` reads one multiplexed wire but exposes each
/// session's updates as its own `AsyncStream<SessionUpdate>`. This router owns
/// that demultiplexing: it correlates every notification to its `sessionId`
/// and delivers the update to every stream currently subscribed to that
/// session.
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
/// `SessionUpdateSubscription.missedUpdates`.
final class SessionUpdateRouter: Sendable {
    /// The subscriber registry, guarded for the read loop and subscribers.
    private struct Registry {
        /// Live subscriber continuations, keyed by session then by a token
        /// that distinguishes one session's concurrent subscribers.
        var subscribers: [SessionId: [Int: AsyncStream<SessionUpdate>.Continuation]] = [:]

        /// Monotonic token distinguishing one session's subscribers.
        var nextToken = 0

        /// Set once the connection closes; later subscriptions finish at once.
        var isFinished = false

        /// The updates kept for sessions that have no subscriber.
        var pending: PendingSessionUpdates
    }

    /// The registry, guarded so delivery, subscription, and shutdown are safe
    /// across the read loop and subscribing tasks.
    private let registry: Mutex<Registry>

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
        registry = Mutex(Registry(pending: PendingSessionUpdates(limits: limits)))
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
        let (stream, continuation) = AsyncStream.makeStream(of: SessionUpdate.self)
        guard let attachment = attach(continuation, to: sessionId) else {
            continuation.finish()
            return SessionUpdateSubscription(updates: stream, missedUpdates: false)
        }
        continuation.onTermination = { [weak self] _ in
            self?.removeSubscriber(sessionId: sessionId, token: attachment.token)
        }
        return SessionUpdateSubscription(updates: stream, missedUpdates: attachment.missedUpdates)
    }

    /// Delivers one notification to every subscriber of its session.
    ///
    /// A notification for a session with no active subscriber is kept for the
    /// first subscriber, up to the buffer limits. When a limit makes the
    /// router discard kept updates, the router logs a warning.
    ///
    /// - Parameter notification: The session update to route.
    func deliver(_ notification: UpdateSessionNotification) {
        let overflow = registry.withLock { registry -> PendingSessionUpdates.Overflow? in
            guard !registry.isFinished else { return nil }
            guard let subscribers = registry.subscribers[notification.sessionId] else {
                return registry.pending.keep(notification.update, for: notification.sessionId)
            }
            for continuation in subscribers.values {
                continuation.yield(notification.update)
            }
            return nil
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
        registry.withLock { registry in
            registry.pending.discard(for: sessionId)
        }
    }

    /// Finishes every subscribed stream, discards every kept update and
    /// overflow mark, and refuses future subscriptions.
    ///
    /// Called once when the connection closes (EOF, stream failure, or an
    /// explicit close), which is the signal that no further updates can arrive.
    /// Continuations are collected under the lock and finished outside it, so a
    /// synchronous `onTermination` callback never re-enters the registry lock.
    func finishAll() {
        let orphaned = registry.withLock { registry -> [AsyncStream<SessionUpdate>.Continuation] in
            registry.isFinished = true
            registry.pending.removeAll()
            let continuations = registry.subscribers.values.flatMap { $0.values }
            registry.subscribers.removeAll()
            return continuations
        }
        for continuation in orphaned {
            continuation.finish()
        }
    }

    /// Registers a subscriber and replays the kept updates of its session
    /// into it.
    ///
    /// The replay runs under the same lock as `deliver(_:)`, so no live update
    /// can come before a kept update.
    ///
    /// - Parameters:
    ///   - continuation: The continuation of the subscriber's stream.
    ///   - sessionId: The session to subscribe to.
    /// - Returns: The subscriber's registry token and the overflow mark of the
    ///   session, or `nil` when the router has finished.
    private func attach(
        _ continuation: AsyncStream<SessionUpdate>.Continuation,
        to sessionId: SessionId
    ) -> (token: Int, missedUpdates: Bool)? {
        registry.withLock { registry in
            guard !registry.isFinished else { return nil }
            let token = registry.nextToken
            registry.nextToken += 1
            registry.subscribers[sessionId, default: [:]][token] = continuation
            let kept = registry.pending.take(for: sessionId)
            for update in kept.updates {
                continuation.yield(update)
            }
            return (token, kept.missedUpdates)
        }
    }

    /// Drops one subscriber when its consumer stops iterating.
    ///
    /// - Parameters:
    ///   - sessionId: The session the subscriber belonged to.
    ///   - token: The subscriber's registry token.
    private func removeSubscriber(sessionId: SessionId, token: Int) {
        registry.withLock { registry in
            registry.subscribers[sessionId]?.removeValue(forKey: token)
            if registry.subscribers[sessionId]?.isEmpty == true {
                registry.subscribers.removeValue(forKey: sessionId)
            }
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

    /// The kept updates of each session, in arrival order.
    private var buffers: [SessionId: [SessionUpdate]] = [:]

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

    /// Keeps one update for a session, and applies the limits.
    ///
    /// When the buffer of the session is full, the store discards the buffer
    /// and the new update, and marks the session. When the update needs a new
    /// buffer and the session limit is reached, the store first discards the
    /// oldest buffer and marks its session.
    ///
    /// - Parameters:
    ///   - update: The update to keep.
    ///   - sessionId: The session of the update.
    /// - Returns: The overflow that discarded kept updates, or `nil` when
    ///   nothing was discarded.
    mutating func keep(_ update: SessionUpdate, for sessionId: SessionId) -> Overflow? {
        if let count = buffers[sessionId]?.count {
            guard count < limits.maximumUpdatesPerSession else {
                markOverflowed(sessionId)
                return .sessionFull(sessionId)
            }
            buffers[sessionId, default: []].append(update)
            return nil
        }
        let eviction = evictOldestBufferWhenFull()
        buffers[sessionId] = [update]
        bufferOrder.append(sessionId)
        return eviction
    }

    /// Removes and returns the kept updates and the overflow mark of a
    /// session.
    ///
    /// - Parameter sessionId: The session to take.
    /// - Returns: The kept updates, in order, and whether the session was
    ///   marked.
    mutating func take(for sessionId: SessionId) -> (updates: [SessionUpdate], missedUpdates: Bool) {
        let updates = removeBuffer(of: sessionId)
        let missedUpdates = overflowed.remove(sessionId) != nil
        return (updates, missedUpdates)
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
    /// - Returns: The removed updates, or an empty array when the session had
    ///   no buffer.
    private mutating func removeBuffer(of sessionId: SessionId) -> [SessionUpdate] {
        guard let updates = buffers.removeValue(forKey: sessionId) else { return [] }
        bufferOrder.removeAll { $0 == sessionId }
        return updates
    }
}
