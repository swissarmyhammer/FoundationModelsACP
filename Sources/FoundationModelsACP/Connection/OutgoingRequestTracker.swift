import Foundation
import Synchronization

/// Records the outgoing requests of one `Connection` that wait for a
/// response, and sends an `OutgoingRequestEvent` to each subscriber when a
/// request starts or finishes.
///
/// A plain class guarded by a lock rather than an actor: the lookup of an
/// in-flight method must be synchronous, and `Connection` must record a start
/// or a finish with no `await` between the change to its pending map and the
/// event. An actor hop there would let a subscriber see a response before the
/// start of its request.
///
/// `Connection` calls `start(id:method:)` and `finish(id:)` only while it is
/// open, and calls `finishAll()` one time when it closes.
final class OutgoingRequestTracker: Sendable {
    /// One request that waits for a response.
    private struct InFlightRequest {
        /// The wire method of the request.
        let method: String

        /// The start order of the request, so a new subscriber gets the
        /// in-flight requests in the order that they started.
        let sequence: Int
    }

    /// The state that the lock guards.
    private struct State {
        /// The requests that wait for a response, keyed by their wire ID.
        var inFlight: [RequestId: InFlightRequest] = [:]

        /// The sequence of the next request that starts.
        var nextSequence = 0

        /// The live subscriber continuations, keyed by a token.
        var subscribers: [Int: AsyncStream<OutgoingRequestEvent>.Continuation] = [:]

        /// The token of the next subscriber.
        var nextToken = 0

        /// Set when the connection closes. A later subscription finishes at
        /// once.
        var isFinished = false

        /// The start event of each in-flight request, in start order.
        var startEvents: [OutgoingRequestEvent] {
            inFlight
                .sorted { $0.value.sequence < $1.value.sequence }
                .map { .started(id: $0.key, method: $0.value.method) }
        }

        /// Sends one event to each subscriber.
        ///
        /// - Parameter event: The event to send.
        func broadcast(_ event: OutgoingRequestEvent) {
            for continuation in subscribers.values {
                continuation.yield(event)
            }
        }
    }

    /// The in-flight requests and the subscribers.
    private let state = Mutex(State())

    /// Records that a request started, and tells each subscriber.
    ///
    /// - Parameters:
    ///   - id: The wire ID of the request.
    ///   - method: The wire method of the request.
    func start(id: RequestId, method: String) {
        state.withLock { state in
            state.inFlight[id] = InFlightRequest(method: method, sequence: state.nextSequence)
            state.nextSequence += 1
            state.broadcast(.started(id: id, method: method))
        }
    }

    /// Records that a request finished, and tells each subscriber.
    ///
    /// - Parameter id: The wire ID of the request.
    func finish(id: RequestId) {
        state.withLock { state in
            guard state.inFlight.removeValue(forKey: id) != nil else { return }
            state.broadcast(.finished(id: id))
        }
    }

    /// Finishes each in-flight request, tells each subscriber, and then
    /// finishes each subscriber stream. Later subscriptions finish at once.
    ///
    /// The continuations are finished outside the lock, so a synchronous
    /// `onTermination` callback never re-enters the lock.
    func finishAll() {
        let orphaned = state.withLock { state -> [AsyncStream<OutgoingRequestEvent>.Continuation] in
            for case .started(let id, _) in state.startEvents {
                state.broadcast(.finished(id: id))
            }
            state.inFlight.removeAll()
            state.isFinished = true
            let continuations = Array(state.subscribers.values)
            state.subscribers.removeAll()
            return continuations
        }
        for continuation in orphaned {
            continuation.finish()
        }
    }

    /// The wire method of one in-flight request.
    ///
    /// - Parameter id: The wire ID of the request.
    /// - Returns: The wire method, or `nil` when no in-flight request has
    ///   this ID.
    func method(for id: RequestId) -> String? {
        state.withLock { $0.inFlight[id]?.method }
    }

    /// Attaches a new subscriber.
    ///
    /// The stream first gets one `started` event for each request that is in
    /// flight, in start order, and then the live events. The stream finishes
    /// when the connection closes. A subscription made after the connection
    /// closed gets a stream that is already finished.
    ///
    /// - Returns: The stream of events.
    func subscribe() -> AsyncStream<OutgoingRequestEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: OutgoingRequestEvent.self)
        guard let token = attach(continuation) else {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            self?.detach(token)
        }
        return stream
    }

    /// Registers a subscriber, and sends it the start of each in-flight
    /// request.
    ///
    /// The replay runs under the same lock as `start(id:method:)` and
    /// `finish(id:)`, so no live event can come before a replayed one.
    ///
    /// - Parameter continuation: The continuation of the subscriber stream.
    /// - Returns: The token of the subscriber, or `nil` when the connection
    ///   closed.
    private func attach(_ continuation: AsyncStream<OutgoingRequestEvent>.Continuation) -> Int? {
        state.withLock { state in
            guard !state.isFinished else { return nil }
            let token = state.nextToken
            state.nextToken += 1
            state.subscribers[token] = continuation
            for event in state.startEvents {
                continuation.yield(event)
            }
            return token
        }
    }

    /// Drops one subscriber when its consumer stops the iteration.
    ///
    /// - Parameter token: The token of the subscriber.
    private func detach(_ token: Int) {
        state.withLock { state in
            _ = state.subscribers.removeValue(forKey: token)
        }
    }
}
