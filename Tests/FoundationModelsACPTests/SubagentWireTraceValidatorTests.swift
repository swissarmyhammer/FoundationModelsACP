import Foundation
import Testing

@testable import FoundationModelsACP

/// `SubagentWireTraceValidator`: the conformance oracle for sub-agent wire
/// traces. The nested scenario of `acp-test-agent` must pass. One mutated copy
/// of its trace for each rule must fail with that rule.
@Suite struct SubagentWireTraceValidatorTests {
    private static let root = SessionId(rawValue: "root")
    private static let child = SessionId(rawValue: "child-1")
    private static let failedGrandchild = SessionId(rawValue: "grandchild-2")
    private static let failedChild = SessionId(rawValue: "child-2")
    private static let childCall = ToolCallId(rawValue: "call-child-1")

    /// Runs the real scenario and records its trace in wire order. The
    /// elicitation request is the one that the client saw, placed by its
    /// wire sequence number.
    private func recordedTrace() async throws -> [WireTraceEvent] {
        let recording = try await NestedScenarioRun.play()
        let request = recording.request
        let requestPosition = try #require(recording.events.firstIndex { $0.sequence > request.arrival })
        let observed = WireTraceEvent.agentRequest(
            id: .number(Double(request.arrival)), method: request.method, sessionId: request.sessionId)
        return [.resumeRequest(id: recording.resumeId, sessionId: Self.root)]
            + recording.events[..<requestPosition].compactMap(WireTraceEvent.init)
            + [observed]
            + recording.events[requestPosition...].compactMap(WireTraceEvent.init)
    }

    private func rules(_ trace: [WireTraceEvent]) -> Set<SubagentWireTraceValidator.Rule> {
        Set(SubagentWireTraceValidator().validate(trace).map(\.rule))
    }

    private func index(in trace: [WireTraceEvent], where match: (WireTraceEvent) -> Bool) throws -> Int {
        let found = trace.firstIndex(where: match)
        return try #require(found)
    }

    private static func isRootState(_ event: WireTraceEvent) -> Bool {
        if case .update(Self.root, .stateUpdate) = event { return true } else { return false }
    }

    private static func isResponse(_ event: WireTraceEvent) -> Bool {
        if case .resumeResponse = event { return true } else { return false }
    }

    private static func isRequest(_ event: WireTraceEvent) -> Bool {
        if case .agentRequest = event { return true } else { return false }
    }

    /// Moves the first event that matches to the position `offset` events
    /// after the response, counted after the move.
    private func moving(
        _ trace: [WireTraceEvent], where match: (WireTraceEvent) -> Bool, afterResponseBy offset: Int
    ) throws -> [WireTraceEvent] {
        var moved = trace
        let event = moved.remove(at: try index(in: moved, where: match))
        let response = try index(in: moved, where: Self.isResponse)
        moved.insert(event, at: response + offset)
        return moved
    }

    /// Changes the first `subagent_update` of a session that matches.
    private func changingSubagentUpdate(
        in trace: [WireTraceEvent],
        where match: (SubagentUpdate) -> Bool,
        _ change: (inout SubagentUpdate) throws -> Void
    ) throws -> [WireTraceEvent] {
        var changed = trace
        let position = try index(in: changed) {
            if case .update(_, .subagentUpdate(let update)) = $0 { return match(update) } else { return false }
        }
        guard case .update(let session, .subagentUpdate(var update)) = changed[position] else { return changed }
        try change(&update)
        changed[position] = .update(sessionId: session, update: .subagentUpdate(update))
        return changed
    }

    /// Changes the current snapshot of the child that failed to restore.
    private func changingFailedChildSnapshot(
        in trace: [WireTraceEvent], _ change: (inout SubagentUpdate) throws -> Void
    ) throws -> [WireTraceEvent] {
        try changingSubagentUpdate(
            in: trace,
            where: { update in
                guard update.sessionId == Self.failedChild, case .value(let meta) = update.meta else { return false }
                return SAH.RestoreFailure.extract(from: meta) != nil
            }, change)
    }

    @Test func theNestedScenarioPasses() async throws {
        let trace = try await recordedTrace()
        let violations = SubagentWireTraceValidator().validate(trace)
        #expect(violations == [], "\(violations)")
    }

    @Test func aSecondResumeStartsANewWindowAndPasses() async throws {
        let trace = try await recordedTrace()
        let violations = SubagentWireTraceValidator().validate(trace + trace)
        #expect(violations == [], "\(violations)")
    }

    /// Two resumes on one connection, with `event` put directly after the
    /// second resume request, or after the first update of the replay of the
    /// second resume.
    private func secondResume(
        with event: WireTraceEvent, afterReplayStart: Bool = false
    ) async throws -> [WireTraceEvent] {
        let trace = try await recordedTrace()
        var twice = trace + trace
        let secondRequest = trace.count
        twice.insert(event, at: secondRequest + (afterReplayStart ? 2 : 1))
        return twice
    }

    private static let liveChildState = WireTraceEvent.update(
        sessionId: child, update: .stateUpdate(.running(RunningStateUpdate())))

    @Test func aLiveUpdateOfAnAnnouncedSessionBeforeTheReplayStartsPasses() async throws {
        let trace = try await secondResume(with: Self.liveChildState)
        let violations = SubagentWireTraceValidator().validate(trace)
        #expect(violations == [], "\(violations)")
    }

    @Test func rule3_anUpdateOfASessionThatWasNeverAnnouncedBeforeTheReplayStartsIsAViolation() async throws {
        let stranger = SessionId(rawValue: "stranger")
        let trace = try await secondResume(
            with: .update(sessionId: stranger, update: .stateUpdate(.running(RunningStateUpdate()))))
        #expect(rules(trace).contains(.announceBeforeUse))
    }

    @Test func rule2_aStateUpdateOfAnAnnouncedChildAfterTheReplayStartsIsAViolation() async throws {
        let trace = try await secondResume(with: Self.liveChildState, afterReplayStart: true)
        #expect(rules(trace).contains(.noHistoricalStateAsCurrent))
    }

    @Test func rule1_aSessionInfoUpdateBeforeTheCurrentStateIsAViolation() async throws {
        var trace = try await recordedTrace()
        let state = try index(in: trace, where: Self.isRootState)
        trace.swapAt(state, state + 1)
        #expect(rules(trace).contains(.resumeOrder))
    }

    @Test func rule2_aSecondStateUpdateInTheReplayIsAViolation() async throws {
        var trace = try await recordedTrace()
        let state = try index(in: trace, where: Self.isRootState)
        trace.insert(trace[state], at: state)
        #expect(rules(trace).contains(.noHistoricalStateAsCurrent))
    }

    @Test func rule2_aStateUpdateOfAnotherSessionInTheReplayIsAViolation() async throws {
        var trace = try await recordedTrace()
        let response = try index(in: trace, where: Self.isResponse)
        trace.insert(.update(sessionId: Self.child, update: .stateUpdate(.running(RunningStateUpdate()))), at: response)
        #expect(rules(trace).contains(.noHistoricalStateAsCurrent))
    }

    @Test func rule3_aChildThatIsNeverAnnouncedIsAViolation() async throws {
        let trace = try await recordedTrace().filter {
            if case .update(_, .subagentUpdate(let update)) = $0, update.sessionId == Self.child { return false }
            return true
        }
        #expect(rules(trace).contains(.announceBeforeUse))
    }

    @Test func rule4_aRequestForAChildBeforeItsCurrentSnapshotIsAViolation() async throws {
        let trace = try moving(try await recordedTrace(), where: Self.isRequest, afterResponseBy: 1)
        #expect(rules(trace).contains(.currentSnapshotAfterResponse))
    }

    @Test func rule4_capabilitiesBeforeTheResponseAreAViolation() async throws {
        let trace = try changingSubagentUpdate(in: try await recordedTrace(), where: { $0.sessionId == Self.child }) {
            $0.capabilities = .value(SubagentSessionCapabilities(cancel: SessionCancelCapabilities()))
        }
        #expect(rules(trace).contains(.currentSnapshotAfterResponse))
    }

    @Test func rule5_aChildEventAfterTheResponseBeforeItsSnapshotIsAViolation() async throws {
        let trace = try moving(
            try await recordedTrace(),
            where: { if case .update(Self.child, .agentMessage) = $0 { return true } else { return false } },
            afterResponseBy: 1)
        #expect(rules(trace).contains(.childHistoryBeforeResponse))
    }

    @Test func rule6_aRequestInsideTheReplayIsAViolation() async throws {
        var trace = try await recordedTrace()
        let response = try index(in: trace, where: Self.isResponse)
        trace.insert(.agentRequest(id: .string("replayed"), method: "session/request_permission", sessionId: Self.root), at: response)
        #expect(rules(trace).contains(.noReplayedRequests))
    }

    @Test func rule7_aPartialSahObjectIsAViolation() async throws {
        let trace = try changingFailedChildSnapshot(in: try await recordedTrace()) {
            $0.meta = .value(try SAH.RestoreFailure(reason: "r").inject(into: nil))
        }
        #expect(rules(trace).contains(.wholeSahObject))
    }

    @Test func rule8_theFinalToolCallBeforeTheLastChildUpdateIsAViolation() async throws {
        var trace = try await recordedTrace()
        let final = trace.count - 1
        trace.swapAt(final, final - 1)
        #expect(rules(trace).contains(.finalToolCallLast))
    }

    @Test func rule9_aStateUpdateWithoutTheBackgroundListIsAViolation() async throws {
        var trace = try await recordedTrace()
        trace.insert(.update(sessionId: Self.root, update: .stateUpdate(.running(RunningStateUpdate()))), at: trace.count - 2)
        #expect(rules(trace).contains(.backgroundList))
    }

    @Test func rule9_aListedChildThatIsNotAnnouncedIsAViolation() async throws {
        let trace = try await recordedTrace().filter {
            if case .update(_, .subagentUpdate(let update)) = $0, update.sessionId == Self.failedChild { return false }
            return true
        }
        #expect(rules(trace).contains(.backgroundList))
    }

    @Test func rule9_aDroppedChildThatIsStillRunningIsAViolation() async throws {
        var trace = try await recordedTrace()
        let response = try index(in: trace, where: Self.isResponse)
        let dropping = StateUpdate.running(RunningStateUpdate(background: [
            .subagent(BackgroundSubagent(sessionId: Self.failedChild))
        ]))
        trace.insert(.update(sessionId: Self.root, update: .stateUpdate(dropping)), at: response + 5)
        #expect(rules(trace).contains(.backgroundList))
    }

    @Test func rule10_aFailedChildWithAStateIsAViolation() async throws {
        let trace = try changingFailedChildSnapshot(in: try await recordedTrace()) {
            $0.state = .value(.running(RunningStateUpdate()))
        }
        #expect(rules(trace).contains(.failedChild))
    }

    @Test func rule10_aFailedChildWithCapabilitiesIsAViolation() async throws {
        let trace = try changingFailedChildSnapshot(in: try await recordedTrace()) {
            $0.capabilities = .value(SubagentSessionCapabilities(cancel: SessionCancelCapabilities()))
        }
        #expect(rules(trace).contains(.failedChild))
    }

    @Test func rule10_aDescendantOfAFailedChildWithoutTheFailureIsAViolation() async throws {
        let trace = try changingSubagentUpdate(
            in: try await recordedTrace(),
            where: { update in
                guard update.sessionId == Self.failedGrandchild, case .value(let meta) = update.meta else { return false }
                return SAH.RestoreFailure.extract(from: meta) != nil
            }
        ) {
            $0.meta = .value(try SAH.AgentRun(toolCallId: ToolCallId(rawValue: "call-grandchild-2")).inject(into: nil))
        }
        #expect(rules(trace).contains(.failedChild))
    }

    @Test func aViolationNamesTheRuleAndThePosition() async throws {
        var trace = try await recordedTrace()
        let response = try index(in: trace, where: Self.isResponse)
        trace.insert(.agentRequest(id: .string("replayed"), method: "elicitation/create", sessionId: Self.root), at: response)
        let violations = SubagentWireTraceValidator().validate(trace)
        let violation = try #require(violations.first { $0.rule == .noReplayedRequests })
        #expect(violation.position == response)
    }

    // MARK: tool call ids are scoped to their session

    /// A live trace in which the root and its child both have a tool call
    /// with the id `call-1`. The root call starts the child. The child call
    /// starts the grandchild. The root call is seen after the child call. The
    /// final update of a call has no `_meta`.
    private func sharedCallIdTrace(rootCallFinishesBeforeChildIdle: Bool = false) throws -> [WireTraceEvent] {
        let call = ToolCallId(rawValue: "call-1")
        let child = SessionId(rawValue: "child-1")
        let grandchild = SessionId(rawValue: "grandchild-1")
        func toolCall(_ session: SessionId, started: SessionId, status: ToolCallStatus) throws -> WireTraceEvent {
            .update(
                sessionId: session,
                update: .toolCallUpdate(ToolCallUpdate(
                    toolCallId: call, name: .value("agents"), status: .value(status),
                    // Only the first update of a call carries the link. A later
                    // update leaves `_meta` as it is.
                    meta: status == .inProgress
                        ? .value(try SAH.AgentRun(sessionId: started).inject(into: nil)) : .unchanged)))
        }
        func announce(_ session: SessionId, in parent: SessionId, _ state: StateUpdate) -> WireTraceEvent {
            .update(
                sessionId: parent,
                update: .subagentUpdate(SubagentUpdate(sessionId: session, state: .value(state))))
        }
        let running = StateUpdate.running(RunningStateUpdate())
        let idle = StateUpdate.idle(IdleStateUpdate(stopReason: .endTurn))
        var trace: [WireTraceEvent] = [
            announce(child, in: Self.root, running),
            try toolCall(child, started: grandchild, status: .inProgress),
            announce(grandchild, in: child, running),
            try toolCall(Self.root, started: child, status: .inProgress),
            announce(grandchild, in: child, idle),
            try toolCall(child, started: grandchild, status: .completed),
        ]
        let rootFinal = try toolCall(Self.root, started: child, status: .completed)
        if rootCallFinishesBeforeChildIdle {
            trace += [rootFinal, announce(child, in: Self.root, idle)]
        } else {
            trace += [announce(child, in: Self.root, idle), rootFinal]
        }
        return trace
    }

    @Test func theSameToolCallIdInTheRootAndAChildIsTwoCalls() throws {
        let trace = try sharedCallIdTrace()
        let violations = SubagentWireTraceValidator().validate(trace)
        #expect(violations == [], "\(violations)")
    }

    @Test func rule8_theFinalRootCallBeforeTheLastChildUpdateFailsWithTheSameIdInTheChild() throws {
        let violations = SubagentWireTraceValidator().validate(
            try sharedCallIdTrace(rootCallFinishesBeforeChildIdle: true))
        #expect(violations.map(\.rule).contains(.finalToolCallLast), "\(violations)")
    }
}
