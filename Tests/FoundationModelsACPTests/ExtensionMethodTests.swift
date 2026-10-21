import Foundation
import Testing

@testable import FoundationModelsACP

// MARK: - Fixtures

/// The params and the result of the extension messages of this suite.
private struct EchoMessage: Codable, Equatable, Sendable {
    /// The text of the message.
    var text: String
}

/// The extension method that the handlers of this suite serve: it answers
/// with the text of the params in upper case.
private let echoMethod = "_test/echo"

/// The extension notification that the handlers of this suite record.
private let eventNotification = "_test/event"

/// An extension method and notification that no handler of this suite serves.
private let unknownMethod = "_test/unknown"

/// The namespace under which the agent of this suite advertises its
/// extensions in `_meta`.
private let capabilityNamespace = "test"

/// The extension capabilities that the agent of this suite advertises.
private struct TestCapabilities: Codable, Equatable {
    /// The extension methods that the agent serves.
    var methods: [String]
}

/// The echo of `message`: its text in upper case.
///
/// - Parameter message: The params of the call.
/// - Returns: The result of the call.
private func echo(_ message: EchoMessage) -> EchoMessage {
    EchoMessage(text: message.text.uppercased())
}

/// Handlers that serve `echoMethod`, and give each `eventNotification` to
/// `received`.
///
/// - Parameter received: Gets the params of each event notification.
/// - Returns: The handlers.
private func recordingHandlers(
    into received: AsyncStream<EchoMessage>.Continuation
) -> ExtensionHandlers {
    var handlers = ExtensionHandlers()
    handlers.registerMethod(echoMethod, params: EchoMessage.self) { echo($0) }
    handlers.registerNotification(eventNotification, params: EchoMessage.self) { received.yield($0) }
    return handlers
}

/// An agent connection and a client connection over one in-memory transport.
private struct ExtensionPeers {
    /// The agent side.
    let agent: AgentSideConnection

    /// The client side.
    let client: ClientSideConnection

    /// Connects a `StubAgent` and a `HandshakeClient` with the given handlers.
    ///
    /// - Parameters:
    ///   - agentHandlers: The extension handlers of the agent.
    ///   - clientHandlers: The extension handlers of the client.
    ///   - initializeMeta: The `_meta` of the `initialize` response of the
    ///     agent.
    /// - Returns: The two connected sides.
    static func connect(
        agentHandlers: ExtensionHandlers = ExtensionHandlers(),
        clientHandlers: ExtensionHandlers = ExtensionHandlers(),
        initializeMeta: JSONValue? = nil
    ) async -> ExtensionPeers {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agent = await AgentSideConnection(stream: agentEnd) { _ in
            StubAgent(extensionHandlers: agentHandlers, initializeMeta: initializeMeta)
        }
        let client = await ClientSideConnection(stream: clientEnd) { _ in
            HandshakeClient(extensionHandlers: clientHandlers)
        }
        return ExtensionPeers(agent: agent, client: client)
    }

    /// Closes both sides.
    func close() async {
        await agent.close()
        await client.close()
    }
}

/// An agent connection with the recording handlers, and a raw client end.
private struct RawClientHarness {
    /// The agent side.
    let agent: AgentSideConnection

    /// The raw client end of the transport.
    let clientEnd: InMemoryTransport

    /// Reads the frames that reach the client end.
    let reader: WireReader

    /// Connects an agent that serves the recording handlers to a raw end.
    ///
    /// - Parameters:
    ///   - received: Gets the params of each event notification.
    ///   - logger: The logger of the agent connection.
    /// - Returns: The harness.
    static func connect(
        recordingInto received: AsyncStream<EchoMessage>.Continuation,
        logger: ACPLogger
    ) async -> RawClientHarness {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let handlers = recordingHandlers(into: received)
        let agent = await AgentSideConnection(stream: agentEnd, logger: logger) { _ in
            StubAgent(extensionHandlers: handlers)
        }
        return RawClientHarness(agent: agent, clientEnd: clientEnd, reader: WireReader(clientEnd))
    }

    /// Sends one notification over the raw end.
    ///
    /// - Parameters:
    ///   - method: The wire method.
    ///   - params: The raw params.
    func sendNotification(_ method: String, params: JSONValue) async throws {
        try await send(notificationEnvelope(method: method, params: params), over: clientEnd)
    }

    /// Calls `echoMethod` over the raw end, and expects its response as the
    /// next frame on the wire.
    ///
    /// The agent dispatches a notification before it reads the next frame.
    /// Thus, when the response comes, each notification sent before it was
    /// dispatched.
    func expectEchoRoundTrip() async throws {
        let id = JSONValue.number(1)
        let params = try JSONValue.encode(result: EchoMessage(text: "after"))
        try await send(RawPeerEnvelope.request(id: id, method: echoMethod, params: params), over: clientEnd)
        let frame = try #require(try await reader.next())
        #expect(frame == (try responseEnvelope(id: id, result: EchoMessage(text: "AFTER"))))
    }

    /// Closes the agent side and the raw client end.
    func close() async {
        await agent.close()
        clientEnd.close()
    }
}

// MARK: - Extension methods

/// A registered `_` method gets the call, and its result goes back. A `_`
/// method with no handler gives `methodNotFound`.
@Suite struct ExtensionMethodTests {
    @Test func aRegisteredMethodOfTheAgentGetsTheCallAndItsResultGoesBack() async throws {
        let (_, received) = AsyncStream<EchoMessage>.makeStream()
        let peers = await ExtensionPeers.connect(agentHandlers: recordingHandlers(into: received))
        defer { await peers.close() }

        let result = try await peers.client.callExtensionMethod(
            echoMethod, EchoMessage(text: "hi"), returning: EchoMessage.self)

        #expect(result == EchoMessage(text: "HI"))
    }

    @Test func aRegisteredMethodOfTheClientGetsTheCallAndItsResultGoesBack() async throws {
        let (_, received) = AsyncStream<EchoMessage>.makeStream()
        let peers = await ExtensionPeers.connect(clientHandlers: recordingHandlers(into: received))
        defer { await peers.close() }

        let result = try await peers.agent.callExtensionMethod(
            echoMethod, EchoMessage(text: "hi"), returning: EchoMessage.self)

        #expect(result == EchoMessage(text: "HI"))
    }

    @Test func aMethodWithNoHandlerGivesMethodNotFound() async throws {
        let (_, received) = AsyncStream<EchoMessage>.makeStream()
        let peers = await ExtensionPeers.connect(agentHandlers: recordingHandlers(into: received))
        defer { await peers.close() }

        let error = await #expect(throws: RequestError.self) {
            try await peers.client.callExtensionMethod(unknownMethod, EchoMessage(text: "hi"), returning: EchoMessage.self)
        }

        #expect(error == RequestError.methodNotFound(unknownMethod))
    }

    @Test func aMethodWhoseParamsDoNotDecodeGivesInvalidParams() async throws {
        let (_, received) = AsyncStream<EchoMessage>.makeStream()
        let peers = await ExtensionPeers.connect(agentHandlers: recordingHandlers(into: received))
        defer { await peers.close() }
        let wrongParams = JSONValue.object(["text": .number(1)])

        let error = await #expect(throws: RequestError.self) {
            try await peers.client.callExtensionMethod(echoMethod, wrongParams, returning: EchoMessage.self)
        }

        #expect(error?.code == .invalidParams)
    }
}

// MARK: - Extension notifications

/// A registered `_` notification reaches its handler in each direction. A `_`
/// notification with no handler is ignored.
@Suite struct ExtensionNotificationTests {
    @Test func aNotificationFromTheAgentReachesTheHandlerOfTheClient() async throws {
        let (events, received) = AsyncStream<EchoMessage>.makeStream()
        let peers = await ExtensionPeers.connect(clientHandlers: recordingHandlers(into: received))
        defer { await peers.close() }

        try await peers.agent.sendExtensionNotification(eventNotification, EchoMessage(text: "ping"))
        // The client dispatches the notification before it reads the request
        // that follows it, so the event is recorded when the call returns.
        _ = try await peers.agent.callExtensionMethod(echoMethod, EchoMessage(text: "after"), returning: EchoMessage.self)
        received.finish()

        #expect(await events.reduce(into: []) { $0.append($1) } == [EchoMessage(text: "ping")])
    }

    @Test func aNotificationFromTheClientReachesTheHandlerOfTheAgent() async throws {
        let (events, received) = AsyncStream<EchoMessage>.makeStream()
        let peers = await ExtensionPeers.connect(agentHandlers: recordingHandlers(into: received))
        defer { await peers.close() }

        try await peers.client.sendExtensionNotification(eventNotification, EchoMessage(text: "ping"))
        // The agent dispatches the notification before it reads the request
        // that follows it, so the event is recorded when the call returns.
        _ = try await peers.client.callExtensionMethod(echoMethod, EchoMessage(text: "after"), returning: EchoMessage.self)
        received.finish()

        #expect(await events.reduce(into: []) { $0.append($1) } == [EchoMessage(text: "ping")])
    }

    @Test func aNotificationWithNoHandlerIsIgnored() async throws {
        let (events, received) = AsyncStream<EchoMessage>.makeStream()
        let logs = LogCapture()
        let harness = await RawClientHarness.connect(recordingInto: received, logger: logs.logger)
        defer { await harness.close() }

        try await harness.sendNotification(unknownMethod, params: .object(["text": .string("ping")]))
        try await harness.expectEchoRoundTrip()
        received.finish()

        #expect(await events.reduce(into: []) { $0.append($1) }.isEmpty)
        #expect(logs.messages.isEmpty)
    }

    @Test func aNotificationWhoseParamsDoNotDecodeIsDroppedWithAWarning() async throws {
        let (events, received) = AsyncStream<EchoMessage>.makeStream()
        let logs = LogCapture()
        let harness = await RawClientHarness.connect(recordingInto: received, logger: logs.logger)
        defer { await harness.close() }

        try await harness.sendNotification(eventNotification, params: .object(["text": .number(1)]))
        try await harness.expectEchoRoundTrip()
        received.finish()

        #expect(await events.reduce(into: []) { $0.append($1) }.isEmpty)
        #expect(logs.messages.count == 1)
        #expect(logs.messages.first?.contains(eventNotification) == true)
    }
}

// MARK: - Extension capabilities in _meta

/// A side advertises its extensions as capabilities under its namespace in
/// `_meta`, and the peer reads them.
@Suite struct ExtensionCapabilityTests {
    @Test func theClientReadsTheCapabilitiesThatTheAgentAdvertisesInInitialize() async throws {
        let advertised = TestCapabilities(methods: [echoMethod])
        let meta = try ExtensionMeta.inject(advertised, into: nil, member: capabilityNamespace)
        let peers = await ExtensionPeers.connect(initializeMeta: meta)
        defer { await peers.close() }

        let response = try await peers.client.initialize(handshakeInitializeRequest())

        #expect(ExtensionMeta.payload(TestCapabilities.self, in: response.meta, member: capabilityNamespace) == advertised)
    }

    @Test func advertisingKeepsTheOtherMembersOfMeta() throws {
        let other: JSONValue = .object(["other": .string("kept")])

        let advertised = TestCapabilities(methods: [echoMethod])

        let meta = try ExtensionMeta.inject(advertised, into: other, member: capabilityNamespace)

        #expect(ExtensionMeta.payload(String.self, in: meta, member: "other") == "kept")
        #expect(ExtensionMeta.payload(TestCapabilities.self, in: meta, member: capabilityNamespace) == advertised)
    }

    @Test func aMetaWithNoValidPayloadAdvertisesNothing() {
        let meta: JSONValue = .object([capabilityNamespace: .string("not an object")])

        #expect(ExtensionMeta.payload(TestCapabilities.self, in: meta, member: capabilityNamespace) == nil)
        #expect(ExtensionMeta.payload(TestCapabilities.self, in: nil, member: capabilityNamespace) == nil)
    }
}
