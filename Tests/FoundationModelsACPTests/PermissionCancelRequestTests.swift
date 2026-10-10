import Foundation
import Testing

@testable import FoundationModelsACP

// MARK: - Fixtures

/// The time limit of each test in this suite, in minutes.
private let cancelRequestTestTimeout = 1

/// The session of the permission request.
private let permissionSession = SessionId(rawValue: "cancel-request-session")

/// The wire id of the `session/request_permission` request.
private let permissionRequestId: JSONValue = .number(1)

/// The number of the probe request.
private let probeRequestNumber: Double = 2

/// The wire id of the probe request. The answer to the probe proves that no
/// frame came before it.
private let probeRequestId: JSONValue = .number(probeRequestNumber)

/// A wire method that no `Client` handler serves. The client answers it at
/// once with `-32601`.
private let probeMethod = "test/probe"

/// The wire method of `session/request_permission`.
private let requestPermissionMethod = RoleRouting.wireMethod(for: "requestPermission", on: .client)

/// The wire method of `session/cancel`.
private let sessionCancelMethod = RoleRouting.wireMethod(for: "sessionCancel", on: .agent)

/// The outcome that the handler gives after the gate opens, when its task is
/// not cancelled. It is not `cancelled`, so a test can tell the two apart.
private let selectedOutcome = RequestPermissionOutcome.selected(
    SelectedPermissionOutcome(optionId: RequestPermissionRequest.stubOptionId)
)

/// A `ClientSideConnection` that serves a `GatedPermissionClient`, and the raw
/// agent end of its transport.
private struct RawAgentHarness {
    /// The client side.
    let client: ClientSideConnection

    /// The raw agent end of the transport.
    let agentEnd: InMemoryTransport

    /// Reads the frames that the client writes.
    let reader: WireReader

    /// The gate of the permission handler.
    let gate: Gate

    /// The sessions of the permission requests that reached the handler.
    let entered: AsyncStream<SessionId>

    /// One value for each permission handler whose task is cancelled.
    let cancelled: AsyncStream<Void>

    /// Connects a `GatedPermissionClient` to a raw agent end over
    /// `InMemoryTransport`.
    ///
    /// - Returns: The harness.
    static func connect() async -> RawAgentHarness {
        let gate = Gate()
        let entered = AsyncStream<SessionId>.makeStream()
        let cancelled = AsyncStream<Void>.makeStream()
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let client = await ClientSideConnection(stream: clientEnd) { _ in
            GatedPermissionClient(
                entered: entered.continuation, cancelled: cancelled.continuation, gate: gate,
                outcome: selectedOutcome
            )
        }
        return RawAgentHarness(
            client: client, agentEnd: agentEnd, reader: WireReader(agentEnd), gate: gate,
            entered: entered.stream, cancelled: cancelled.stream
        )
    }

    /// Sends the permission request, and waits until the handler started.
    ///
    /// - Throws: Any encoding or transport failure.
    func sendPermissionRequest() async throws {
        let params = try JSONValue.encode(result: RequestPermissionRequest.stub(for: permissionSession))
        try await send(
            RawPeerEnvelope.request(id: permissionRequestId, method: requestPermissionMethod, params: params),
            over: agentEnd
        )
        var started = entered.makeAsyncIterator()
        #expect(await started.next() == permissionSession)
    }

    /// Sends a `$/cancel_request` for the permission request.
    ///
    /// - Throws: Any transport failure.
    func cancelPermissionRequest() async throws {
        try await send(RawPeerEnvelope.cancelRequest(for: permissionRequestId), over: agentEnd)
    }

    /// Sends the probe request.
    ///
    /// - Throws: Any transport failure.
    func sendProbe() async throws {
        try await send(
            RawPeerEnvelope.request(id: probeRequestId, method: probeMethod, params: .object([:])),
            over: agentEnd
        )
    }

    /// Reads the next frame that the client wrote.
    ///
    /// - Returns: The frame.
    /// - Throws: When the stream ends before a frame comes.
    func nextFrame() async throws -> JSONValue {
        try #require(try await reader.next())
    }

    /// Opens the gate, and closes the client side.
    func close() async {
        gate.open()
        await client.close()
    }
}

// MARK: - Tests

/// The answer of the client to a `$/cancel_request` for a pending
/// `session/request_permission`. The ACP v2 cancellation rules
/// (https://agentclientprotocol.com/protocol/v2/cancellation) require a valid
/// response or a `-32800` error, and one response only.
@Suite struct PermissionCancelRequestTests {
    @Test(.timeLimit(.minutes(cancelRequestTestTimeout)))
    func aCancelRequestForAPendingPermissionRequestAnswersRequestCancelled() async throws {
        let harness = await RawAgentHarness.connect()
        try await harness.sendPermissionRequest()

        try await harness.cancelPermissionRequest()
        var cancelled = harness.cancelled.makeAsyncIterator()
        _ = try #require(await cancelled.next())
        harness.gate.open()

        let expectedAnswer = errorEnvelope(id: permissionRequestId, error: .requestCancelled)
        #expect(try await harness.nextFrame() == expectedAnswer)
        await harness.close()
    }

    @Test(.timeLimit(.minutes(cancelRequestTestTimeout)))
    func aCancelRequestAfterTheCancelledOutcomeSendsNoSecondResponse() async throws {
        let harness = await RawAgentHarness.connect()
        try await harness.sendPermissionRequest()
        let cancel = CancelSessionNotification(sessionId: permissionSession)
        try await harness.client.sessionCancel(cancel)
        let expectedCancel = notificationEnvelope(
            method: sessionCancelMethod, params: try JSONValue.encode(result: cancel))
        #expect(try await harness.nextFrame() == expectedCancel)
        let expectedAnswer = try responseEnvelope(
            id: permissionRequestId, result: RequestPermissionResponse(outcome: .cancelled))
        #expect(try await harness.nextFrame() == expectedAnswer)

        try await harness.cancelPermissionRequest()
        try await harness.sendProbe()

        #expect(requestID(of: try await harness.nextFrame()) == probeRequestId)
        await harness.close()
    }
}
