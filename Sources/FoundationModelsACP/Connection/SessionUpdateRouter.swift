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
/// turn. A `tool_call_update` that arrives after the prompt response, or after
/// a `session/cancel`, is therefore still delivered: the turn ends via the
/// prompt response carrying `StopReason.cancelled`, but the session's stream
/// stays open and keeps accepting trailing updates. Updates for a session with
/// no active subscriber are dropped, not buffered — a consumer subscribes via
/// `updates(for:)` before driving the turn, so the drop only affects sessions
/// the host never asked about.
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
    }

    /// The registry, guarded so delivery, subscription, and shutdown are safe
    /// across the read loop and subscribing tasks.
    private let registry = Mutex(Registry())

    /// Returns a stream of updates for one session.
    ///
    /// Each call registers a fresh subscriber, so several consumers of the
    /// same session each receive every update. A subscription made after the
    /// connection has closed yields an immediately-finished stream.
    ///
    /// - Parameter sessionId: The session whose updates to observe.
    /// - Returns: A stream of that session's updates, finishing when the
    ///   connection closes.
    func updates(for sessionId: SessionId) -> AsyncStream<SessionUpdate> {
        AsyncStream { continuation in
            let token: Int? = registry.withLock { registry in
                guard !registry.isFinished else { return nil }
                let token = registry.nextToken
                registry.nextToken += 1
                registry.subscribers[sessionId, default: [:]][token] = continuation
                return token
            }
            guard let token else {
                continuation.finish()
                return
            }
            continuation.onTermination = { [weak self] _ in
                self?.removeSubscriber(sessionId: sessionId, token: token)
            }
        }
    }

    /// Delivers one notification to every subscriber of its session.
    ///
    /// A notification for a session with no active subscriber is dropped, per
    /// the straggler policy.
    ///
    /// - Parameter notification: The session update to route.
    func deliver(_ notification: SessionNotification) {
        registry.withLock { registry in
            guard let subscribers = registry.subscribers[notification.sessionId] else { return }
            for continuation in subscribers.values {
                continuation.yield(notification.update)
            }
        }
    }

    /// Finishes every subscribed stream and refuses future subscriptions.
    ///
    /// Called once when the connection closes (EOF, stream failure, or an
    /// explicit close), which is the signal that no further updates can arrive.
    /// Continuations are collected under the lock and finished outside it, so a
    /// synchronous `onTermination` callback never re-enters the registry lock.
    func finishAll() {
        let orphaned = registry.withLock { registry -> [AsyncStream<SessionUpdate>.Continuation] in
            registry.isFinished = true
            let continuations = registry.subscribers.values.flatMap { $0.values }
            registry.subscribers.removeAll()
            return continuations
        }
        for continuation in orphaned {
            continuation.finish()
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
