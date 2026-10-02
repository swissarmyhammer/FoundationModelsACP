import Testing

@testable import FoundationModelsACP

/// The broadcaster that `SessionUpdateRouter` and `OutgoingRequestTracker`
/// use, tested with string topics, string events, and a context that keeps
/// the events that no subscriber got.
@Suite(.timeLimit(.minutes(1))) struct EventBroadcasterTests {
    /// A broadcaster with string topics and string events. Its context holds
    /// the events that the tests keep for the next subscriber.
    typealias Broadcaster = EventBroadcaster<String, String, [String]>

    /// The topic that each test subscribes to first.
    private static let topic = "alpha"

    /// A second topic, so a test can show that one topic does not get the
    /// events of another topic.
    private static let otherTopic = "beta"

    /// The events that the replay test keeps before the first subscriber.
    private static let keptEvents = ["kept-1", "kept-2"]

    /// Attaches a subscriber that gets the kept events of the context first.
    ///
    /// - Parameters:
    ///   - broadcaster: The broadcaster to subscribe to.
    ///   - topic: The topic of the subscriber.
    /// - Returns: The events of the subscriber, and the number of kept events
    ///   that it got, or `nil` when the broadcaster finished.
    private static func subscribeTakingKept(
        _ broadcaster: Broadcaster,
        to topic: String
    ) -> (events: AsyncStream<String>, keptCount: Int?) {
        let subscription = broadcaster.subscribe(to: topic) { kept in
            let replay = kept
            kept.removeAll()
            return (replay, replay.count)
        }
        return (subscription.events, subscription.attachment)
    }

    /// Attaches a subscriber that gets no replay.
    ///
    /// - Parameters:
    ///   - broadcaster: The broadcaster to subscribe to.
    ///   - topic: The topic of the subscriber.
    /// - Returns: The events of the subscriber.
    private static func subscribeLive(_ broadcaster: Broadcaster, to topic: String) -> AsyncStream<String> {
        broadcaster.subscribe(to: topic) { _ in ([], ()) }.events
    }

    /// Reads every event of a stream until the stream finishes.
    ///
    /// - Parameter events: The stream to read.
    /// - Returns: The events, in order.
    private static func drain(_ events: AsyncStream<String>) async -> [String] {
        var received: [String] = []
        for await event in events {
            received.append(event)
        }
        return received
    }

    @Test func publishGivesTheEventToEachSubscriberOfTheTopicOnly() async {
        let broadcaster = Broadcaster(context: [])
        let first = Self.subscribeLive(broadcaster, to: Self.topic)
        let second = Self.subscribeLive(broadcaster, to: Self.topic)
        let other = Self.subscribeLive(broadcaster, to: Self.otherTopic)

        let delivered = broadcaster.withState { $0.publish("one", to: Self.topic) }
        broadcaster.finishAll { _ in }

        #expect(delivered)
        #expect(await Self.drain(first) == ["one"])
        #expect(await Self.drain(second) == ["one"])
        #expect(await Self.drain(other).isEmpty)
    }

    @Test func publishToATopicWithNoSubscriberReturnsFalse() {
        let broadcaster = Broadcaster(context: [])
        _ = Self.subscribeLive(broadcaster, to: Self.otherTopic)

        #expect(!broadcaster.withState { $0.publish("lost", to: Self.topic) })
    }

    @Test func broadcastGivesTheEventToEachSubscriberOfEachTopic() async {
        let broadcaster = Broadcaster(context: [])
        let first = Self.subscribeLive(broadcaster, to: Self.topic)
        let other = Self.subscribeLive(broadcaster, to: Self.otherTopic)

        broadcaster.withState { $0.broadcast("everyone") }
        broadcaster.finishAll { _ in }

        #expect(await Self.drain(first) == ["everyone"])
        #expect(await Self.drain(other) == ["everyone"])
    }

    @Test func subscribeGivesTheReplayBeforeTheLiveEventsAndReturnsTheAttachment() async {
        let broadcaster = Broadcaster(context: Self.keptEvents)
        let subscription = Self.subscribeTakingKept(broadcaster, to: Self.topic)
        broadcaster.withState { $0.publish("live", to: Self.topic) }
        broadcaster.finishAll { _ in }

        #expect(subscription.keptCount == Self.keptEvents.count)
        #expect(await Self.drain(subscription.events) == Self.keptEvents + ["live"])
        #expect(broadcaster.withState { $0.context }.isEmpty)
    }

    @Test func finishAllRunsTheFinalStepThenFinishesEachStream() async {
        let broadcaster = Broadcaster(context: ["kept"])
        let events = Self.subscribeLive(broadcaster, to: Self.topic)

        broadcaster.finishAll { state in
            state.broadcast("last")
            state.context.removeAll()
        }

        #expect(await Self.drain(events) == ["last"])
        #expect(broadcaster.withState { $0.isFinished })
        #expect(broadcaster.withState { $0.context }.isEmpty)
    }

    @Test func subscribeAfterFinishAllGivesAFinishedStreamAndNoAttachment() async {
        let broadcaster = Broadcaster(context: [])
        broadcaster.finishAll { _ in }
        broadcaster.withState { $0.context = ["kept"] }

        let subscription = Self.subscribeTakingKept(broadcaster, to: Self.topic)

        #expect(subscription.keptCount == nil)
        #expect(await Self.drain(subscription.events).isEmpty)
        #expect(broadcaster.withState { $0.context } == ["kept"])
    }

    @Test func aSubscriberWhoseConsumerStopsIsRemoved() async {
        let broadcaster = Broadcaster(context: [])
        let events = Self.subscribeLive(broadcaster, to: Self.topic)

        let consumer = Task {
            var iterator = events.makeAsyncIterator()
            _ = await iterator.next()
        }
        consumer.cancel()
        await consumer.value

        #expect(!broadcaster.withState { $0.publish("after", to: Self.topic) })
    }
}
