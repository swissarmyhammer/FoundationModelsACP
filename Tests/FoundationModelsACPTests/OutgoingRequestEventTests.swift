import Foundation
import Testing

@testable import FoundationModelsACP

/// The outgoing-request events of `ClientSideConnection`, over a live
/// transport pair with a raw agent end.
///
/// The raw agent end reads each request from the wire, so each test can
/// compare the wire ID and the wire method with the events. The connection
/// sends `started` before it writes the request, and it sends `finished`
/// before the call returns or throws. Thus each event is in the stream
/// before the test reads it, and no test waits on a timer.
@Suite(.timeLimit(.minutes(1))) struct OutgoingRequestEventTests {
    // MARK: - Fixtures

    /// The timeout of the request in the timeout test. The raw agent end
    /// never answers that request.
    private static let shortRequestTimeout: Duration = .milliseconds(50)

    /// The wire method of the request that a request-scoped elicitation
    /// names in the elicitation test.
    private static let loginWireMethod = "auth/login"

    /// The elicitation ID in the elicitation test.
    private static let elicitationId = ElicitationId(rawValue: "elicit-login")

    // MARK: - Every typed call: success, error, cancel, close

    @Test func everyTypedCallIsInTheTableOfCalls() {
        let typedCalls = Set(
            ACPMethodTable.methods
                .filter { $0.side == .agent && $0.kind == .request }
                .map(\.handlerName)
        )
        #expect(Set(TypedCall.all.map(\.handlerName)) == typedCalls)
    }

    @Test(arguments: TypedCall.all)
    func successfulCallStartsThenFinishes(_ call: TypedCall) async throws {
        let peer = await RawAgentPeer()
        var events = peer.client.subscribeToOutgoingRequests().makeAsyncIterator()
        let caller = Task { [client = peer.client] in try await call.invoke(client) }

        let request = try await peer.nextRequest()
        #expect(request.method == call.wireMethod)
        #expect(await events.next() == .started(id: request.id, method: call.wireMethod))
        #expect(peer.client.inFlightMethod(for: request.id) == call.wireMethod)

        try await peer.respond(to: request.id, with: call.successResult())
        try await caller.value
        #expect(await events.next() == .finished(id: request.id))
        #expect(peer.client.inFlightMethod(for: request.id) == nil)
        await peer.close()
    }

    @Test(arguments: TypedCall.all)
    func failedCallStartsThenFinishes(_ call: TypedCall) async throws {
        let peer = await RawAgentPeer()
        var events = peer.client.subscribeToOutgoingRequests().makeAsyncIterator()
        let caller = Task { [client = peer.client] in try await call.invoke(client) }

        let request = try await peer.nextRequest()
        #expect(await events.next() == .started(id: request.id, method: call.wireMethod))

        try await peer.respond(to: request.id, withError: .invalidParams)
        await #expect(throws: RequestError.invalidParams) { try await caller.value }
        #expect(await events.next() == .finished(id: request.id))
        #expect(peer.client.inFlightMethod(for: request.id) == nil)
        await peer.close()
    }

    @Test(arguments: TypedCall.all)
    func cancelledCallStartsThenFinishes(_ call: TypedCall) async throws {
        let peer = await RawAgentPeer()
        var events = peer.client.subscribeToOutgoingRequests().makeAsyncIterator()
        let caller = Task { [client = peer.client] in try await call.invoke(client) }

        let request = try await peer.nextRequest()
        #expect(await events.next() == .started(id: request.id, method: call.wireMethod))

        caller.cancel()
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(await events.next() == .finished(id: request.id))
        #expect(peer.client.inFlightMethod(for: request.id) == nil)
        await peer.close()
    }

    @Test(arguments: TypedCall.all)
    func callInFlightAtCloseFinishesAndTheStreamEnds(_ call: TypedCall) async throws {
        let peer = await RawAgentPeer()
        var events = peer.client.subscribeToOutgoingRequests().makeAsyncIterator()
        let caller = Task { [client = peer.client] in try await call.invoke(client) }

        let request = try await peer.nextRequest()
        #expect(await events.next() == .started(id: request.id, method: call.wireMethod))

        await peer.client.close()
        await #expect(throws: ConnectionError.closed) { try await caller.value }
        #expect(await events.next() == .finished(id: request.id))
        #expect(await events.next() == nil)
        #expect(peer.client.inFlightMethod(for: request.id) == nil)
        await peer.close()
    }

    // MARK: - Timeout and subscription edges

    @Test func timedOutCallFinishes() async throws {
        let peer = await RawAgentPeer(requestTimeout: Self.shortRequestTimeout)
        var events = peer.client.subscribeToOutgoingRequests().makeAsyncIterator()

        await #expect(throws: ConnectionError.timedOut) {
            _ = try await peer.client.logoutAuth(LogoutAuthRequest())
        }
        let request = try await peer.nextRequest()
        #expect(await events.next() == .started(id: request.id, method: request.method))
        #expect(await events.next() == .finished(id: request.id))
        await peer.close()
    }

    @Test func lateSubscriberFirstGetsTheRequestsThatAreInFlight() async throws {
        let peer = await RawAgentPeer()
        let caller = Task { [client = peer.client] in try await client.logoutAuth(LogoutAuthRequest()) }
        let request = try await peer.nextRequest()

        var events = peer.client.subscribeToOutgoingRequests().makeAsyncIterator()
        #expect(await events.next() == .started(id: request.id, method: request.method))

        try await peer.respond(to: request.id, with: WireRoundTrip.encode(LogoutAuthResponse()))
        _ = try await caller.value
        #expect(await events.next() == .finished(id: request.id))
        await peer.close()
    }

    @Test func everySubscriberGetsEveryEvent() async throws {
        let peer = await RawAgentPeer()
        var first = peer.client.subscribeToOutgoingRequests().makeAsyncIterator()
        var second = peer.client.subscribeToOutgoingRequests().makeAsyncIterator()
        let caller = Task { [client = peer.client] in try await client.logoutAuth(LogoutAuthRequest()) }

        let request = try await peer.nextRequest()
        try await peer.respond(to: request.id, with: WireRoundTrip.encode(LogoutAuthResponse()))
        _ = try await caller.value

        let expected: [OutgoingRequestEvent] = [
            .started(id: request.id, method: request.method), .finished(id: request.id),
        ]
        #expect([await first.next(), await first.next()] == expected)
        #expect([await second.next(), await second.next()] == expected)
        await peer.close()
    }

    @Test func subscriptionAfterCloseEndsAtOnce() async throws {
        let peer = await RawAgentPeer()
        await peer.client.close()

        var events = peer.client.subscribeToOutgoingRequests().makeAsyncIterator()
        #expect(await events.next() == nil)
        await peer.close()
    }

    @Test func inFlightMethodIsNilForAnUnknownRequest() async {
        let peer = await RawAgentPeer()
        #expect(peer.client.inFlightMethod(for: .string("never-sent")) == nil)
        await peer.close()
    }

    // MARK: - A request-scoped elicitation matches its request

    @Test func requestScopedElicitationMatchesTheInFlightLogin() async throws {
        let peer = await RawAgentPeer()
        var events = peer.client.subscribeToOutgoingRequests().makeAsyncIterator()
        let caller = Task { [client = peer.client] in
            try await client.loginAuth(LoginAuthRequest(methodId: AuthMethodId(rawValue: "browser")))
        }
        let login = try await peer.nextRequest()
        #expect(login.method == Self.loginWireMethod)
        #expect(await events.next() == .started(id: login.id, method: Self.loginWireMethod))

        try await peer.sendElicitation(Self.loginElicitation(scopedTo: login.id))
        let elicitation = try #require(await peer.elicitations.next())
        let scopedId = try #require(elicitation.urlRequestScope?.requestId)
        #expect(peer.client.inFlightMethod(for: scopedId) == Self.loginWireMethod)

        _ = try await peer.nextResponse()
        try await peer.respond(to: login.id, with: WireRoundTrip.encode(LoginAuthResponse()))
        _ = try await caller.value
        #expect(await events.next() == .finished(id: scopedId))
        #expect(peer.client.inFlightMethod(for: scopedId) == nil)
        await peer.close()
    }

    /// Makes a url-mode elicitation that names one request of the client.
    ///
    /// - Parameter requestId: The wire ID of the client request.
    /// - Returns: The elicitation request.
    private static func loginElicitation(scopedTo requestId: RequestId) -> CreateElicitationRequest {
        CreateElicitationRequest(
            message: "Finish sign-in in the browser",
            mode: .url(
                ElicitationUrlMode(
                    elicitationId: elicitationId,
                    url: "https://example.test/login",
                    scope: .request(ElicitationRequestScope(requestId: requestId))
                )
            )
        )
    }
}

// MARK: - The typed calls

/// One typed outbound call of `ClientSideConnection`, with a valid result
/// for a raw agent end to send back.
struct TypedCall: Sendable, CustomTestStringConvertible {
    /// The routing table's handler name of the call.
    let handlerName: String

    /// Makes the call on a connection, and discards the result.
    let invoke: @Sendable (ClientSideConnection) async throws -> Void

    /// Makes a valid `result` value for the call.
    let successResult: @Sendable () throws -> JSONValue

    /// The wire method of the call, from the routing table.
    var wireMethod: String {
        ACPMethodTable.methods.first { $0.side == .agent && $0.handlerName == handlerName }?.wireMethod ?? ""
    }

    /// The handler name, as the name of the test case.
    var testDescription: String { handlerName }

    /// The session ID that each session-scoped call names.
    private static let sessionId = SessionId(rawValue: "session-events")

    /// The working directory that each call that needs one names.
    private static let workingDirectory = AbsolutePath(rawValue: "/work")

    /// The client identity that `initialize` sends.
    private static let clientInfo = Implementation(name: "events-client", version: "0.0.0")

    /// Every typed request call of `ClientSideConnection`.
    static let all: [TypedCall] = [
        TypedCall(
            handlerName: "initialize",
            invoke: { _ = try await $0.initialize(InitializeRequest(info: clientInfo, protocolVersion: .v2)) },
            successResult: {
                try WireRoundTrip.encode(
                    InitializeResponse(
                        info: Implementation(name: "events-agent", version: "0.0.0"),
                        protocolVersion: .v2,
                        capabilities: AgentCapabilities(session: SessionCapabilities())
                    )
                )
            }
        ),
        TypedCall(
            handlerName: "newSession",
            invoke: { _ = try await $0.newSession(NewSessionRequest(cwd: workingDirectory)) },
            successResult: { try WireRoundTrip.encode(NewSessionResponse(sessionId: sessionId)) }
        ),
        TypedCall(
            handlerName: "listSessions",
            invoke: { _ = try await $0.listSessions(ListSessionsRequest()) },
            successResult: { try WireRoundTrip.encode(ListSessionsResponse(sessions: [])) }
        ),
        TypedCall(
            handlerName: "resumeSession",
            invoke: {
                _ = try await $0.resumeSession(ResumeSessionRequest(cwd: workingDirectory, sessionId: sessionId))
            },
            successResult: { try WireRoundTrip.encode(ResumeSessionResponse()) }
        ),
        TypedCall(
            handlerName: "closeSession",
            invoke: { _ = try await $0.closeSession(CloseSessionRequest(sessionId: sessionId)) },
            successResult: { try WireRoundTrip.encode(CloseSessionResponse()) }
        ),
        TypedCall(
            handlerName: "prompt",
            invoke: {
                _ = try await $0.prompt(PromptRequest(prompt: [.text(TextContent(text: "hi"))], sessionId: sessionId))
            },
            successResult: { try WireRoundTrip.encode(PromptResponse.stubAcknowledgement) }
        ),
        TypedCall(
            handlerName: "loginAuth",
            invoke: { _ = try await $0.loginAuth(LoginAuthRequest(methodId: AuthMethodId(rawValue: "m1"))) },
            successResult: { try WireRoundTrip.encode(LoginAuthResponse()) }
        ),
        TypedCall(
            handlerName: "logoutAuth",
            invoke: { _ = try await $0.logoutAuth(LogoutAuthRequest()) },
            successResult: { try WireRoundTrip.encode(LogoutAuthResponse()) }
        ),
        TypedCall(
            handlerName: "deleteSession",
            invoke: { _ = try await $0.deleteSession(DeleteSessionRequest(sessionId: sessionId)) },
            successResult: { try WireRoundTrip.encode(DeleteSessionResponse()) }
        ),
        TypedCall(
            handlerName: "setSessionConfigOption",
            invoke: {
                _ = try await $0.setSessionConfigOption(
                    SetSessionConfigOptionRequest(
                        configId: SessionConfigId(rawValue: "cfg-1"),
                        sessionId: sessionId,
                        value: .boolean(true)
                    )
                )
            },
            successResult: { try WireRoundTrip.encode(SetSessionConfigOptionResponse(configOptions: [])) }
        ),
    ]
}

// MARK: - The raw agent end

/// A `ClientSideConnection` and a raw agent end that the test drives frame
/// by frame.
private final class RawAgentPeer {
    /// One request that the client wrote to the wire.
    struct WireRequest {
        /// The wire ID of the request.
        let id: RequestId

        /// The wire method of the request.
        let method: String
    }

    /// The connection under test.
    let client: ClientSideConnection

    /// The elicitation requests that the client served, in order.
    var elicitations: AsyncStream<CreateElicitationRequest>.Iterator

    /// The raw agent end of the transport pair.
    private let agentEnd: InMemoryTransport

    /// Reads the frames that the client writes.
    private let reader: WireReader

    /// The monotonic ID of the next request that the agent end sends.
    private var nextAgentRequestId = 1

    /// Opens a transport pair and a client connection on one end.
    ///
    /// - Parameter requestTimeout: The default timeout of each outbound
    ///   request of the client; `nil` waits forever.
    init(requestTimeout: Duration? = nil) async {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let served = AsyncStream<CreateElicitationRequest>.makeStream()
        self.agentEnd = agentEnd
        reader = WireReader(agentEnd)
        elicitations = served.stream.makeAsyncIterator()
        client = await ClientSideConnection(stream: clientEnd, requestTimeout: requestTimeout) { _ in
            ElicitationRecordingClient(served: served.continuation)
        }
    }

    /// Reads the next request that the client wrote.
    ///
    /// - Returns: The wire ID and the wire method of the request.
    /// - Throws: When the wire ends, or the next frame is not a request.
    func nextRequest() async throws -> WireRequest {
        let fields = try await nextFrame()
        let id = try #require(fields["id"])
        guard case .string(let method) = try #require(fields["method"]) else {
            throw RawAgentPeerError.notARequest(fields)
        }
        return WireRequest(id: id, method: method)
    }

    /// Reads the next response that the client wrote.
    ///
    /// - Returns: The members of the response envelope.
    /// - Throws: When the wire ends.
    @discardableResult
    func nextResponse() async throws -> [String: JSONValue] {
        try await nextFrame()
    }

    /// Answers one client request with a result.
    ///
    /// - Parameters:
    ///   - id: The wire ID of the request.
    ///   - result: The `result` value.
    /// - Throws: When the write fails.
    func respond(to id: RequestId, with result: JSONValue) async throws {
        try await send(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]), over: agentEnd)
    }

    /// Answers one client request with an error.
    ///
    /// - Parameters:
    ///   - id: The wire ID of the request.
    ///   - error: The error to send.
    /// - Throws: When the write fails.
    func respond(to id: RequestId, withError error: RequestError) async throws {
        try await send(.object(["jsonrpc": .string("2.0"), "id": id, "error": error.wireValue]), over: agentEnd)
    }

    /// Sends one `elicitation/create` request to the client.
    ///
    /// - Parameter elicitation: The elicitation request.
    /// - Throws: When the encoding or the write fails.
    func sendElicitation(_ elicitation: CreateElicitationRequest) async throws {
        let id: RequestId = .number(Double(nextAgentRequestId))
        nextAgentRequestId += 1
        let envelope: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "method": .string("elicitation/create"),
            "params": try WireRoundTrip.encode(elicitation),
        ])
        try await send(envelope, over: agentEnd)
    }

    /// Closes the client connection and the agent end.
    func close() async {
        await client.close()
        agentEnd.close()
    }

    /// Reads the next frame that the client wrote.
    ///
    /// - Returns: The members of the envelope.
    /// - Throws: When the wire ends, or the frame is not an object.
    private func nextFrame() async throws -> [String: JSONValue] {
        let frame = try #require(try await reader.next())
        guard case .object(let fields) = frame else {
            throw RawAgentPeerError.notAnObject(frame)
        }
        return fields
    }
}

/// A frame from the client that does not have the expected shape.
private enum RawAgentPeerError: Error {
    /// The frame is not a JSON object.
    case notAnObject(JSONValue)

    /// The frame has no string `method` member.
    case notARequest([String: JSONValue])
}

/// A `Client` that sends each elicitation it serves to a stream, and
/// declines it.
private struct ElicitationRecordingClient: Client {
    /// Receives each elicitation request, in order.
    let served: AsyncStream<CreateElicitationRequest>.Continuation

    func sessionUpdate(_ notification: UpdateSessionNotification) async {}

    func requestPermission(_ params: RequestPermissionRequest) async throws -> RequestPermissionResponse {
        RequestPermissionResponse(outcome: .cancelled)
    }

    func createElicitation(_ params: CreateElicitationRequest) async throws -> CreateElicitationResponse {
        served.yield(params)
        return .object(["action": .string("decline")])
    }

    func elicitationComplete(_ notification: CompleteElicitationNotification) async {}
}

extension CreateElicitationRequest {
    /// The request scope of a url-mode elicitation, or `nil` for any other
    /// mode or scope.
    fileprivate var urlRequestScope: ElicitationRequestScope? {
        guard case .url(let url) = mode, case .request(let scope) = url.scope else { return nil }
        return scope
    }
}
