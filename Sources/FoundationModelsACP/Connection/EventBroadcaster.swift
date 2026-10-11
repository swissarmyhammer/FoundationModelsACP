import Synchronization

/// Sends events to `AsyncStream` subscribers, grouped by topic, and guards a
/// context of the owner with the same lock.
///
/// `SessionUpdateRouter` and `OutgoingRequestTracker` use this type for their
/// subscriptions. Each owner keeps its own data (the kept session updates, or
/// the in-flight requests) in `Context`. The lock that guards the context
/// also guards the subscribers. Thus an owner can change its data and send
/// an event in one step, and a new subscriber can get a replay with no live
/// event before it.
///
/// A plain class guarded by a lock rather than an actor: the owners must
/// change their data and send events synchronously, with no `await` between
/// the two.
///
/// The broadcaster has two locks:
///
/// - The state lock guards the context and the subscribers. A step collects
///   its events in an outbox under this lock, and the broadcaster yields them
///   only after it releases this lock.
/// - The delivery lock is held around each step and the yields of its events.
///   Thus the subscribers get the events in step order, and no live event
///   comes before a replayed event.
///
/// The `onTermination` callback of a subscriber takes only the state lock.
/// A yield must never occur while the state lock is held: `Task.cancel()`
/// holds the task lock of a consumer while it runs `onTermination`, and a
/// yield to that consumer needs the same task lock.
///
/// The life of the broadcaster has two parts. While it is open, each
/// subscription gets the events. After `finishAll(_:)`, each stream is
/// finished, and a new subscription gets a stream that is already finished.
final class EventBroadcaster<Topic: Hashable & Sendable, Event: Sendable, Context: Sendable>: Sendable {
    /// One event for one subscriber, which the broadcaster yields after it
    /// releases the state lock.
    fileprivate typealias Delivery = (continuation: AsyncStream<Event>.Continuation, event: Event)

    /// The state that the lock guards: the context of the owner and the
    /// subscribers.
    struct State {
        /// The data of the owner.
        var context: Context

        /// Set when `finishAll(_:)` runs. A later subscription finishes at
        /// once.
        fileprivate(set) var isFinished = false

        /// The live subscriber continuations, keyed by topic and then by a
        /// token that identifies one subscriber of the topic.
        fileprivate var subscribers: [Topic: [Int: AsyncStream<Event>.Continuation]] = [:]

        /// The token of the next subscriber.
        fileprivate var nextToken = 0

        /// The events that the current step sends. The broadcaster yields
        /// them after it releases the state lock.
        fileprivate var outbox: [Delivery] = []

        /// Sends one event to each subscriber of one topic.
        ///
        /// - Parameters:
        ///   - event: The event to send.
        ///   - topic: The topic of the subscribers that get the event.
        /// - Returns: `true` when the topic has one or more subscribers, and
        ///   `false` when no subscriber got the event.
        @discardableResult
        mutating func publish(_ event: Event, to topic: Topic) -> Bool {
            guard let continuations = subscribers[topic] else { return false }
            for continuation in continuations.values {
                outbox.append((continuation, event))
            }
            return true
        }

        /// Sends one event to each subscriber of each topic.
        ///
        /// - Parameter event: The event to send.
        mutating func broadcast(_ event: Event) {
            for continuation in subscribers.values.lazy.flatMap(\.values) {
                outbox.append((continuation, event))
            }
        }

        /// Removes the events of the current step from the outbox.
        ///
        /// - Returns: The events, in the order of the step.
        fileprivate mutating func takeOutbox() -> [Delivery] {
            defer { outbox.removeAll() }
            return outbox
        }
    }

    /// The context and the subscribers.
    private let state: Mutex<State>

    /// Held around each step and the yields of its events, so that the
    /// subscribers get the events in step order. `onTermination` never takes
    /// this lock.
    private let delivery = Mutex(())

    /// Creates a broadcaster with no subscribers.
    ///
    /// - Parameter context: The initial data of the owner.
    init(context: Context) {
        state = Mutex(State(context: context))
    }

    /// Runs one step on the state under the lock.
    ///
    /// The step can read or change the context, and send events with
    /// `State.publish(_:to:)` or `State.broadcast(_:)`. The subscribers get
    /// the events after the state lock is released, before this method
    /// returns. The step runs also after `finishAll(_:)`; it reads
    /// `State.isFinished` when that matters.
    ///
    /// - Parameter body: The step to run.
    /// - Returns: The value that the step returns.
    @discardableResult
    func withState<Result: Sendable>(_ body: (inout State) -> Result) -> Result {
        delivery.withLock { _ in
            let (result, outbox) = state.withLock { state in
                let result = body(&state)
                return (result, state.takeOutbox())
            }
            Self.yield(outbox)
            return result
        }
    }

    /// Attaches a new subscriber to one topic.
    ///
    /// The replay step runs in the same delivery step as the registration.
    /// Thus no live event can come before a replayed event.
    ///
    /// - Parameters:
    ///   - topic: The topic of the subscriber.
    ///   - replay: A step that gets the context. It returns the events that
    ///     the new subscriber gets first, and an attachment value for the
    ///     caller. It does not run when the broadcaster finished.
    /// - Returns: The stream of the subscriber, and the attachment value, or
    ///   `nil` when the broadcaster finished. In that case, the stream is
    ///   already finished.
    func subscribe<Attachment: Sendable>(
        to topic: Topic,
        replay: (inout Context) -> (events: [Event], attachment: Attachment)
    ) -> (events: AsyncStream<Event>, attachment: Attachment?) {
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        guard let attached = attach(continuation, to: topic, replay: replay) else {
            continuation.finish()
            return (stream, nil)
        }
        continuation.onTermination = { [weak self] _ in
            self?.detach(token: attached.token, from: topic)
        }
        return (stream, attached.attachment)
    }

    /// Runs a last step on the state, finishes each subscriber stream, and
    /// refuses later subscriptions.
    ///
    /// The events and the finishes occur outside the state lock, so a
    /// synchronous `onTermination` callback never re-enters the lock.
    ///
    /// - Parameter finalize: The last step. It can send events, which the
    ///   subscribers get before their streams finish.
    func finishAll(_ finalize: (inout State) -> Void) {
        delivery.withLock { _ in
            let (outbox, orphaned) = state.withLock { state in
                finalize(&state)
                state.isFinished = true
                let continuations = state.subscribers.values.flatMap(\.values)
                state.subscribers.removeAll()
                return (state.takeOutbox(), continuations)
            }
            Self.yield(outbox)
            for continuation in orphaned {
                continuation.finish()
            }
        }
    }

    /// Registers a subscriber, and sends it the replay events.
    ///
    /// - Parameters:
    ///   - continuation: The continuation of the subscriber stream.
    ///   - topic: The topic of the subscriber.
    ///   - replay: The step that returns the replay events and the
    ///     attachment value.
    /// - Returns: The token of the subscriber and the attachment value, or
    ///   `nil` when the broadcaster finished.
    private func attach<Attachment: Sendable>(
        _ continuation: AsyncStream<Event>.Continuation,
        to topic: Topic,
        replay: (inout Context) -> (events: [Event], attachment: Attachment)
    ) -> (token: Int, attachment: Attachment)? {
        delivery.withLock { _ in
            let attached = state.withLock { state -> (token: Int, events: [Event], attachment: Attachment)? in
                guard !state.isFinished else { return nil }
                let token = state.nextToken
                state.nextToken += 1
                state.subscribers[topic, default: [:]][token] = continuation
                let replayed = replay(&state.context)
                return (token, replayed.events, replayed.attachment)
            }
            guard let attached else { return nil }
            for event in attached.events {
                continuation.yield(event)
            }
            return (attached.token, attached.attachment)
        }
    }

    /// Drops one subscriber when its consumer stops the iteration.
    ///
    /// This takes only the state lock, never the delivery lock. Thus it never
    /// waits for a yield.
    ///
    /// - Parameters:
    ///   - token: The token of the subscriber.
    ///   - topic: The topic of the subscriber.
    private func detach(token: Int, from topic: Topic) {
        state.withLock { state in
            state.subscribers[topic]?.removeValue(forKey: token)
            if state.subscribers[topic]?.isEmpty == true {
                state.subscribers.removeValue(forKey: topic)
            }
        }
    }

    /// Yields the events of one step, in order.
    ///
    /// The caller holds the delivery lock and does not hold the state lock.
    ///
    /// - Parameter outbox: The events to yield.
    private static func yield(_ outbox: [Delivery]) {
        for delivery in outbox {
            delivery.continuation.yield(delivery.event)
        }
    }
}
