/// Records the outgoing requests of one `Connection` that wait for a
/// response, and sends an `OutgoingRequestEvent` to each subscriber when a
/// request starts or finishes.
///
/// The in-flight requests are the context of an `EventBroadcaster`, so one
/// lock guards the requests and the subscribers. The lookup of an in-flight
/// method is synchronous, and `Connection` records a start or a finish with
/// no `await` between the change to its pending map and the event. An `await`
/// there would let a subscriber see a response before the start of its
/// request.
///
/// `Connection` calls `start(id:method:)` and `finish(id:)` only while it is
/// open, and calls `finishAll()` one time when it closes.
final class OutgoingRequestTracker: Sendable {
    /// The one topic of the tracker: each subscriber gets each event.
    private enum Topic {
        /// The events of all outgoing requests.
        case allRequests
    }

    /// One request that waits for a response.
    private struct InFlightRequest {
        /// The wire method of the request.
        let method: String

        /// The start order of the request, so a new subscriber gets the
        /// in-flight requests in the order that they started.
        let sequence: Int
    }

    /// The requests that wait for a response.
    private struct InFlightRequests {
        /// The requests, keyed by their wire ID.
        var requests: [RequestId: InFlightRequest] = [:]

        /// The sequence of the next request that starts.
        var nextSequence = 0

        /// The start event of each request, in start order.
        var startEvents: [OutgoingRequestEvent] {
            requests
                .sorted { $0.value.sequence < $1.value.sequence }
                .map { .started(id: $0.key, method: $0.value.method) }
        }

        /// Adds one request.
        ///
        /// - Parameters:
        ///   - id: The wire ID of the request.
        ///   - method: The wire method of the request.
        mutating func add(id: RequestId, method: String) {
            requests[id] = InFlightRequest(method: method, sequence: nextSequence)
            nextSequence += 1
        }
    }

    /// The in-flight requests and the subscribers.
    private let broadcaster = EventBroadcaster<Topic, OutgoingRequestEvent, InFlightRequests>(
        context: InFlightRequests()
    )

    /// Records that a request started, and tells each subscriber.
    ///
    /// - Parameters:
    ///   - id: The wire ID of the request.
    ///   - method: The wire method of the request.
    func start(id: RequestId, method: String) {
        broadcaster.withState { state in
            state.context.add(id: id, method: method)
            state.broadcast(.started(id: id, method: method))
        }
    }

    /// Records that a request finished, and tells each subscriber.
    ///
    /// - Parameter id: The wire ID of the request.
    func finish(id: RequestId) {
        broadcaster.withState { state in
            guard state.context.requests.removeValue(forKey: id) != nil else { return }
            state.broadcast(.finished(id: id))
        }
    }

    /// Finishes each in-flight request, tells each subscriber, and then
    /// finishes each subscriber stream. Later subscriptions finish at once.
    func finishAll() {
        broadcaster.finishAll { state in
            for case .started(let id, _) in state.context.startEvents {
                state.broadcast(.finished(id: id))
            }
            state.context.requests.removeAll()
        }
    }

    /// The wire method of one in-flight request.
    ///
    /// - Parameter id: The wire ID of the request.
    /// - Returns: The wire method, or `nil` when no in-flight request has
    ///   this ID.
    func method(for id: RequestId) -> String? {
        broadcaster.withState { $0.context.requests[id]?.method }
    }

    /// Attaches a new subscriber.
    ///
    /// The stream first gets one `started` event for each request that is in
    /// flight, in start order, and then the live events. The replay runs
    /// under the same lock as `start(id:method:)` and `finish(id:)`, so no
    /// live event can come before a replayed one. The stream finishes when
    /// the connection closes. A subscription made after the connection
    /// closed gets a stream that is already finished.
    ///
    /// - Returns: The stream of events.
    func subscribe() -> AsyncStream<OutgoingRequestEvent> {
        broadcaster.subscribe(to: .allRequests) { inFlight in
            (inFlight.startEvents, ())
        }.events
    }
}
