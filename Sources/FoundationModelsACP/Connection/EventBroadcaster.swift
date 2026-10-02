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
/// The life of the broadcaster has two parts. While it is open, each
/// subscription gets the events. After `finishAll(_:)`, each stream is
/// finished, and a new subscription gets a stream that is already finished.
final class EventBroadcaster<Topic: Hashable & Sendable, Event: Sendable, Context: Sendable>: Sendable {
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

        /// Sends one event to each subscriber of one topic.
        ///
        /// - Parameters:
        ///   - event: The event to send.
        ///   - topic: The topic of the subscribers that get the event.
        /// - Returns: `true` when the topic has one or more subscribers, and
        ///   `false` when no subscriber got the event.
        @discardableResult
        func publish(_ event: Event, to topic: Topic) -> Bool {
            guard let continuations = subscribers[topic] else { return false }
            for continuation in continuations.values {
                continuation.yield(event)
            }
            return true
        }

        /// Sends one event to each subscriber of each topic.
        ///
        /// - Parameter event: The event to send.
        func broadcast(_ event: Event) {
            for continuation in subscribers.values.lazy.flatMap(\.values) {
                continuation.yield(event)
            }
        }
    }

    /// The context and the subscribers.
    private let state: Mutex<State>

    /// Creates a broadcaster with no subscribers.
    ///
    /// - Parameter context: The initial data of the owner.
    init(context: Context) {
        state = Mutex(State(context: context))
    }

    /// Runs one step on the state under the lock.
    ///
    /// The step can read or change the context, and send events with
    /// `State.publish(_:to:)` or `State.broadcast(_:)`. The step runs also
    /// after `finishAll(_:)`; it reads `State.isFinished` when that matters.
    ///
    /// - Parameter body: The step to run.
    /// - Returns: The value that the step returns.
    @discardableResult
    func withState<Result: Sendable>(_ body: (inout State) -> Result) -> Result {
        state.withLock { body(&$0) }
    }

    /// Attaches a new subscriber to one topic.
    ///
    /// The replay step runs under the same lock as `withState(_:)`. Thus no
    /// live event can come before a replayed event.
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
    /// The continuations are finished outside the lock, so a synchronous
    /// `onTermination` callback never re-enters the lock.
    ///
    /// - Parameter finalize: The last step. It can send events, which the
    ///   subscribers get before their streams finish.
    func finishAll(_ finalize: (inout State) -> Void) {
        let orphaned = state.withLock { state -> [AsyncStream<Event>.Continuation] in
            finalize(&state)
            state.isFinished = true
            let continuations = state.subscribers.values.flatMap(\.values)
            state.subscribers.removeAll()
            return continuations
        }
        for continuation in orphaned {
            continuation.finish()
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
        state.withLock { state in
            guard !state.isFinished else { return nil }
            let token = state.nextToken
            state.nextToken += 1
            state.subscribers[topic, default: [:]][token] = continuation
            let replayed = replay(&state.context)
            for event in replayed.events {
                continuation.yield(event)
            }
            return (token, replayed.attachment)
        }
    }

    /// Drops one subscriber when its consumer stops the iteration.
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
}
