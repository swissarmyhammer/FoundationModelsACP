import Foundation
import FoundationModelsACP

/// The reference script of a correct agent for nested sub-agent sessions.
///
/// The scenario has a root session, two children of the root, and a
/// grandchild below each child:
///
/// - `child-1` restored. It has the grandchild `grandchild-1`.
/// - `child-2` failed to restore. It has the grandchild `grandchild-2`, which
///   fails because its ancestor was not restored.
///
/// The agent plays the script when the client resumes the root session. The
/// order follows the "Ordering" rule of ACP v2 "Session Setup":
///
/// 1. **History** (the replay). Each update is history. It confirms nothing
///    about the state now.
/// 2. **A `subagent_update` for each child that the root lists in
///    `background`.** It comes before the snapshot that lists the child. The
///    client treats it as unconfirmed, because a child snapshot before the
///    response is historical.
/// 3. **The current `state_update` of the root**, with the background list.
/// 4. **A `session_info_update`.**
/// 5. **The `session/resume` response.**
/// 6. **Current snapshots**, after the response. A `subagent_update` here
///    replaces the state of its child. An omitted `state` means the state is
///    unknown. A child that failed to restore has no state and carries
///    `SAH.RestoreFailure`, as does each descendant of that child.
/// 7. **A child elicitation** for `child-1`. The agent waits for the answer.
/// 8. **The finish.** `grandchild-1`, then `child-1`, report `idle`. The last
///    update is the final `tool_call_update` of the `agents` call that started
///    `child-1`. It comes after the last update of the child. A client removes
///    the child at that update.
///
/// Every announcement of a child is a `subagent_update` in the stream of its
/// parent. Its `_meta.sah.agentRun.toolCallId` names the tool call that
/// started the child. That tool call carries `_meta.sah.agentRun.sessionId`.
enum NestedSubagentScenario {
    /// The name that selects this scenario: `--scenario nested-subagents`.
    static let name = "nested-subagents"

    static let root = SessionId(rawValue: "root")
    static let child = SessionId(rawValue: "child-1")
    static let grandchild = SessionId(rawValue: "grandchild-1")
    static let failedChild = SessionId(rawValue: "child-2")
    static let failedGrandchild = SessionId(rawValue: "grandchild-2")

    /// The `agents` tool call in the root session that started `child-1`.
    static let childCall = ToolCallId(rawValue: "call-child-1")
    /// The `agents` tool call in the root session that started `child-2`.
    static let failedChildCall = ToolCallId(rawValue: "call-child-2")
    /// The `agents` tool call in `child-1` that started `grandchild-1`.
    static let grandchildCall = ToolCallId(rawValue: "call-grandchild-1")
    /// The `agents` tool call in `child-2` that started `grandchild-2`.
    static let failedGrandchildCall = ToolCallId(rawValue: "call-grandchild-2")

    /// The reason of the child that failed to restore.
    static let failedChildReason = "the session file is missing"
    /// The reason of each descendant of a child that failed to restore.
    static let ancestorReason = "an ancestor was not restored"

    /// The question of the child elicitation.
    static let elicitationMessage = "Which source should the researcher read?"

    // MARK: - The script

    /// The history, in wire order. The agent sends it before the response.
    static var history: [UpdateSessionNotification] {
        get throws {
            [
                note(root, .userMessage(UserMessage(
                    messageId: MessageId(rawValue: "root-user-1"),
                    content: .value([.text(TextContent(text: "Research the topic"))])))),
                note(root, try agentsCall(childCall, started: child)),
                note(root, try announcement(child, parentCall: childCall, title: "Researcher", state: .running(RunningStateUpdate()))),
                note(child, .agentMessage(AgentMessage(
                    messageId: MessageId(rawValue: "child-agent-1"),
                    content: .value([.text(TextContent(text: "Looking at the sources"))])))),
                note(child, try agentsCall(grandchildCall, started: grandchild)),
                note(child, try announcement(grandchild, parentCall: grandchildCall, title: "Reader", state: .running(RunningStateUpdate()))),
                note(grandchild, .agentMessage(AgentMessage(
                    messageId: MessageId(rawValue: "grandchild-agent-1"),
                    content: .value([.text(TextContent(text: "Reading the first page"))])))),
                note(root, try agentsCall(failedChildCall, started: failedChild)),
                note(root, try announcement(failedChild, parentCall: failedChildCall, title: "Archivist", state: .running(RunningStateUpdate()))),
                note(failedChild, try agentsCall(failedGrandchildCall, started: failedGrandchild)),
                note(failedChild, try announcement(failedGrandchild, parentCall: failedGrandchildCall, title: "Indexer", state: .running(RunningStateUpdate()))),
            ]
        }
    }

    /// The current snapshots, in wire order. The agent sends them after the
    /// response. They replace the state of each child that the replay and the
    /// updates before the response gave.
    static var currentSnapshots: [UpdateSessionNotification] {
        get throws {
            [
                note(root, try announcement(
                    child, parentCall: childCall, title: "Researcher", state: .running(RunningStateUpdate()),
                    capabilities: SubagentSessionCapabilities(cancel: SessionCancelCapabilities()))),
                note(child, try announcement(
                    grandchild, parentCall: grandchildCall, title: "Reader", state: .running(RunningStateUpdate()))),
                // A child that failed to restore: no state, so the state is unknown.
                note(root, try announcement(
                    failedChild, parentCall: failedChildCall, title: "Archivist", state: nil,
                    failure: failedChildReason)),
                note(failedChild, try announcement(
                    failedGrandchild, parentCall: failedGrandchildCall, title: "Indexer", state: nil,
                    failure: ancestorReason)),
            ]
        }
    }

    /// The updates between the history and the response, in wire order: a
    /// `subagent_update` for each listed child, the current `state_update` of
    /// the root with the background list, and a `session_info_update`.
    static var beforeResponse: [UpdateSessionNotification] {
        get throws {
            [
                note(root, try announcement(
                    child, parentCall: childCall, title: "Researcher", state: .running(RunningStateUpdate()))),
                note(root, try announcement(
                    failedChild, parentCall: failedChildCall, title: "Archivist", state: .running(RunningStateUpdate()))),
                note(root, .stateUpdate(.running(RunningStateUpdate(background: [
                    .subagent(BackgroundSubagent(sessionId: child)),
                    .subagent(BackgroundSubagent(sessionId: failedChild)),
                ])))),
                note(root, .sessionInfoUpdate(SessionInfoUpdate(title: .value("Research the topic")))),
            ]
        }
    }

    /// The question that the agent asks for `child-1`, after the current
    /// snapshots.
    static var elicitation: CreateElicitationRequest {
        CreateElicitationRequest(
            message: elicitationMessage,
            mode: .form(ElicitationFormMode(
                requestedSchema: ElicitationSchema(
                    properties: .object(["source": .object(["type": .string("string")])]),
                    type: .object),
                scope: .session(ElicitationSessionScope(sessionId: child)))))
    }

    /// The finish, in wire order. The agent sends it after the answer of the
    /// client. The last update is the final update of the tool call that
    /// started `child-1`.
    static var finish: [UpdateSessionNotification] {
        get throws {
            [
                note(child, .agentMessage(AgentMessage(
                    messageId: MessageId(rawValue: "child-agent-2"),
                    content: .value([.text(TextContent(text: "The research is done"))])))),
                note(child, try announcement(
                    grandchild, parentCall: grandchildCall, title: "Reader",
                    state: .idle(IdleStateUpdate(stopReason: .endTurn)))),
                note(child, try finalCall(grandchildCall, started: grandchild)),
                note(root, try announcement(
                    child, parentCall: childCall, title: "Researcher",
                    state: .idle(IdleStateUpdate(stopReason: .endTurn)))),
                note(root, try finalCall(childCall, started: child)),
            ]
        }
    }

    // MARK: - Builders

    private static func note(_ session: SessionId, _ update: SessionUpdate) -> UpdateSessionNotification {
        UpdateSessionNotification(sessionId: session, update: update)
    }

    /// The `tool_call_update` that shows an `agents` call, and links it to the
    /// child it started.
    private static func agentsCall(_ call: ToolCallId, started child: SessionId) throws -> SessionUpdate {
        .toolCallUpdate(ToolCallUpdate(
            toolCallId: call,
            name: .value("agents"),
            status: .value(.inProgress),
            title: .value("Run an agent"),
            meta: .value(try SAH.AgentRun(sessionId: child).inject(into: nil))))
    }

    /// The final `tool_call_update` of an `agents` call.
    private static func finalCall(_ call: ToolCallId, started child: SessionId) throws -> SessionUpdate {
        .toolCallUpdate(ToolCallUpdate(
            toolCallId: call,
            status: .value(.completed),
            meta: .value(try SAH.AgentRun(sessionId: child).inject(into: nil))))
    }

    /// A `subagent_update`. Its `_meta.sah` object carries every member that
    /// must stay, because ACP patches `_meta` by top-level key.
    private static func announcement(
        _ session: SessionId,
        parentCall: ToolCallId,
        title: String,
        state: StateUpdate?,
        capabilities: SubagentSessionCapabilities? = nil,
        failure: String? = nil
    ) throws -> SessionUpdate {
        var meta = try SAH.AgentRun(toolCallId: parentCall).inject(into: nil)
        if let failure {
            meta = try SAH.RestoreFailure(reason: failure).inject(into: meta)
        }
        return .subagentUpdate(SubagentUpdate(
            sessionId: session,
            capabilities: capabilities.map { .value($0) } ?? .unchanged,
            state: state.map { .value($0) } ?? .unchanged,
            title: .value(title),
            meta: .value(meta)))
    }

    // MARK: - Playing the script

    /// Plays the history and the updates before the response on a resume of the
    /// root session. The agent calls this in the handler of `session/resume`,
    /// so these updates are before the response. The rest of the script runs
    /// after the response.
    ///
    /// - Parameter connection: The connection to the client.
    static func resume(on connection: AgentSideConnection) async throws -> ResumeSessionResponse {
        for notification in try history + beforeResponse {
            try await connection.sessionUpdate(notification)
        }
        connection.afterRespondingToCurrentRequest {
            do {
                try await playCurrentSnapshotsAndFinish(on: connection)
            } catch {
                FileHandle.standardError.write(Data("acp-test-agent: scenario failed: \(error)\n".utf8))
            }
        }
        return ResumeSessionResponse()
    }

    private static func playCurrentSnapshotsAndFinish(on connection: AgentSideConnection) async throws {
        for notification in try currentSnapshots {
            try await connection.sessionUpdate(notification)
        }
        _ = try await connection.createElicitation(elicitation)
        for notification in try finish {
            try await connection.sessionUpdate(notification)
        }
    }
}
