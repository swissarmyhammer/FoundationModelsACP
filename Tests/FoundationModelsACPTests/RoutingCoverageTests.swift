import Foundation
import Testing

@testable import FoundationModelsACP

/// End-to-end proof that every routed method reaches the correct side's
/// *handler* — not just that the generated routing table is internally
/// consistent.
///
/// `RoleRoutingTests` (`RoleDispatchTests.swift`, from M2) already pins
/// `ACPMethodTable` itself: every entry's `wireMethod` resolves back to its
/// own `handlerName` and nothing else, on both sides. What that static check
/// cannot see is `AgentSideConnection.serve`/`serveNotification` and
/// `ClientSideConnection.serve`/`serveNotification` — the hand-written switch
/// statements that actually bind each handler name to a Swift method call.
/// Those switches could misroute a case (swap two labels, leaving both arms
/// individually well-typed) and the static table check would never notice,
/// because it never calls either switch. This is exactly the bug class the
/// task references: the real TS-SDK bug wired `setSessionModel` to
/// `session/set_mode` — a hand-written dispatch mistake the routing *data*
/// was innocent of.
///
/// This suite closes that gap by actually dispatching through a live
/// `InMemoryTransport` pair for every stable method, and asserting the
/// **one** handler that fired is the **one** the routing table names for that
/// wire method — no more, no less.
@Suite struct RoutingCoverageTests {
    // MARK: - A recording sink

    /// Records which handler fired, in call order, so a test can assert
    /// "exactly this one ran" rather than merely "no crash happened".
    private actor CallLog {
        private(set) var calls: [String] = []

        func record(_ name: String) {
            calls.append(name)
        }
    }

    // MARK: - Recording Agent

    /// An `Agent` where every method's only job is to record its own name and
    /// return a minimal valid response — the routing table's `handlerName`
    /// strings, verbatim, so a mis-wired case shows up as the wrong string in
    /// `CallLog.calls`.
    private struct RecordingAgent: Agent {
        let log: CallLog

        func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
            await log.record("initialize")
            return InitializeResponse(
                info: Implementation(name: "recording-agent", version: "0.0.0"),
                protocolVersion: .v2,
                capabilities: AgentCapabilities(session: SessionCapabilities())
            )
        }

        func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
            await log.record("newSession")
            return NewSessionResponse(sessionId: SessionId(rawValue: "s1"))
        }

        func listSessions(_ params: ListSessionsRequest) async throws -> ListSessionsResponse {
            await log.record("listSessions")
            return ListSessionsResponse(sessions: [])
        }

        func resumeSession(_ params: ResumeSessionRequest) async throws -> ResumeSessionResponse {
            await log.record("resumeSession")
            return ResumeSessionResponse()
        }

        func closeSession(_ params: CloseSessionRequest) async throws -> CloseSessionResponse {
            await log.record("closeSession")
            return CloseSessionResponse()
        }

        func prompt(_ params: PromptRequest) async throws -> PromptResponse {
            await log.record("prompt")
            return PromptResponse()
        }

        func sessionCancel(_ params: CancelSessionNotification) async {
            await log.record("sessionCancel")
        }

        func loginAuth(_ params: LoginAuthRequest) async throws -> LoginAuthResponse {
            await log.record("loginAuth")
            return LoginAuthResponse()
        }

        func logoutAuth(_ params: LogoutAuthRequest) async throws -> LogoutAuthResponse {
            await log.record("logoutAuth")
            return LogoutAuthResponse()
        }

        func deleteSession(_ params: DeleteSessionRequest) async throws -> DeleteSessionResponse {
            await log.record("deleteSession")
            return DeleteSessionResponse()
        }

        func setSessionConfigOption(
            _ params: SetSessionConfigOptionRequest
        ) async throws -> SetSessionConfigOptionResponse {
            await log.record("setSessionConfigOption")
            return SetSessionConfigOptionResponse(configOptions: [])
        }
    }

    // MARK: - Recording Client

    /// A `Client` where both methods record their own name, mirroring
    /// `RecordingAgent`'s role on the other side.
    private struct RecordingClient: Client {
        let log: CallLog

        func sessionUpdate(_ notification: UpdateSessionNotification) async {
            await log.record("sessionUpdate")
        }

        func requestPermission(
            _ params: RequestPermissionRequest
        ) async throws -> RequestPermissionResponse {
            await log.record("requestPermission")
            return RequestPermissionResponse(
                outcome: .selected(SelectedPermissionOutcome(optionId: PermissionOptionId(rawValue: "allow")))
            )
        }
    }

    // MARK: - Fixtures

    private static let sessionId = SessionId(rawValue: "s1")
    private static let workingDirectory = AbsolutePath(rawValue: "/work")!

    // MARK: - Agent-side coverage

    /// Every wire request/notification the agent side serves, expressed as a
    /// data table (handler name -> the live call that fires it) rather than
    /// one hardcoded test function per method — so the loop below is the only
    /// place that needs to know how to drive each one, and the routing table
    /// itself decides which handlers must be covered.
    ///
    /// `sessionCancel` is a notification (no response to await), so its
    /// driver also performs a trailing `initialize` round trip: `Connection`
    /// documents notifications as "awaited inline" by the read loop, in
    /// arrival order, so awaiting a *later* request's response guarantees the
    /// notification in front of it was already dispatched.
    private static func driveAgentHandler(
        _ handlerName: String,
        client: ClientSideConnection
    ) async throws {
        switch handlerName {
        case "initialize":
            _ = try await client.initialize(InitializeRequest(info: Self.clientInfo, protocolVersion: .v2))
        case "newSession":
            _ = try await client.newSession(NewSessionRequest(cwd: Self.workingDirectory))
        case "listSessions":
            _ = try await client.listSessions(ListSessionsRequest())
        case "resumeSession":
            _ = try await client.resumeSession(ResumeSessionRequest(cwd: Self.workingDirectory, sessionId: Self.sessionId))
        case "closeSession":
            _ = try await client.closeSession(CloseSessionRequest(sessionId: Self.sessionId))
        case "prompt":
            _ = try await client.prompt(
                PromptRequest(prompt: [.text(TextContent(text: "hi"))], sessionId: Self.sessionId)
            )
        case "sessionCancel":
            try await client.sessionCancel(CancelSessionNotification(sessionId: Self.sessionId))
            _ = try await client.initialize(InitializeRequest(info: Self.clientInfo, protocolVersion: .v2))
        case "loginAuth":
            _ = try await client.loginAuth(LoginAuthRequest(methodId: AuthMethodId(rawValue: "m1")))
        case "logoutAuth":
            _ = try await client.logoutAuth(LogoutAuthRequest())
        case "deleteSession":
            _ = try await client.deleteSession(DeleteSessionRequest(sessionId: Self.sessionId))
        case "setSessionConfigOption":
            _ = try await client.setSessionConfigOption(
                SetSessionConfigOptionRequest(
                    configId: SessionConfigId(rawValue: "cfg-1"),
                    sessionId: Self.sessionId,
                    value: .boolean(true)
                )
            )
        default:
            Issue.record("RoutingCoverageTests has no driver wired for agent handler \"\(handlerName)\"")
        }
    }

    private static let clientInfo = Implementation(name: "recording-client", version: "0.0.0")

    @Test func everyAgentMethodReachesExactlyItsOwnHandlerAndNoOther() async throws {
        let agentEntries = ACPMethodTable.methods.filter { $0.side == .agent }
        #expect(!agentEntries.isEmpty, "the routing table named no agent-side entries; this test would vacuously pass")

        for entry in agentEntries {
            let log = CallLog()
            let (clientEnd, agentEnd) = InMemoryTransport.pair()
            let agentConn = await AgentSideConnection(stream: agentEnd) { _ in RecordingAgent(log: log) }
            let client = await ClientSideConnection(stream: clientEnd) { _ in RecordingClient(log: log) }

            try await Self.driveAgentHandler(entry.handlerName, client: client)

            let calls = await log.calls
            // `sessionCancel` is a notification: its driver appends a
            // trailing `initialize` round trip purely to synchronize on the
            // notification having already been dispatched (see
            // `driveAgentHandler`'s doc comment), so it alone expects two
            // recorded calls instead of one.
            let expected = entry.handlerName == "sessionCancel" ? ["sessionCancel", "initialize"] : [entry.handlerName]
            #expect(
                calls == expected,
                "wire method \"\(entry.wireMethod)\" should reach \(expected), reached \(calls) instead"
            )

            await agentConn.close()
            await client.close()
        }
    }

    // MARK: - Client-side coverage

    /// The client-side counterpart of `driveAgentHandler`: drives one
    /// client-served handler through the agent's own outbound surface.
    /// `sessionUpdate` is a notification, so its driver performs a trailing
    /// `requestPermission` round trip for the same reason `sessionCancel`
    /// does above.
    private static func driveClientHandler(
        _ handlerName: String,
        agentConnection: AgentSideConnection
    ) async throws {
        switch handlerName {
        case "requestPermission":
            _ = try await agentConnection.requestPermission(
                RequestPermissionRequest(
                    options: [
                        PermissionOption(kind: .allowOnce, name: "Allow", optionId: PermissionOptionId(rawValue: "allow"))
                    ],
                    sessionId: Self.sessionId,
                    title: "Permission needed"
                )
            )
        case "sessionUpdate":
            try await agentConnection.sessionUpdate(
                UpdateSessionNotification(sessionId: Self.sessionId, update: .stateUpdate(.running(RunningStateUpdate())))
            )
            _ = try await agentConnection.requestPermission(
                RequestPermissionRequest(
                    options: [
                        PermissionOption(kind: .allowOnce, name: "Allow", optionId: PermissionOptionId(rawValue: "allow"))
                    ],
                    sessionId: Self.sessionId,
                    title: "Permission needed"
                )
            )
        default:
            Issue.record("RoutingCoverageTests has no driver wired for client handler \"\(handlerName)\"")
        }
    }

    @Test func everyClientMethodReachesExactlyItsOwnHandlerAndNoOther() async throws {
        let clientEntries = ACPMethodTable.methods.filter { $0.side == .client }
        #expect(!clientEntries.isEmpty, "the routing table named no client-side entries; this test would vacuously pass")

        for entry in clientEntries {
            let log = CallLog()
            let (clientEnd, agentEnd) = InMemoryTransport.pair()
            let agentConn = await AgentSideConnection(stream: agentEnd) { _ in RecordingAgent(log: log) }
            let client = await ClientSideConnection(stream: clientEnd) { _ in RecordingClient(log: log) }

            try await Self.driveClientHandler(entry.handlerName, agentConnection: agentConn)

            let calls = await log.calls
            let expected = entry.handlerName == "sessionUpdate" ? ["sessionUpdate", "requestPermission"] : [entry.handlerName]
            #expect(
                calls == expected,
                "wire method \"\(entry.wireMethod)\" should reach \(expected), reached \(calls) instead"
            )

            await agentConn.close()
            await client.close()
        }
    }

    // MARK: - Every stable table entry is exercised by one of the two suites above

    @Test func everyStableMethodTableEntryIsCoveredByThisSuite() {
        // The protocol-level `$/cancel_request` entry is intercepted by
        // `Connection` itself before either role's dispatch switch ever sees
        // it (see `Connection.MessageKind.cancelRequest`), so it has no
        // per-role handler to mis-route in the first place — it is out of
        // scope for *this* suite by construction, not by oversight, and its
        // cancellation semantics are already covered by `ConnectionTests`.
        let dispatchable = ACPMethodTable.methods.filter { $0.side != .protocolLevel }
        #expect(!dispatchable.isEmpty)
        for entry in dispatchable {
            #expect(
                entry.side == .agent || entry.side == .client,
                "unexpected routing side \(entry.side) for \(entry.wireMethod); this suite covers only agent and client"
            )
        }
    }
}
