import Foundation
import Testing

@testable import FoundationModelsACP

/// The agent side of a connection, when a `session/cancel` from the client
/// does not decode.
///
/// The notification has no response, so the client does not learn of the
/// failure. The agent connection writes one warning to its logger and
/// continues to read.
@Suite struct SessionCancelDecodingTests {
    /// The wire method of the notification under test.
    private static let cancelMethod = "session/cancel"

    /// The params member that names the session of the cancel.
    private static let sessionIdField = "sessionId"

    /// The number that the malformed cancel sends as its session ID.
    private static let numericSessionId: Double = 7

    /// The params of a `session/cancel` whose session ID is a number. The
    /// schema requires a string, so the payload does not decode.
    private static let malformedCancelParams = JSONValue.object([
        sessionIdField: .number(numericSessionId)
    ])

    /// A well-formed cancel that the client sends after the malformed one.
    private static let laterCancel = CancelSessionNotification(sessionId: SessionId(rawValue: "session-cancel-1"))

    @Test(.timeLimit(.minutes(1)))
    func aCancelWithABadFieldTypeLogsOneWarningAndALaterCancelStillArrives() async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let log = LogCapture()
        let (cancels, cancelled) = AsyncStream<CancelSessionNotification>.makeStream()
        let agent = await AgentSideConnection(stream: agentEnd, logger: log.logger) { _ in
            StubAgent(onSessionCancel: { cancelled.yield($0) })
        }

        try await send(notificationEnvelope(method: Self.cancelMethod, params: Self.malformedCancelParams), over: clientEnd)
        try await send(
            notificationEnvelope(method: Self.cancelMethod, params: try JSONValue.encode(result: Self.laterCancel)),
            over: clientEnd
        )

        // The connection reads the notifications in wire order, so the warning
        // for the bad cancel is in the log when the later cancel arrives.
        var received = cancels.makeAsyncIterator()
        #expect(await received.next() == Self.laterCancel)
        let warnings = log.messages
        #expect(warnings.count == 1)
        let warning = try #require(warnings.first)
        #expect(warning.contains(Self.cancelMethod))
        #expect(warning.contains(Self.sessionIdField))

        await agent.close()
    }
}
