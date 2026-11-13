import Foundation

/// One message of a recorded wire trace, for ``SubagentWireTraceValidator``.
///
/// A trace is an array of these events in the order that they crossed the
/// wire of one connection. The position of an event in the array is the
/// position that a ``SubagentWireTraceValidator/Violation`` names.
public enum WireTraceEvent: Hashable, Sendable {
    /// The client sent `session/resume` for a session.
    case resumeRequest(id: RequestId, sessionId: SessionId)

    /// The agent answered `session/resume`.
    case resumeResponse(id: RequestId)

    /// The agent sent a `session/update` for a session.
    case update(sessionId: SessionId, update: SessionUpdate)

    /// The agent sent a request that waits on the user, such as
    /// `session/request_permission` or `elicitation/create`.
    case agentRequest(id: RequestId, method: String, sessionId: SessionId)

    /// Makes the trace event of a client-side stream event.
    ///
    /// A session update gives ``update(sessionId:update:)``. The
    /// request-finished marker of `session/resume` gives
    /// ``resumeResponse(id:)``. Other markers give no event. The client
    /// records the resume request and the agent requests itself.
    ///
    /// - Parameter event: The event of ``ClientSideConnection/subscribeToAllSessions()``.
    public init?(_ event: SequencedSessionEvent) {
        switch event.event {
        case .update(let update):
            self = .update(sessionId: event.sessionId, update: update)
        case .requestFinished(let id, let method, _):
            guard method == WireTraceEvent.resumeMethod else { return nil }
            self = .resumeResponse(id: id)
        }
    }

    /// The wire method of `session/resume`.
    private static let resumeMethod = RoleRouting.wireMethod(for: "resumeSession", on: .agent)
}

/// Checks a recorded wire trace against the rules for sub-agent sessions.
///
/// Other packages use it as the test oracle: record the messages of a
/// connection in wire order as ``WireTraceEvent`` values, and call
/// ``validate(_:)``. An empty result means that the trace follows the rules.
/// The nested scenario of `acp-test-agent` is a trace that follows them.
///
/// The rules come from ACP v2 "Session Setup" ("Ordering"), the "Subagent
/// Sessions" RFD, and the SAH decisions. See ``Rule`` for each one.
public struct SubagentWireTraceValidator: Sendable {
    /// A rule of the validator. The raw value is the number of the rule.
    public enum Rule: Int, CaseIterable, Sendable {
        /// Rule 1. The resume order for the resumed session: the replay; then
        /// the pre-response updates of listed background items; then one
        /// current `state_update` (also without `replayFrom`); then
        /// `session_info_update`; then the response.
        case resumeOrder = 1

        /// Rule 2. No historical `state_update` is replayed as current: one
        /// `state_update` of the resumed session before the response, and
        /// none for another session.
        ///
        /// A live update that was in transit is not part of the replay. Between
        /// a resume request and the first update in the stream of the resumed
        /// session, an update of a session that was announced earlier on the
        /// same connection is such an update: the agent could write it before
        /// it read the request. The validator checks no rule on it. The replay
        /// and the current snapshots after the response give its content again.
        case noHistoricalStateAsCurrent

        /// Rule 3. A child is announced by `subagent_update` before any update
        /// in its stream, any request for it, and any `background` item that
        /// names it. The parent is announced before the child. The
        /// `agentRun` link in the `_meta` of a tool call is a link, not an
        /// address: the tool call that starts a child can come first.
        case announceBeforeUse

        /// Rule 4. Current child snapshots come only after the response.
        /// `capabilities` before the response are not allowed, and a
        /// snapshot before the response authorizes no request: a request for
        /// a child needs a `subagent_update` of that child after the response.
        case currentSnapshotAfterResponse

        /// Rule 5. All child history is before the response. The trace shows
        /// it so: after the response, the first thing for a child that was
        /// announced before the response is its current snapshot. An event in
        /// the stream of the child before that snapshot is a violation.
        case childHistoryBeforeResponse

        /// Rule 6. A replay never reissues a permission or elicitation
        /// request: no agent request between the resume request and the
        /// response.
        case noReplayedRequests

        /// Rule 7. `_meta.sah` is never sent partially: an update that carries
        /// `_meta.sah` carries every member that an earlier update of the same
        /// target set.
        case wholeSahObject

        /// Rule 8. The final `tool_call_update` of an `agents` call comes
        /// after the last update of its child and after the final `idle`
        /// state of the child. A tool call id is scoped to its session: the root and
        /// a child can have calls with the same id.
        case finalToolCallLast

        /// Rule 9. `background` is present on every `state_update` of a
        /// session that reported it once. A listed item is announced before
        /// the snapshot that lists it, and finished before the snapshot that
        /// drops it.
        case backgroundList

        /// Rule 10. A child that failed to restore is announced with no
        /// state, no capabilities and `SAH.RestoreFailure`, and so is each of
        /// its descendants.
        case failedChild
    }

    /// One broken rule.
    public struct Violation: Hashable, Sendable {
        /// The rule that the trace breaks.
        public let rule: Rule

        /// The position of the event in the trace that breaks the rule.
        public let position: Int

        /// What is wrong, in short text.
        public let message: String
    }

    /// Makes a validator.
    public init() {}

    /// Checks a trace.
    ///
    /// - Parameter trace: The events of one connection, in wire order.
    /// - Returns: The violations, in the order of their positions. The array
    ///   is empty when the trace follows the rules.
    public func validate(_ trace: [WireTraceEvent]) -> [Violation] {
        var run = Run()
        for (position, event) in trace.enumerated() {
            run.apply(event, at: position)
        }
        run.finish()
        return run.violations.sorted { $0.position < $1.position }
    }
}

// MARK: - The run

extension SubagentWireTraceValidator {
    /// The state of one validation.
    private struct Run {
        /// Where the trace is relative to the resume. The three cases are
        /// exclusive.
        enum Phase {
            /// The trace has no resume request: every update is current.
            case live
            /// Between the resume request and its response: the replay.
            case replaying
            /// After the response of the resume.
            case afterResponse
        }

        var violations: [Violation] = []

        /// The resumed session, or the first session of the trace.
        var root: SessionId?
        var phase = Phase.live
        var hasResume: Bool { phase != .live }
        var inWindow: Bool { phase == .replaying }
        var afterResponse: Bool { phase != .replaying }
        var stateUpdatesInWindow = 0
        var sawRootStateInWindow = false

        /// The sessions announced on the connection before the resume request.
        /// Until the replay starts, an update of one of them is a live update
        /// that was in transit.
        var announcedBeforeRequest: Set<SessionId> = []
        /// Whether the replay started: an update in the stream of the resumed
        /// session came after the resume request.
        var replayStarted = false

        var announced: Set<SessionId> = []
        var unannouncedReported: Set<SessionId> = []
        var announcedBeforeResponse: Set<SessionId> = []
        var currentSnapshot: Set<SessionId> = []
        var parent: [SessionId: SessionId] = [:]

        var sahMembers: [String: Set<String>] = [:]
        /// The child that each tool call starts. A tool call id is scoped to its
        /// session: the root and a child can have calls with the same id.
        var childOfCall: [SessionId: [ToolCallId: SessionId]] = [:]
        var lastStateIsIdle: [SessionId: Bool] = [:]
        var finished: Set<SessionId> = []
        var reportedBackground: [SessionId: [SessionId]] = [:]
        var failed: [SessionId: Int] = [:]
        var carriesFailure: Set<SessionId> = []

        /// Makes a session the root when the trace has no root yet, and
        /// announces it.
        mutating func claimRootIfUnset(_ session: SessionId) {
            if root == nil { root = session }
            if session == root { announced.insert(session) }
        }

        mutating func report(_ rule: Rule, _ position: Int, _ message: String) {
            violations.append(Violation(rule: rule, position: position, message: message))
        }

        mutating func apply(_ event: WireTraceEvent, at position: Int) {
            switch event {
            case .resumeRequest(_, let sessionId):
                // A resume starts a new replay. Nothing from an earlier window
                // carries over, except the violations.
                let earlier = violations
                let earlierAnnounced = announced
                self = Run()
                violations = earlier
                announcedBeforeRequest = earlierAnnounced
                phase = .replaying
                claimRootIfUnset(sessionId)
            case .resumeResponse:
                if inWindow, !sawRootStateInWindow {
                    report(.resumeOrder, position, "no current state_update before the resume response")
                }
                phase = .afterResponse
                announcedBeforeResponse = announced
            case .agentRequest(_, let method, let sessionId):
                applyRequest(method: method, sessionId: sessionId, at: position)
            case .update(let sessionId, let update):
                applyUpdate(update, in: sessionId, at: position)
            }
        }

        mutating func applyRequest(method: String, sessionId: SessionId, at position: Int) {
            if inWindow {
                report(.noReplayedRequests, position, "\(method) for \(sessionId.rawValue) during the replay")
            }
            claimRootIfUnset(sessionId)
            if !announced.contains(sessionId) {
                report(.announceBeforeUse, position, "\(method) names \(sessionId.rawValue) before it is announced")
            } else if hasResume, sessionId != root, !currentSnapshot.contains(sessionId), !inWindow {
                report(
                    .currentSnapshotAfterResponse, position,
                    "\(method) for \(sessionId.rawValue) before its current snapshot after the response")
            }
        }

        mutating func applyUpdate(_ update: SessionUpdate, in stream: SessionId, at position: Int) {
            if isInTransit(stream) { return }
            claimRootIfUnset(stream)
            if !announced.contains(stream), unannouncedReported.insert(stream).inserted {
                report(.announceBeforeUse, position, "an update in \(stream.rawValue) before it is announced")
            }
            if finished.contains(stream) {
                report(.finalToolCallLast, position, "an update in \(stream.rawValue) after its final tool call")
            }
            if afterResponse, hasResume, stream != root, announcedBeforeResponse.contains(stream),
                !currentSnapshot.contains(stream)
            {
                report(
                    .childHistoryBeforeResponse, position,
                    "an update in \(stream.rawValue) after the response, before its current snapshot")
            }
            if inWindow, sawRootStateInWindow {
                if case .sessionInfoUpdate = update, stream == root {} else {
                    report(.resumeOrder, position, "only session_info_update may follow the current state_update")
                }
            }
            switch update {
            case .subagentUpdate(let subagent):
                applySubagent(subagent, in: stream, at: position)
            case .stateUpdate(let state):
                applyState(state, in: stream, at: position)
            case .sessionInfoUpdate:
                if inWindow, stream == root, !sawRootStateInWindow {
                    report(.resumeOrder, position, "session_info_update before the current state_update")
                }
            case .toolCallUpdate(let call):
                applyToolCall(call, in: stream, at: position)
            default:
                break
            }
        }

        /// Whether an update in a stream is a live update that was in transit
        /// at the resume request. It also records the start of the replay.
        ///
        /// - Parameter stream: The session of the update.
        /// - Returns: `true` when the validator must skip the update.
        mutating func isInTransit(_ stream: SessionId) -> Bool {
            guard inWindow, !replayStarted else { return false }
            if stream == root {
                replayStarted = true
                return false
            }
            return announcedBeforeRequest.contains(stream)
        }

        mutating func applySubagent(_ update: SubagentUpdate, in stream: SessionId, at position: Int) {
            let child = update.sessionId
            if !announced.contains(child) {
                announced.insert(child)
                parent[child] = stream
            }
            if finished.contains(child) {
                report(.finalToolCallLast, position, "a subagent_update of \(child.rawValue) after its final tool call")
            }
            if afterResponse { currentSnapshot.insert(child) }
            if !afterResponse, hasResume, case .value = update.capabilities {
                report(.currentSnapshotAfterResponse, position, "capabilities of \(child.rawValue) before the response")
            }
            if case .value(let state) = update.state {
                if case .idle = state { lastStateIsIdle[child] = true } else { lastStateIsIdle[child] = false }
            }
            checkSah(update.meta, key: "child:\(child.rawValue)", at: position)
            if case .value(let meta) = update.meta, SAH.RestoreFailure.extract(from: meta) != nil {
                carriesFailure.insert(child)
                if failed[child] == nil { failed[child] = position }
                if case .value = update.state {
                    report(.failedChild, position, "failed child \(child.rawValue) has a state")
                }
                if case .value = update.capabilities {
                    report(.failedChild, position, "failed child \(child.rawValue) has capabilities")
                }
            }
        }

        mutating func applyState(_ state: StateUpdate, in stream: SessionId, at position: Int) {
            if inWindow {
                if stream == root {
                    stateUpdatesInWindow += 1
                    if stateUpdatesInWindow > 1 {
                        report(.noHistoricalStateAsCurrent, position, "a second state_update before the response")
                    }
                    sawRootStateInWindow = true
                } else {
                    report(
                        .noHistoricalStateAsCurrent, position,
                        "a state_update of \(stream.rawValue) before the response is history replayed as current")
                }
            }
            let background: [BackgroundWork]?
            switch state {
            case .running(let running):
                background = running.background
                lastStateIsIdle[stream] = false
            case .idle(let idle):
                background = idle.background
                lastStateIsIdle[stream] = true
            case .requiresAction(let action):
                background = action.background
                lastStateIsIdle[stream] = false
            case .unknown:
                background = nil
            }
            guard let background else {
                if reportedBackground[stream] != nil {
                    report(.backgroundList, position, "state_update of \(stream.rawValue) without background")
                }
                return
            }
            let listed = background.compactMap { work -> SessionId? in
                if case .subagent(let subagent) = work { return subagent.sessionId }
                return nil
            }
            for child in listed where !announced.contains(child) {
                report(.backgroundList, position, "background lists \(child.rawValue) before it is announced")
            }
            for dropped in (reportedBackground[stream] ?? []) where !listed.contains(dropped) {
                if !finished.contains(dropped), lastStateIsIdle[dropped] != true {
                    report(.backgroundList, position, "background drops \(dropped.rawValue) before it finished")
                }
            }
            reportedBackground[stream] = listed
        }

        mutating func applyToolCall(_ call: ToolCallUpdate, in stream: SessionId, at position: Int) {
            checkSah(call.meta, key: "call:\(stream.rawValue)/\(call.toolCallId.rawValue)", at: position)
            if case .value(let meta) = call.meta, let run = SAH.AgentRun.extract(from: meta), let child = run.sessionId {
                // The tool call starts the child, so it can come before the
                // announcement. It links to the child. It does not address it.
                childOfCall[stream, default: [:]][call.toolCallId] = child
            }
            guard case .value(let status) = call.status,
                let child = childOfCall[stream]?[call.toolCallId]
            else { return }
            switch status {
            case .completed, .failed, .cancelled:
                if lastStateIsIdle[child] != true {
                    report(.finalToolCallLast, position, "final tool call before the final idle state of \(child.rawValue)")
                }
                finished.insert(child)
                for descendant in descendants(of: child) { finished.insert(descendant) }
            default:
                break
            }
        }

        func descendants(of session: SessionId) -> [SessionId] {
            let children = parent.filter { $0.value == session }.map(\.key)
            return children + children.flatMap { descendants(of: $0) }
        }

        mutating func checkSah(_ meta: PatchField<JSONValue>, key: String, at position: Int) {
            switch meta {
            case .unchanged:
                return
            case .cleared:
                sahMembers[key] = []
            case .value(let value):
                guard case .object(let object) = value, case .object(let sah)? = object[SAH.metaKey] else { return }
                let members = Set(sah.keys)
                let missing = (sahMembers[key] ?? []).subtracting(members)
                if !missing.isEmpty {
                    report(.wholeSahObject, position, "_meta.sah lacks \(missing.sorted().joined(separator: ", "))")
                }
                sahMembers[key, default: []].formUnion(members)
            }
        }

        mutating func finish() {
            for (failedSession, position) in failed {
                for descendant in descendants(of: failedSession) where !carriesFailure.contains(descendant) {
                    report(
                        .failedChild, position,
                        "\(descendant.rawValue) is a descendant of failed \(failedSession.rawValue) without a restore failure")
                }
            }
        }
    }
}
