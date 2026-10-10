import Foundation
import Testing

@testable import FoundationModelsACP

// MARK: - Fixtures

/// The time limit of each test in this suite, in minutes.
private let permissionCancellationTestTimeout = 1

/// The kind that `LoggingTransport` records for a response frame.
private let responseFrame = "response"

/// The kind that `LoggingTransport` records for a frame that is not a
/// response and not a `session/update`, such as `session/cancel`.
private let notificationFrame = "other"

/// The session whose work the client cancels.
private let cancelledSession = StubAgent.sessionId

/// A session that the client does not cancel.
private let otherSession = SessionId(rawValue: "other-session")

/// The outcome that the handler of `GatedPermissionClient` gives in this
/// suite: it selects the one option of `RequestPermissionRequest.stub(for:)`.
private let selectedOutcome = RequestPermissionOutcome.selected(
    SelectedPermissionOutcome(optionId: RequestPermissionRequest.stubOptionId)
)

/// The two ends of one test connection, and the probes of the client.
private struct PermissionHarness {
    /// The agent side, which sends `session/request_permission`.
    let agent: AgentSideConnection

    /// The client side, whose outgoing frames go to `log`, and the probes of
    /// its permission handler.
    let connection: GatedPermissionConnection

    /// Gets the kind of each frame that the client writes.
    let log: EventLog

    /// Connects a `StubAgent` to a `GatedPermissionClient` over
    /// `InMemoryTransport`.
    ///
    /// - Returns: The harness.
    static func connect() async -> PermissionHarness {
        let log = EventLog()
        let connection = await GatedPermissionConnection.connect(outcome: selectedOutcome) { clientEnd in
            LoggingTransport(underlying: clientEnd, log: log)
        }
        let agent = await connection.connectStubAgent()
        return PermissionHarness(agent: agent, connection: connection, log: log)
    }

    /// Sends one permission request from the agent, and waits until the
    /// handler of the client started.
    ///
    /// - Parameter sessionId: The session of the request.
    /// - Returns: The task that gives the answer of the client.
    func sendPermissionRequest(for sessionId: SessionId) async throws -> Task<RequestPermissionResponse, any Error> {
        let agent = agent
        let answer = Task { try await agent.requestPermission(.stub(for: sessionId)) }
        var started = connection.entered.makeAsyncIterator()
        #expect(try #require(await started.next()) == sessionId)
        return answer
    }

    /// Waits for the answer of the client to one permission request.
    ///
    /// When the test is cancelled (for example, at its time limit), the wait
    /// cancels the request. Thus a missing answer fails the test, and the
    /// test does not wait forever.
    ///
    /// - Parameter request: The task that `sendPermissionRequest(for:)` gave.
    /// - Returns: The answer of the client.
    /// - Throws: Any error of the request.
    func answer(to request: Task<RequestPermissionResponse, any Error>) async throws -> RequestPermissionResponse {
        try await withTaskCancellationHandler {
            try await request.value
        } onCancel: {
            request.cancel()
        }
    }

    /// Cancels the work of one session from the client.
    ///
    /// - Parameter sessionId: The session to cancel.
    func cancel(_ sessionId: SessionId) async throws {
        try await connection.client.sessionCancel(CancelSessionNotification(sessionId: sessionId))
    }

    /// Opens the gate, and closes the two sides.
    func close() async {
        connection.gate.open()
        await connection.client.close()
        await agent.close()
    }
}

// MARK: - Tests

/// `ClientSideConnection.sessionCancel(_:)` answers each pending
/// `session/request_permission` of the session with the `cancelled` outcome.
/// It does not wait for the `Client` handler, and the connection ignores the
/// late result of the handler.
@Suite struct PermissionCancellationTests {
    @Test(.timeLimit(.minutes(permissionCancellationTestTimeout)))
    func sessionCancelAnswersAPendingPermissionRequestWithCancelled() async throws {
        let harness = await PermissionHarness.connect()
        let answer = try await harness.sendPermissionRequest(for: cancelledSession)

        try await harness.cancel(cancelledSession)

        #expect(try await harness.answer(to: answer).outcome == .cancelled)
        await harness.close()
    }

    @Test(.timeLimit(.minutes(permissionCancellationTestTimeout)))
    func theCancelNotificationIsWrittenBeforeTheCancelledAnswer() async throws {
        let harness = await PermissionHarness.connect()
        let answer = try await harness.sendPermissionRequest(for: cancelledSession)

        try await harness.cancel(cancelledSession)
        _ = try await harness.answer(to: answer)

        #expect(await harness.log.events == [notificationFrame, responseFrame])
        await harness.close()
    }

    @Test(.timeLimit(.minutes(permissionCancellationTestTimeout)))
    func theLateResultOfTheHandlerIsIgnored() async throws {
        let harness = await PermissionHarness.connect()
        let answer = try await harness.sendPermissionRequest(for: cancelledSession)
        try await harness.cancel(cancelledSession)
        _ = try await harness.answer(to: answer)

        harness.connection.gate.open()
        var ended = harness.connection.exited.makeAsyncIterator()
        _ = try #require(await ended.next())
        await harness.connection.client.close()
        _ = await harness.connection.client.closed

        #expect(await harness.log.events == [notificationFrame, responseFrame])
        await harness.agent.close()
    }

    @Test(.timeLimit(.minutes(permissionCancellationTestTimeout)))
    func aPermissionRequestOfAnotherSessionStaysWithTheHandler() async throws {
        let harness = await PermissionHarness.connect()
        let cancelledAnswer = try await harness.sendPermissionRequest(for: cancelledSession)
        let otherAnswer = try await harness.sendPermissionRequest(for: otherSession)

        try await harness.cancel(cancelledSession)
        _ = try await harness.answer(to: cancelledAnswer)
        harness.connection.gate.open()

        #expect(try await harness.answer(to: otherAnswer).outcome == selectedOutcome)
        await harness.close()
    }

    @Test(.timeLimit(.minutes(permissionCancellationTestTimeout)))
    func aPermissionRequestAfterTheCancelReachesTheHandler() async throws {
        let harness = await PermissionHarness.connect()
        try await harness.cancel(cancelledSession)
        harness.connection.gate.open()

        let answer = try await harness.sendPermissionRequest(for: cancelledSession)

        #expect(try await harness.answer(to: answer).outcome == selectedOutcome)
        await harness.close()
    }
}
