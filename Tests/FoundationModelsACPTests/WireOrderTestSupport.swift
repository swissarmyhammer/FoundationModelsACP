import Foundation

@testable import FoundationModelsACP

/// Records events in the order that they occur across concurrent tasks.
///
/// The ordering tests use it to compare the time of the prompt response with
/// the time of the first `session/update`. A test records an event only after
/// the real thing that the event names occurs. Thus, the scheduling of a test
/// task does not change the result.
actor EventLog {
    /// The events, in the order that the log recorded them.
    private(set) var events: [String] = []

    /// Records one event at the end of the log.
    ///
    /// - Parameter event: The name of the event.
    func record(_ event: String) {
        events.append(event)
    }

    /// Removes all events that the log has. Then the setup traffic (for
    /// example, the `session/new` round trip) is not in a measurement that
    /// starts later.
    func reset() {
        events.removeAll()
    }
}

/// Wraps an `ACPTransport`, and records the kind of each outgoing frame
/// before the real transport writes it.
///
/// A test then reads the order in which the wrapped side wrote frames to the
/// wire. This order is the only order that an ordering test examines. The
/// order in which a client continuation starts is a different scheduling
/// question.
struct LoggingTransport: ACPTransport {
    /// The real transport.
    let underlying: any ACPTransport

    /// The log that gets the kind of each outgoing frame.
    let log: EventLog

    /// The incoming bytes of the real transport.
    var bytes: AsyncThrowingStream<Data, any Error> { underlying.bytes }

    /// Records the kind of the frame, then writes the frame to the real
    /// transport.
    ///
    /// - Parameter data: The outgoing bytes.
    /// - Throws: Any error from the real transport.
    func write(_ data: Data) async throws {
        await log.record(Self.classify(data))
        try await underlying.write(data)
    }

    /// Classifies one outgoing frame as a `session/update` notification, a
    /// request response, or other traffic.
    ///
    /// A response has an `id` and no `method`. `Connection.owesResponse` uses
    /// the same test. An outbound request (for example,
    /// `session/request_permission`) also has an `id`, so the `method` check
    /// is necessary.
    ///
    /// Other test transports also use this method to classify the frames
    /// that they write.
    ///
    /// - Parameter data: The outgoing bytes of one frame.
    /// - Returns: `"update"`, `"response"`, or `"other"`.
    static func classify(_ data: Data) -> String {
        guard
            let value = try? JSONDecoder().decode(JSONValue.self, from: data),
            case .object(let fields) = value
        else {
            return "other"
        }
        if fields["method"] == .string("session/update") { return "update" }
        if fields["id"] != nil, fields["method"] == nil { return "response" }
        return "other"
    }
}
