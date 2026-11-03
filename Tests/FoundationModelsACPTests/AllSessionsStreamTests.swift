import Foundation
import Testing

@testable import FoundationModelsACP

/// `ClientSideConnection.subscribeToAllSessions()`: one stream of the events
/// of every session, in wire order, with a sequence number that shares its
/// counter with `currentRequestArrival`.
@Suite struct AllSessionsStreamTests {
    private static let root = SessionId(rawValue: "root")
    private static let child = SessionId(rawValue: "child")
    private static let grandchild = SessionId(rawValue: "grandchild")
    private static let resumeMethod = RoleRouting.wireMethod(for: "resumeSession", on: .agent)
    private static let permissionMethod = RoleRouting.wireMethod(for: "requestPermission", on: .client)

    /// A client that reports the arrival number of each permission request.
    private struct RecordingClient: Client {
        let arrivals: AsyncStream<UInt64?>.Continuation

        func sessionUpdate(_ notification: UpdateSessionNotification) async {}

        func requestPermission(_ params: RequestPermissionRequest) async throws -> RequestPermissionResponse {
            arrivals.yield(ClientSideConnection.currentRequestArrival)
            return RequestPermissionResponse(outcome: .cancelled(CancelledPermissionOutcome()))
        }

        func createElicitation(_ params: CreateElicitationRequest) async throws -> CreateElicitationResponse {
            throw RequestError.methodNotFound("createElicitation")
        }

        func elicitationComplete(_ notification: CompleteElicitationNotification) async {}
    }

    private static func announce(_ session: SessionId, child: SessionId) -> UpdateSessionNotification {
        UpdateSessionNotification(
            sessionId: session, update: .subagentUpdate(SubagentUpdate(sessionId: child, title: .value("T"))))
    }

    private static func permissionRequest(id: String, session: SessionId) throws -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"), "id": .string(id), "method": .string(permissionMethod),
            "params": try WireRoundTrip.encode(RequestPermissionRequest.stub(for: session)),
        ])
    }

    private static func connect() async -> (
        client: ClientSideConnection, agentEnd: InMemoryTransport, arrivals: AsyncStream<UInt64?>
    ) {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let (arrivals, continuation) = AsyncStream.makeStream(of: UInt64?.self)
        let client = await ClientSideConnection(stream: clientEnd) { _ in RecordingClient(arrivals: continuation) }
        return (client, agentEnd, arrivals)
    }

    @Test func aNestedReplayAndAnImmediateRequestAreInOneWireOrder() async throws {
        let (client, agentEnd, arrivals) = await Self.connect()
        defer {
            await client.close()
            agentEnd.close()
        }
        let reader = WireReader(agentEnd)
        var events = client.subscribeToAllSessions().events.makeAsyncIterator()
        let resume = Task {
            try await client.resumeSession(ResumeSessionRequest(cwd: AbsolutePath(rawValue: "/work"), sessionId: Self.root))
        }
        let resumeId = try #require(requestID(of: try await reader.next()))
        try await send(sessionUpdateEnvelope(Self.announce(Self.root, child: Self.child)), over: agentEnd)
        try await send(sessionUpdateEnvelope(Self.announce(Self.child, child: Self.grandchild)), over: agentEnd)
        try await send(responseEnvelope(id: resumeId, result: ResumeSessionResponse()), over: agentEnd)
        _ = try await resume.value
        try await send(Self.permissionRequest(id: "perm-1", session: Self.grandchild), over: agentEnd)

        let first = try #require(await events.next())
        let second = try #require(await events.next())
        let marker = try #require(await events.next())
        var arrivalIterator = arrivals.makeAsyncIterator()
        let arrivalOrNil = try #require(await arrivalIterator.next())
        let arrival = try #require(arrivalOrNil)

        #expect([first.sessionId, second.sessionId, marker.sessionId] == [Self.root, Self.child, Self.root])
        #expect(first.sequence < second.sequence)
        #expect(second.sequence < marker.sequence)
        #expect(marker.sequence < arrival)
    }

    @Test func theResumeMarkerIsInTheSingleStreamAtTheWirePositionOfTheResponse() async throws {
        let (client, agentEnd, _) = await Self.connect()
        defer {
            await client.close()
            agentEnd.close()
        }
        let reader = WireReader(agentEnd)
        var events = client.subscribeToAllSessions().events.makeAsyncIterator()
        let resume = Task {
            try await client.resumeSession(ResumeSessionRequest(cwd: AbsolutePath(rawValue: "/work"), sessionId: Self.root))
        }
        let resumeId = try #require(requestID(of: try await reader.next()))
        try await send(sessionUpdateEnvelope(Self.announce(Self.child, child: Self.grandchild)), over: agentEnd)
        try await send(responseEnvelope(id: resumeId, result: ResumeSessionResponse()), over: agentEnd)
        _ = try await resume.value
        try await send(sessionUpdateEnvelope(Self.announce(Self.child, child: Self.grandchild)), over: agentEnd)

        let kinds = [try #require(await events.next()), try #require(await events.next()), try #require(await events.next())]
            .map(\.event)
        guard case .update = kinds[0], case .requestFinished(let id, let method, let outcome) = kinds[1], case .update = kinds[2] else {
            Issue.record("expected update, marker, update; got \(kinds)")
            return
        }
        #expect(id == resumeId)
        #expect(method == Self.resumeMethod)
        #expect(outcome == .succeeded)
    }

    @Test func eventsBeforeTheFirstSubscriberAreKeptInOrder() async throws {
        let (client, agentEnd, _) = await Self.connect()
        defer {
            await client.close()
            agentEnd.close()
        }
        try await send(sessionUpdateEnvelope(Self.announce(Self.root, child: Self.child)), over: agentEnd)
        try await send(sessionUpdateEnvelope(Self.announce(Self.child, child: Self.grandchild)), over: agentEnd)
        // A per-session subscriber proves the router read both frames.
        var childUpdates = client.subscribe(to: Self.child).updates.makeAsyncIterator()
        _ = await childUpdates.nextUpdate()

        let subscription = client.subscribeToAllSessions()
        var events = subscription.events.makeAsyncIterator()
        #expect(try #require(await events.next()).sessionId == Self.root)
        #expect(try #require(await events.next()).sessionId == Self.child)
        #expect(subscription.sessionsWithMissedEvents.isEmpty)
    }

    @Test func anOverflowBeforeTheFirstSubscriberMarksTheSessions() async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let (_, continuation) = AsyncStream.makeStream(of: UInt64?.self)
        let limits = SessionUpdateBufferLimits(maximumUpdatesPerSession: 1, maximumSessions: 1)
        let client = await ClientSideConnection(stream: clientEnd, bufferLimits: limits) { _ in
            RecordingClient(arrivals: continuation)
        }
        defer {
            await client.close()
            agentEnd.close()
        }
        // A per-session subscriber proves the router read both frames.
        var probe = client.subscribe(to: Self.root).updates.makeAsyncIterator()
        try await send(sessionUpdateEnvelope(Self.announce(Self.root, child: Self.child)), over: agentEnd)
        try await send(sessionUpdateEnvelope(Self.announce(Self.root, child: Self.grandchild)), over: agentEnd)
        _ = await probe.nextUpdate()
        _ = await probe.nextUpdate()

        #expect(client.subscribeToAllSessions().sessionsWithMissedEvents == [Self.root])
    }

    @Test func theStreamFinishesWhenTheConnectionCloses() async throws {
        let (client, agentEnd, _) = await Self.connect()
        defer { agentEnd.close() }
        var events = client.subscribeToAllSessions().events.makeAsyncIterator()
        await client.close()
        #expect(await events.next() == nil)
    }
}
