/// One outgoing request whose params name a session, and that finished.
///
/// `OutgoingRequestTracker` gives this value to its session observer.
struct FinishedSessionRequest: Hashable, Sendable {
    /// The wire ID of the request.
    let id: RequestId

    /// The wire method of the request.
    let method: String

    /// The session that the params of the request name.
    let sessionId: SessionId

    /// How the request finished.
    let outcome: OutgoingRequestOutcome
}

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
/// The tracker also calls one optional session observer, synchronously, for
/// each finished request whose params name a `sessionId`. `Connection`
/// records the finish before it resumes the caller, and, for a response from
/// the wire, in the read loop. Thus the observer runs at the position of the
/// response on the wire, before the caller continues.
///
/// `Connection` calls `start(id:method:params:)` and `finish(id:outcome:)`
/// only while it is open, and calls `finishAll()` one time when it closes.
final class OutgoingRequestTracker: Sendable {
    /// Receives each finished request whose params name a session.
    typealias SessionObserver = @Sendable (FinishedSessionRequest) -> Void

    /// The one topic of the tracker: each subscriber gets each event.
    private enum Topic {
        /// The events of all outgoing requests.
        case allRequests
    }

    /// One request that waits for a response.
    private struct InFlightRequest {
        /// The wire method of the request.
        let method: String

        /// The session that the params of the request name, or `nil` when
        /// they name no session.
        let sessionId: SessionId?

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

        /// The requests with their wire IDs, in start order.
        var inStartOrder: [(id: RequestId, request: InFlightRequest)] {
            requests
                .sorted { $0.value.sequence < $1.value.sequence }
                .map { (id: $0.key, request: $0.value) }
        }

        /// The start event of each request, in start order.
        var startEvents: [OutgoingRequestEvent] {
            inStartOrder.map { .started(id: $0.id, method: $0.request.method) }
        }

        /// Adds one request.
        ///
        /// - Parameters:
        ///   - id: The wire ID of the request.
        ///   - method: The wire method of the request.
        ///   - sessionId: The session that the params of the request name.
        mutating func add(id: RequestId, method: String, sessionId: SessionId?) {
            requests[id] = InFlightRequest(method: method, sessionId: sessionId, sequence: nextSequence)
            nextSequence += 1
        }
    }

    /// The in-flight requests and the subscribers.
    private let broadcaster = EventBroadcaster<Topic, OutgoingRequestEvent, InFlightRequests>(
        context: InFlightRequests()
    )

    /// Receives each finished request whose params name a session, or `nil`
    /// when no part of the connection needs them.
    private let sessionObserver: SessionObserver?

    /// Creates a tracker with no in-flight requests and no subscribers.
    ///
    /// - Parameter sessionObserver: Receives each finished request whose
    ///   params name a session. The tracker calls it synchronously, outside
    ///   its lock, before `finish(id:outcome:)` or `finishAll()` returns.
    init(sessionObserver: SessionObserver? = nil) {
        self.sessionObserver = sessionObserver
    }

    /// Records that a request started, and tells each subscriber.
    ///
    /// - Parameters:
    ///   - id: The wire ID of the request.
    ///   - method: The wire method of the request.
    ///   - params: The params of the request. When they are an object with a
    ///     string `sessionId` member, the tracker gives the finish of the
    ///     request to the session observer.
    func start(id: RequestId, method: String, params: JSONValue?) {
        let sessionId = SessionId(namedIn: params)
        broadcaster.withState { state in
            state.context.add(id: id, method: method, sessionId: sessionId)
            state.broadcast(.started(id: id, method: method))
        }
    }

    /// Records that a request finished, and tells each subscriber.
    ///
    /// - Parameters:
    ///   - id: The wire ID of the request.
    ///   - outcome: How the request finished.
    func finish(id: RequestId, outcome: OutgoingRequestOutcome) {
        let finished = broadcaster.withState { state -> InFlightRequest? in
            guard let request = state.context.requests.removeValue(forKey: id) else { return nil }
            state.broadcast(.finished(id: id))
            return request
        }
        guard let finished else { return }
        report(finished, id: id, outcome: outcome)
    }

    /// Finishes each in-flight request, tells each subscriber, and then
    /// finishes each subscriber stream. Later subscriptions finish at once.
    ///
    /// The session observer gets each finished session request, in start
    /// order, with ``OutgoingRequestOutcome/failed``.
    func finishAll() {
        var finished: [(id: RequestId, request: InFlightRequest)] = []
        broadcaster.finishAll { state in
            finished = state.context.inStartOrder
            for request in finished {
                state.broadcast(.finished(id: request.id))
            }
            state.context.requests.removeAll()
        }
        for request in finished {
            report(request.request, id: request.id, outcome: .failed)
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
    /// under the same lock as `start(id:method:params:)` and
    /// `finish(id:outcome:)`, so no live event can come before a replayed
    /// one. The stream finishes when the connection closes. A subscription
    /// made after the connection closed gets a stream that is already
    /// finished.
    ///
    /// - Returns: The stream of events.
    func subscribe() -> AsyncStream<OutgoingRequestEvent> {
        broadcaster.subscribe(to: .allRequests) { inFlight in
            (inFlight.startEvents, ())
        }.events
    }

    /// Gives one finished request to the session observer when the params of
    /// the request name a session.
    ///
    /// Call it outside the lock, so the observer can take a lock of its own.
    ///
    /// - Parameters:
    ///   - request: The finished request.
    ///   - id: The wire ID of the request.
    ///   - outcome: How the request finished.
    private func report(_ request: InFlightRequest, id: RequestId, outcome: OutgoingRequestOutcome) {
        guard let sessionObserver, let sessionId = request.sessionId else { return }
        sessionObserver(FinishedSessionRequest(id: id, method: request.method, sessionId: sessionId, outcome: outcome))
    }
}
