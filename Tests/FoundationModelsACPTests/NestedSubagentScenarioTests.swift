import Foundation
import Testing

@testable import FoundationModelsACP

/// The nested sub-agent scenario of `acp-test-agent` (`--scenario
/// nested-subagents`): the reference script of correct agent behavior. The
/// test runs the real executable over stdio and checks the order on the wire.
@Suite struct NestedSubagentScenarioTests {
    private static let root = SessionId(rawValue: "root")
    private static let child = SessionId(rawValue: "child-1")
    private static let grandchild = SessionId(rawValue: "grandchild-1")
    private static let failedChild = SessionId(rawValue: "child-2")
    private static let failedGrandchild = SessionId(rawValue: "grandchild-2")
    private static let childCall = ToolCallId(rawValue: "call-child-1")

    /// A client that answers the child elicitation, and tells when it did.
    private struct ElicitedClient: Client {
        let elicitations: AsyncStream<UInt64?>.Continuation

        func sessionUpdate(_ notification: UpdateSessionNotification) async {}

        func requestPermission(_ params: RequestPermissionRequest) async throws -> RequestPermissionResponse {
            throw RequestError.methodNotFound("requestPermission")
        }

        func createElicitation(_ params: CreateElicitationRequest) async throws -> CreateElicitationResponse {
            elicitations.yield(ClientSideConnection.currentRequestArrival)
            return .object(["action": .string("cancel")])
        }

        func elicitationComplete(_ notification: CompleteElicitationNotification) async {}
    }

    /// Plays the scenario, and returns every event up to the final update of
    /// the tool call that started `child-1`, and the arrival number of the
    /// elicitation request.
    private func play() async throws -> (events: [SequencedSessionEvent], elicitationArrival: UInt64?) {
        let transport = try SubprocessTransport(
            executableURL: TransportTestSupport.helperAgentURL, arguments: ["--scenario", "nested-subagents"])
        let (elicitations, continuation) = AsyncStream.makeStream(of: UInt64?.self)
        let client = await ClientSideConnection(stream: transport) { _ in ElicitedClient(elicitations: continuation) }
        var events = client.subscribeToAllSessions().events.makeAsyncIterator()
        do {
            _ = try await client.initialize(handshakeInitializeRequest())
            _ = try await client.resumeSession(ResumeSessionRequest(cwd: AbsolutePath(rawValue: "/work"), sessionId: Self.root))
        } catch {
            await client.close()
            transport.close()
            throw error
        }
        var received: [SequencedSessionEvent] = []
        while let event = await events.next() {
            received.append(event)
            if case .update(.toolCallUpdate(let call)) = event.event, event.sessionId == Self.root,
                call.toolCallId == Self.childCall, call.status == .value(.completed)
            {
                break
            }
        }
        var arrivals = elicitations.makeAsyncIterator()
        let arrival = await arrivals.next() ?? nil
        await client.close()
        transport.close()
        return (received, arrival)
    }

    private static func sessions(_ events: some Sequence<SequencedSessionEvent>) -> [SessionId] {
        events.map(\.sessionId)
    }

    @Test func historyComesBeforeTheResponseAndCurrentSnapshotsAfterIt() async throws {
        let (events, _) = try await play()
        let markerIndex = try #require(events.firstIndex {
            if case .requestFinished = $0.event { return true } else { return false }
        })
        let history = events[..<markerIndex]
        let current = events[(markerIndex + 1)...]

        #expect(Self.sessions(history.prefix(11)) == [
            Self.root, Self.root, Self.root, Self.child, Self.child, Self.child, Self.grandchild,
            Self.root, Self.root, Self.failedChild, Self.failedChild,
        ])
        #expect(Self.sessions(current.prefix(4)) == [Self.root, Self.child, Self.root, Self.failedChild])
    }

    @Test func theCurrentRootStateWithTheBackgroundListComesBeforeTheResponse() async throws {
        let (events, _) = try await play()
        let markerIndex = try #require(events.firstIndex {
            if case .requestFinished = $0.event { return true } else { return false }
        })
        let beforeResponse = events[11..<markerIndex]
        let states = beforeResponse.compactMap { event -> StateUpdate? in
            guard event.sessionId == Self.root, case .update(.stateUpdate(let state)) = event.event else { return nil }
            return state
        }
        let state = try #require(states.first)
        guard case .running(let running) = state else {
            Issue.record("expected a running state, got \(state)")
            return
        }
        #expect(running.background == [
            .subagent(BackgroundSubagent(sessionId: Self.child)),
            .subagent(BackgroundSubagent(sessionId: Self.failedChild)),
        ])
        // A listed child is announced before the snapshot that lists it.
        let announcedIndex = try #require(beforeResponse.firstIndex {
            if case .update(.subagentUpdate(let update)) = $0.event { return update.sessionId == Self.child }
            return false
        })
        let listingIndex = try #require(beforeResponse.firstIndex {
            if case .update(.stateUpdate) = $0.event { return true } else { return false }
        })
        #expect(announcedIndex < listingIndex)
        // The session info update is the last update before the response.
        guard case .update(.sessionInfoUpdate) = try #require(beforeResponse.last).event else {
            Issue.record("expected the session_info_update before the response")
            return
        }
        // No root state_update comes after the response.
        let afterResponse = events[(markerIndex + 1)...]
        #expect(!afterResponse.contains {
            if $0.sessionId == Self.root, case .update(.stateUpdate) = $0.event { return true } else { return false }
        })
    }

    @Test func aChildFailedToRestoreHasNoStateAndCarriesTheRestoreFailure() async throws {
        let (events, _) = try await play()
        let markerIndex = try #require(events.firstIndex {
            if case .requestFinished = $0.event { return true } else { return false }
        })
        let current = events[(markerIndex + 1)...].compactMap { event -> SubagentUpdate? in
            guard case .update(.subagentUpdate(let update)) = event.event else { return nil }
            return update
        }
        let failed = try #require(current.first { $0.sessionId == Self.failedChild })
        let failedDescendant = try #require(current.first { $0.sessionId == Self.failedGrandchild })

        #expect(failed.state == .unchanged)
        guard case .value(let meta) = failed.meta, case .value(let descendantMeta) = failedDescendant.meta else {
            Issue.record("expected _meta on both updates")
            return
        }
        #expect(SAH.RestoreFailure.extract(from: meta) == SAH.RestoreFailure(reason: "the session file is missing"))
        #expect(
            SAH.RestoreFailure.extract(from: descendantMeta) == SAH.RestoreFailure(reason: "an ancestor was not restored"))
        #expect(SAH.AgentRun.extract(from: meta)?.toolCallId == ToolCallId(rawValue: "call-child-2"))
    }

    @Test func theElicitationOfTheChildComesAfterTheResponseAndBeforeTheFinish() async throws {
        let (events, arrival) = try await play()
        let markerIndex = try #require(events.firstIndex {
            if case .requestFinished = $0.event { return true } else { return false }
        })
        let elicitationArrival = try #require(arrival)
        let lastSnapshot = events[markerIndex + 4]
        let finishStart = events[markerIndex + 5]

        #expect(elicitationArrival > lastSnapshot.sequence)
        #expect(elicitationArrival < finishStart.sequence)
    }

    @Test func theFinalToolCallUpdateComesAfterTheLastChildUpdate() async throws {
        let (events, _) = try await play()
        let last = try #require(events.last)
        guard case .update(.toolCallUpdate(let call)) = last.event else {
            Issue.record("expected the final tool_call_update, got \(last)")
            return
        }
        #expect(last.sessionId == Self.root)
        #expect(call.toolCallId == Self.childCall)
        #expect(call.status == .value(.completed))
        let childEvents = events.filter { $0.sessionId == Self.child || $0.sessionId == Self.grandchild }
        #expect(try #require(childEvents.last).sequence < last.sequence)
        let engineOnRoot = events.filter { $0.sessionId == Self.root }.reduce(into: SessionMergeEngine()) { engine, event in
            if case .update(let update) = event.event { engine.apply(update) }
        }
        #expect(engineOnRoot.subagents.map(\.sessionId).contains(Self.child))
    }
}
