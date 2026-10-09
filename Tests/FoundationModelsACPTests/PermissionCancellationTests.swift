import Foundation
import Synchronization
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

/// The option that `GatedPermissionClient` selects.
private let allowOption = PermissionOptionId(rawValue: "allow")

/// The outcome that the handler of `GatedPermissionClient` gives.
private let selectedOutcome = RequestPermissionOutcome.selected(SelectedPermissionOutcome(optionId: allowOption))

/// Makes the permission request that the agent sends for one session.
///
/// - Parameter sessionId: The session of the request.
/// - Returns: The permission request.
private func permissionRequest(for sessionId: SessionId) -> RequestPermissionRequest {
    RequestPermissionRequest(
        options: [PermissionOption(kind: .allowOnce, name: "Allow", optionId: allowOption)],
        sessionId: sessionId,
        title: "Permission needed"
    )
}

/// A release that each waiting task gets one time. A cancellation of a
/// waiting task does not end its wait, so a handler that waits here stands
/// for a handler that ignores cancellation.
private final class Gate: Sendable {
    /// `true` after `open()`, and the tasks that wait for it.
    private let state = Mutex<(isOpen: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    /// Releases each waiting task, and each task that waits later.
    func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Waits until `open()` runs.
    func wait() async {
        await withCheckedContinuation { continuation in
            let isOpen = state.withLock { state in
                if !state.isOpen {
                    state.waiters.append(continuation)
                }
                return state.isOpen
            }
            if isOpen {
                continuation.resume()
            }
        }
    }
}

/// A client whose `requestPermission(_:)` handler tells the test that it
/// started, waits for a gate, and then selects `allowOption`.
private struct GatedPermissionClient: Client {
    /// Gets the session of each permission request that the handler starts.
    let entered: AsyncStream<SessionId>.Continuation

    /// Gets one value for each handler that ended.
    let exited: AsyncStream<Void>.Continuation

    /// The gate that each handler waits for.
    let gate: Gate

    func sessionUpdate(_ notification: UpdateSessionNotification) async {}

    /// Waits for the gate, and then selects `allowOption`.
    ///
    /// - Parameter params: The permission request.
    /// - Returns: The `selected` outcome.
    func requestPermission(_ params: RequestPermissionRequest) async throws -> RequestPermissionResponse {
        entered.yield(params.sessionId)
        await gate.wait()
        exited.yield()
        return RequestPermissionResponse(outcome: selectedOutcome)
    }

    func createElicitation(_ params: CreateElicitationRequest) async throws -> CreateElicitationResponse {
        throw RequestError.methodNotFound("createElicitation")
    }

    func elicitationComplete(_ notification: CompleteElicitationNotification) async {}
}

/// The two ends of one test connection, and the probes of the client.
private struct PermissionHarness {
    /// The agent side, which sends `session/request_permission`.
    let agent: AgentSideConnection

    /// The client side, whose outgoing frames go to `log`.
    let client: ClientSideConnection

    /// Gets the kind of each frame that the client writes.
    let log: EventLog

    /// The gate of the permission handler.
    let gate: Gate

    /// The sessions of the permission requests that reached the handler.
    let entered: AsyncStream<SessionId>

    /// One value for each permission handler that ended.
    let exited: AsyncStream<Void>

    /// Connects a `StubAgent` to a `GatedPermissionClient` over
    /// `InMemoryTransport`.
    static func connect() async -> PermissionHarness {
        let log = EventLog()
        let gate = Gate()
        let entered = AsyncStream<SessionId>.makeStream()
        let exited = AsyncStream<Void>.makeStream()
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agent = await AgentSideConnection(stream: agentEnd) { _ in StubAgent() }
        let client = await ClientSideConnection(stream: LoggingTransport(underlying: clientEnd, log: log)) { _ in
            GatedPermissionClient(entered: entered.continuation, exited: exited.continuation, gate: gate)
        }
        return PermissionHarness(
            agent: agent, client: client, log: log, gate: gate, entered: entered.stream, exited: exited.stream
        )
    }

    /// Sends one permission request from the agent, and waits until the
    /// handler of the client started.
    ///
    /// - Parameter sessionId: The session of the request.
    /// - Returns: The task that gives the answer of the client.
    func sendPermissionRequest(for sessionId: SessionId) async throws -> Task<RequestPermissionResponse, any Error> {
        let agent = agent
        let answer = Task { try await agent.requestPermission(permissionRequest(for: sessionId)) }
        var started = entered.makeAsyncIterator()
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
        try await client.sessionCancel(CancelSessionNotification(sessionId: sessionId))
    }

    /// Opens the gate, and closes the two sides.
    func close() async {
        gate.open()
        await client.close()
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

        harness.gate.open()
        var ended = harness.exited.makeAsyncIterator()
        _ = try #require(await ended.next())
        await harness.client.close()
        _ = await harness.client.closed

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
        harness.gate.open()

        #expect(try await harness.answer(to: otherAnswer).outcome == selectedOutcome)
        await harness.close()
    }

    @Test(.timeLimit(.minutes(permissionCancellationTestTimeout)))
    func aPermissionRequestAfterTheCancelReachesTheHandler() async throws {
        let harness = await PermissionHarness.connect()
        try await harness.cancel(cancelledSession)
        harness.gate.open()

        let answer = try await harness.sendPermissionRequest(for: cancelledSession)

        #expect(try await harness.answer(to: answer).outcome == selectedOutcome)
        await harness.close()
    }
}
