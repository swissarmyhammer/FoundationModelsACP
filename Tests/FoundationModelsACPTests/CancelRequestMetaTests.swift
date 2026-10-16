import Foundation
import Synchronization
import Testing

@testable import FoundationModelsACP

/// What the probe client saw, in the order that each handler saw it.
private enum ClientEvent: Sendable, Equatable {
    /// A handler that waits for its cancel started.
    case entered(String)
    /// A handler saw its cancel, and read this `cancelRequestMeta` and this
    /// `cancelledByPeer`.
    case cancelled(String, JSONValue?, byPeer: Bool)
    /// A handler answered at once. It read this arrival number as its first
    /// statement, and this `cancelRequestMeta` and `cancelledByPeer` before it
    /// answered.
    case answered(String, arrival: UInt64?, meta: JSONValue?, byPeer: Bool)
}

/// A `Client` whose `createElicitation` waits for its cancel when the
/// message starts with ``waitPrefix``, and answers `decline` at once when it
/// does not. Its `requestPermission` always waits for its cancel.
private struct CancelProbeClient: Client {
    /// The message prefix of a request that waits for its cancel.
    static let waitPrefix = "wait"

    /// Gets each event of each handler.
    let events: AsyncStream<ClientEvent>.Continuation

    func sessionUpdate(_ notification: UpdateSessionNotification) async {}

    /// Waits for its cancel, with the title of the request as the event name.
    func requestPermission(_ params: RequestPermissionRequest) async throws -> RequestPermissionResponse {
        let name = params.title
        events.yield(.entered(name))
        await CancelGate().waitForCancel()
        events.yield(
            .cancelled(name, ClientSideConnection.cancelRequestMeta, byPeer: ClientSideConnection.cancelledByPeer))
        throw CancellationError()
    }

    func createElicitation(_ params: CreateElicitationRequest) async throws -> CreateElicitationResponse {
        let arrival = ClientSideConnection.currentRequestArrival
        guard params.message.hasPrefix(Self.waitPrefix) else {
            events.yield(
                .answered(
                    params.message, arrival: arrival, meta: ClientSideConnection.cancelRequestMeta,
                    byPeer: ClientSideConnection.cancelledByPeer))
            return .object(["action": .string("decline")])
        }
        events.yield(.entered(params.message))
        await CancelGate().waitForCancel()
        events.yield(
            .cancelled(
                params.message, ClientSideConnection.cancelRequestMeta, byPeer: ClientSideConnection.cancelledByPeer))
        throw CancellationError()
    }

    func elicitationComplete(_ notification: CompleteElicitationNotification) async {}
}

/// An `Agent` that these tests never call. The connection factory needs one.
private struct IdleAgent: Agent {
    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(
            info: Implementation(name: "idle-agent", version: "0.0.0"),
            protocolVersion: .v2,
            capabilities: AgentCapabilities(session: SessionCapabilities())
        )
    }

    func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: SessionId(rawValue: "session-1"))
    }

    func listSessions(_ params: ListSessionsRequest) async throws -> ListSessionsResponse {
        ListSessionsResponse(sessions: [])
    }

    func resumeSession(_ params: ResumeSessionRequest) async throws -> ResumeSessionResponse {
        ResumeSessionResponse()
    }

    func closeSession(_ params: CloseSessionRequest) async throws -> CloseSessionResponse {
        CloseSessionResponse()
    }

    func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        PromptResponse.stubAcknowledgement
    }

    func sessionCancel(_ params: CancelSessionNotification) async {}
}

/// The `_meta` of `$/cancel_request` (elicitation plan task 50), and the
/// arrival number of an inbound request.
///
/// Each test runs in a fixed order. Each step waits for a stream element or
/// a wire frame that the step before it causes. Each wait also ends when a
/// connection closes, and each test closes its connections also when it
/// fails. No test uses a clock, a sleep, a poll, a retry or a time limit.
@Suite struct CancelRequestMetaTests {
    // MARK: - Fixtures

    /// The `_meta` that ACPAgent sends when a run cancel ends a question.
    private static let runCancelledMeta: JSONValue = .object([
        CancelRequestNotification.reasonMetaKey: .string("run cancelled")
    ])

    /// A form-mode elicitation request with `message`.
    ///
    /// - Parameter message: The message, which also selects how the probe
    ///   client answers.
    /// - Returns: The request.
    private static func request(_ message: String) -> CreateElicitationRequest {
        CreateElicitationRequest(
            message: message,
            mode: .form(
                ElicitationFormMode(
                    requestedSchema: ElicitationSchema(
                        properties: .object(["name": .object(["type": .string("string")])]),
                        required: ["name"]
                    ),
                    scope: .session(ElicitationSessionScope(sessionId: SessionId(rawValue: "session-1")))
                )
            )
        )
    }

    /// The `elicitation/create` request frame with `id` and `message`, as a
    /// raw agent writes it.
    ///
    /// - Parameters:
    ///   - id: The wire id.
    ///   - message: The message of the request.
    /// - Returns: The request envelope.
    private static func requestFrame(id: Int, message: String) throws -> JSONValue {
        RawPeerEnvelope.request(
            id: .number(Double(id)), method: "elicitation/create", params: try JSONValue.encode(result: request(message))
        )
    }

    /// An agent connection and a client connection over one in-memory pair.
    private struct EndToEnd {
        let agent: AgentSideConnection
        let client: ClientSideConnection
        let events: AsyncStream<ClientEvent>

        /// Closes the two connections.
        func close() async {
            await agent.close()
            await client.close()
        }
    }

    /// Connects an agent and the probe client. The event stream of the
    /// client ends when the client connection closed.
    ///
    /// - Returns: The two connections and the event stream of the client.
    private static func connectEndToEnd() async -> EndToEnd {
        let events = AsyncStream<ClientEvent>.makeStream()
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let client = await ClientSideConnection(stream: clientEnd) { _ in
            CancelProbeClient(events: events.continuation)
        }
        finishStream(events.continuation) { _ = await client.closed }
        let agent = await AgentSideConnection(stream: agentEnd) { _ in IdleAgent() }
        return EndToEnd(agent: agent, client: client, events: events.stream)
    }

    /// Connects the probe client to a raw agent end. The event stream of the
    /// client ends when the client connection closed.
    ///
    /// - Returns: The client connection, the raw agent end, and the event
    ///   stream of the client.
    private static func connectRawAgent() async -> (
        client: ClientSideConnection, agentEnd: InMemoryTransport, events: AsyncStream<ClientEvent>
    ) {
        let events = AsyncStream<ClientEvent>.makeStream()
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let client = await ClientSideConnection(stream: clientEnd) { _ in
            CancelProbeClient(events: events.continuation)
        }
        finishStream(events.continuation) { _ = await client.closed }
        return (client, agentEnd, events.stream)
    }

    /// Starts one call of the agent in a new task.
    ///
    /// When the call fails with an error that is not `CancellationError`,
    /// the task closes the agent connection. Then each wait of the test for
    /// a client event or a wire frame ends, and the test fails. A test
    /// cancels a call only after the call reached the peer, so the expected
    /// cancel does not close the connection.
    ///
    /// - Parameters:
    ///   - agent: The agent connection that makes the call.
    ///   - body: The call.
    /// - Returns: The task of the call.
    private static func startCall<Response: Sendable>(
        on agent: AgentSideConnection,
        _ body: @escaping @Sendable () async throws -> Response
    ) -> Task<Response, any Error> {
        Task {
            do {
                return try await body()
            } catch let error where !(error is CancellationError) {
                await agent.close()
                throw error
            }
        }
    }

    /// Asserts that `task` ended with `CancellationError`.
    ///
    /// - Parameter task: The task of a cancelled call.
    private static func expectCancelled(_ task: Task<CreateElicitationResponse, any Error>) async {
        let result = await task.result
        guard case .failure(let error) = result else {
            Issue.record("expected the call to throw, got \(result)")
            return
        }
        #expect(error is CancellationError)
    }

    // MARK: - T1: the reason goes to the handler

    @Test func cancelMetaReachesTheClientHandler() async throws {
        let pair = await Self.connectEndToEnd()
        defer { await pair.close() }
        var events = pair.events.makeAsyncIterator()
        let cancellation = OutboundCancellation()
        let agent = pair.agent
        let call = Self.startCall(on: agent) {
            try await agent.createElicitation(Self.request("wait-1"), cancellation: cancellation)
        }

        #expect(await events.next() == .entered("wait-1"))
        cancellation.setMeta(Self.runCancelledMeta)
        call.cancel()

        #expect(await events.next() == .cancelled("wait-1", Self.runCancelledMeta, byPeer: true))
        await Self.expectCancelled(call)
    }

    @Test func cancelRequestFrameCarriesTheMeta() async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agent = await AgentSideConnection(stream: agentEnd) { _ in IdleAgent() }
        defer { await agent.close() }
        defer { clientEnd.close() }
        let reader = WireReader(clientEnd)
        let cancellation = OutboundCancellation()
        let call = Self.startCall(on: agent) {
            try await agent.createElicitation(Self.request("wait-1"), cancellation: cancellation)
        }

        let request = try #require(try await reader.next())
        let id = try #require(requestID(of: request))
        cancellation.setMeta(Self.runCancelledMeta)
        call.cancel()

        let cancel = try #require(try await reader.next())
        #expect(
            cancel
                == notificationEnvelope(
                    method: RawPeerEnvelope.cancelRequestMethod,
                    params: .object(["requestId": id, "_meta": Self.runCancelledMeta])
                ))
        await Self.expectCancelled(call)
    }

    @Test func permissionCancelMetaReachesTheClientHandler() async throws {
        let pair = await Self.connectEndToEnd()
        defer { await pair.close() }
        var events = pair.events.makeAsyncIterator()
        let cancellation = OutboundCancellation()
        let agent = pair.agent
        let request = RequestPermissionRequest.stub(for: SessionId(rawValue: "session-1"))
        let call = Self.startCall(on: agent) { try await agent.requestPermission(request, cancellation: cancellation) }

        #expect(await events.next() == .entered("Permission needed"))
        cancellation.setMeta(Self.runCancelledMeta)
        call.cancel()

        #expect(await events.next() == .cancelled("Permission needed", Self.runCancelledMeta, byPeer: true))
        let result = await call.result
        guard case .failure(let error) = result else {
            Issue.record("expected the call to throw, got \(result)")
            return
        }
        #expect(error is CancellationError)
    }

    // MARK: - T2: no meta

    @Test func cancelWithNoBoxSendsNoMetaMember() async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agent = await AgentSideConnection(stream: agentEnd) { _ in IdleAgent() }
        defer { await agent.close() }
        defer { clientEnd.close() }
        let reader = WireReader(clientEnd)
        let call = Self.startCall(on: agent) { try await agent.createElicitation(Self.request("wait-2")) }

        let request = try #require(try await reader.next())
        let id = try #require(requestID(of: request))
        call.cancel()

        let cancel = try #require(try await reader.next())
        #expect(
            cancel
                == notificationEnvelope(
                    method: RawPeerEnvelope.cancelRequestMethod, params: .object(["requestId": id])
                ))
        await Self.expectCancelled(call)
    }

    @Test func cancelWithABoxThatHasNoMetaSendsNoMetaMember() async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agent = await AgentSideConnection(stream: agentEnd) { _ in IdleAgent() }
        defer { await agent.close() }
        defer { clientEnd.close() }
        let reader = WireReader(clientEnd)
        let cancellation = OutboundCancellation()
        let call = Self.startCall(on: agent) {
            try await agent.createElicitation(Self.request("wait-2"), cancellation: cancellation)
        }

        let request = try #require(try await reader.next())
        let id = try #require(requestID(of: request))
        call.cancel()

        let cancel = try #require(try await reader.next())
        #expect(
            cancel
                == notificationEnvelope(
                    method: RawPeerEnvelope.cancelRequestMethod, params: .object(["requestId": id])
                ))
        await Self.expectCancelled(call)
    }

    @Test func handlerReadsNilWhenTheCancelHasNoMeta() async throws {
        let pair = await Self.connectEndToEnd()
        defer { await pair.close() }
        var events = pair.events.makeAsyncIterator()
        let agent = pair.agent
        let call = Self.startCall(on: agent) { try await agent.createElicitation(Self.request("wait-2")) }

        #expect(await events.next() == .entered("wait-2"))
        call.cancel()

        #expect(await events.next() == .cancelled("wait-2", nil, byPeer: true))
        await Self.expectCancelled(call)
    }

    // MARK: - T3: one meta for each request

    @Test func eachCancelledRequestGetsItsOwnMeta() async throws {
        let pair = await Self.connectEndToEnd()
        defer { await pair.close() }
        var events = pair.events.makeAsyncIterator()
        let agent = pair.agent
        let reasons = ["wait-a": "run cancelled", "wait-b": "no user is present"]
        var calls: [String: (OutboundCancellation, Task<CreateElicitationResponse, any Error>)] = [:]
        for message in reasons.keys {
            let cancellation = OutboundCancellation()
            let call = Self.startCall(on: agent) {
                try await agent.createElicitation(Self.request(message), cancellation: cancellation)
            }
            calls[message] = (cancellation, call)
        }

        var entered: Set<String> = []
        for _ in reasons {
            guard case .entered(let message) = try #require(await events.next()) else {
                Issue.record("expected an entered event")
                return
            }
            entered.insert(message)
        }
        #expect(entered == Set(reasons.keys))

        for (message, (cancellation, call)) in calls {
            cancellation.setMeta(.object([CancelRequestNotification.reasonMetaKey: .string(reasons[message]!)]))
            call.cancel()
        }

        var seen: [String: JSONValue?] = [:]
        for _ in reasons {
            guard case .cancelled(let message, let meta, byPeer: true) = try #require(await events.next()) else {
                Issue.record("expected a cancelled event from the peer")
                return
            }
            seen[message] = meta
        }
        for (message, reason) in reasons {
            #expect(seen[message] == .object([CancelRequestNotification.reasonMetaKey: .string(reason)]))
        }
        for (_, call) in calls.values {
            await Self.expectCancelled(call)
        }
    }

    // MARK: - T4: no cancel, or no handler

    @Test func handlerWithNoCancelReadsNil() async throws {
        let pair = await Self.connectEndToEnd()
        defer { await pair.close() }
        var events = pair.events.makeAsyncIterator()

        let response = try await pair.agent.createElicitation(Self.request("answer-1"))

        #expect(response == .object(["action": .string("decline")]))
        guard case .answered("answer-1", let arrival, let meta, let byPeer) = try #require(await events.next()) else {
            Issue.record("expected an answered event")
            return
        }
        #expect(arrival != nil)
        #expect(meta == nil)
        #expect(!byPeer)
    }

    @Test func codeOutsideAHandlerReadsNil() {
        #expect(Connection.cancelRequestMeta == nil)
        #expect(ClientSideConnection.cancelRequestMeta == nil)
        #expect(AgentSideConnection.cancelRequestMeta == nil)
        #expect(!Connection.cancelledByPeer)
        #expect(!ClientSideConnection.cancelledByPeer)
        #expect(!AgentSideConnection.cancelledByPeer)
        #expect(Connection.currentRequestArrival == nil)
        #expect(ClientSideConnection.currentRequestArrival == nil)
        #expect(AgentSideConnection.currentRequestArrival == nil)
    }

    // MARK: - T5: a raw peer

    @Test func rawMetaThatIsNotAnObjectIsGivenAsItIs() async throws {
        let (client, agentEnd, events) = await Self.connectRawAgent()
        defer { await client.close() }
        defer { agentEnd.close() }
        let reader = WireReader(agentEnd)
        var iterator = events.makeAsyncIterator()

        try await send(Self.requestFrame(id: 7, message: "wait-raw"), over: agentEnd)
        #expect(await iterator.next() == .entered("wait-raw"))

        try await send(
            notificationEnvelope(
                method: RawPeerEnvelope.cancelRequestMethod,
                params: .object(["requestId": .number(7), "_meta": .string("plain text")])
            ),
            over: agentEnd
        )
        #expect(await iterator.next() == .cancelled("wait-raw", .string("plain text"), byPeer: true))

        let response = try #require(try await reader.next())
        #expect(requestID(of: response) == .number(7))
        guard case .object(let fields) = response, case .object(let error) = fields["error"] ?? .null else {
            Issue.record("expected an error response, got \(response)")
            return
        }
        #expect(error["code"] == .number(-32800))
    }

    // MARK: - A close is not a cancel of the peer

    @Test func closeWithAnOpenHandlerIsNotACancelOfThePeer() async throws {
        let (client, agentEnd, events) = await Self.connectRawAgent()
        defer { await client.close() }
        defer { agentEnd.close() }
        var iterator = events.makeAsyncIterator()

        try await send(Self.requestFrame(id: 9, message: "wait-close"), over: agentEnd)
        #expect(await iterator.next() == .entered("wait-close"))

        agentEnd.close()

        #expect(await iterator.next() == .cancelled("wait-close", nil, byPeer: false))
        guard case .endOfInput = await client.closed else {
            Issue.record("expected the close reason endOfInput")
            return
        }
    }

    // MARK: - Arrival number

    @Test func twoRequestsInOneWriteGetArrivalNumbersInWireOrder() async throws {
        let (client, agentEnd, events) = await Self.connectRawAgent()
        defer { await client.close() }
        defer { agentEnd.close() }
        let reader = WireReader(agentEnd)
        var iterator = events.makeAsyncIterator()

        var bytes = try NDJSONCodec.encode(Self.requestFrame(id: 1, message: "first"))
        bytes.append(try NDJSONCodec.encode(Self.requestFrame(id: 2, message: "second")))
        try await agentEnd.write(bytes)

        var arrivals: [String: UInt64] = [:]
        for _ in 0..<2 {
            guard case .answered(let message, let arrival?, _, _) = try #require(await iterator.next()) else {
                Issue.record("expected an answered event with an arrival number")
                return
            }
            arrivals[message] = arrival
        }
        let first = try #require(arrivals["first"])
        #expect(arrivals["second"] == first + 1)

        var answered: Set<JSONValue> = []
        for _ in 0..<2 {
            answered.insert(try #require(requestID(of: try await reader.next())))
        }
        #expect(answered == [.number(1), .number(2)])
    }
}
