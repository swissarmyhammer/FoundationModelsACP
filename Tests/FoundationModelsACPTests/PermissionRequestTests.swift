import Foundation
import Testing

@testable import FoundationModelsACP

/// `session/request_permission` (plan.md M8): the one stable Client request
/// that waits on a human, restructured in v2 to separate prompt copy
/// (`title`/`description`) from structured context (the tagged `subject`).
///
/// Two halves. The first is pure wire round-tripping of `RequestPermissionRequest`
/// and `RequestPermissionSubject`, complementing the generic tag-exhaustiveness
/// coverage `TaggedUnionRoundTripTests` already gives every union including this
/// one — what that generic coverage cannot give is a real `command` payload
/// (required `command` + absolute `cwd`, optional `toolCallId`/`terminalId`) or
/// the absolute-path invariant enforced at decode time. The second half proves,
/// with the real `Agent`/`Client` connection rather than a raw `Connection`
/// stand-in, that a pending permission request never blocks the read loop that
/// keeps other traffic — like a concurrent `session/update` — flowing on the
/// same connection.
@Suite struct PermissionRequestTests {
    // MARK: - RequestPermissionRequest: title/description/subject

    @Test func requestPermissionRoundTripsTitleDescriptionAndToolCallSubject() throws {
        let request = try WireRoundTrip.expectLossless(RequestPermissionRequest.self, """
            {"options":[{"kind":"allow_once","name":"Allow","optionId":"allow"}],"sessionId":"s1",\
            "title":"Read this file?","description":"The agent wants to read a file outside the workspace.",\
            "subject":{"type":"tool_call","toolCall":{"toolCallId":"call-1","title":"Read a file"}}}
            """)
        #expect(request.title == "Read this file?")
        #expect(request.description == "The agent wants to read a file outside the workspace.")
        guard case .toolCall(let toolCall) = try #require(request.subject) else {
            Issue.record("expected .toolCall subject, got \(String(describing: request.subject))")
            return
        }
        #expect(toolCall.toolCall.toolCallId == ToolCallId(rawValue: "call-1"))
    }

    @Test func requestPermissionWithAnOmittedSubjectRoundTrips() throws {
        // "Omitted or null both mean no structured subject was provided" —
        // and description is independently optional, so a request naming only
        // the required title must round-trip with both absent.
        let request = try WireRoundTrip.expectLossless(RequestPermissionRequest.self, """
            {"options":[{"kind":"allow_once","name":"Allow","optionId":"allow"}],"sessionId":"s1","title":"Proceed?"}
            """)
        #expect(request.subject == nil)
        #expect(request.description == nil)
    }

    // MARK: - RequestPermissionSubject: the command variant

    @Test func commandSubjectRoundTripsWithTheRequiredFieldsOnly() throws {
        let subject = try WireRoundTrip.expectLossless(RequestPermissionSubject.self, """
            {"type":"command","command":"rm -rf build","cwd":"/work/project"}
            """)
        guard case .command(let command) = subject else {
            Issue.record("expected .command, got \(subject)")
            return
        }
        #expect(command.command == "rm -rf build")
        #expect(command.cwd == AbsolutePath(rawValue: "/work/project"))
        #expect(command.toolCallId == nil)
        #expect(command.terminalId == nil)
    }

    @Test func commandSubjectRoundTripsWithToolCallIdAndTerminalId() throws {
        let subject = try WireRoundTrip.expectLossless(RequestPermissionSubject.self, """
            {"type":"command","command":"npm test","cwd":"/work/project",\
            "toolCallId":"call-1","terminalId":"term-1"}
            """)
        guard case .command(let command) = subject else {
            Issue.record("expected .command, got \(subject)")
            return
        }
        #expect(command.toolCallId == ToolCallId(rawValue: "call-1"))
        #expect(command.terminalId == TerminalId(rawValue: "term-1"))
    }

    @Test func commandSubjectWithARelativeCwdFailsDecodingWithAClearError() throws {
        // The invariant the type system enforces: `AbsolutePath` rejects a
        // relative wire value at decode time, same as every other absolute-path
        // field in the schema (`WireInvariantTests.relativePathFailsDecodingWithAClearError`)
        // — this pins it specifically for `CommandPermissionSubject.cwd`, which
        // the task calls out as required to be absolute.
        let json = """
            {"type":"command","command":"npm test","cwd":"project"}
            """
        let error = #expect(throws: DecodingError.self) {
            try WireRoundTrip.decode(RequestPermissionSubject.self, from: json)
        }
        guard case .dataCorrupted(let context) = try #require(error) else {
            Issue.record("expected a dataCorrupted error, got \(String(describing: error))")
            return
        }
        #expect(context.debugDescription == #"ACP paths must be absolute; got "project""#)
    }

    // MARK: - Nothing elicitation-related on the stable surface
    //
    // `ClientProtocolTests.clientCarriesNoUnstableOnlyMethod` already asserts
    // this generically against every unstable-only handler name, `Unstable
    // .MethodTable.methods` included. Re-verified by direct grep while working
    // this card: `elicitation` appears only in `MethodTable.generated.swift`
    // (the unstable routing table, expected) and in `Client.swift`'s doc
    // comment explaining the deferral — nowhere else in `Sources/`.

    // MARK: - A pending permission request must not block the read loop

    /// An `Agent` implementing only what `AgentSideConnection`'s factory
    /// requires; this suite drives `requestPermission`/`sessionUpdate`
    /// directly through the connection rather than through a served prompt, so
    /// none of these methods are ever actually called.
    private struct UnusedAgent: Agent {
        func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
            InitializeResponse(
                info: Implementation(name: "unused-agent", version: "0.0.0"),
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
            PromptResponse()
        }

        func sessionCancel(_ params: CancelSessionNotification) async {}
    }

    /// A client whose `requestPermission` suspends on a test-controlled gate
    /// instead of answering — a stand-in for a human still looking at the
    /// prompt, the same role `ConnectionTests.slowRequestHandlerDoesNotDelaySubsequentNotification`
    /// gives a raw handler, but here through the real typed `Client` surface.
    private struct GatedPermissionClient: Client {
        /// Signaled once this handler is definitely running, so the test can
        /// wait for it before sending more traffic.
        let entered: AsyncStream<Void>.Continuation

        /// Finishes once the test releases the pending request.
        let gate: AsyncStream<Void>

        func sessionUpdate(_ notification: UpdateSessionNotification) async {}

        func requestPermission(
            _ params: RequestPermissionRequest
        ) async throws -> RequestPermissionResponse {
            entered.yield(())
            var release = gate.makeAsyncIterator()
            _ = await release.next()
            return RequestPermissionResponse(outcome: .cancelled)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aPendingPermissionRequestDoesNotBlockAConcurrentSessionUpdate() async throws {
        let session = SessionId(rawValue: "session-1")
        let entered = AsyncStream<Void>.makeStream()
        let gate = AsyncStream<Void>.makeStream()

        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agentConn = await AgentSideConnection(stream: agentEnd) { _ in UnusedAgent() }
        let client = await ClientSideConnection(stream: clientEnd) { _ in
            GatedPermissionClient(entered: entered.continuation, gate: gate.stream)
        }
        var updates = client.updates(for: session).makeAsyncIterator()

        // Fires `session/request_permission`; the client's handler suspends on
        // the gate rather than answering, so this stays pending for the rest
        // of the test until the gate is released below.
        let permission = Task {
            try await agentConn.requestPermission(
                RequestPermissionRequest(
                    options: [
                        PermissionOption(kind: .allowOnce, name: "Allow", optionId: PermissionOptionId(rawValue: "allow"))
                    ],
                    sessionId: session,
                    title: "Permission needed"
                )
            )
        }

        // Wait until the client's handler is definitely running before
        // sending more traffic, so the notification below demonstrably
        // arrives while the permission request is still outstanding.
        var enteredIterator = entered.stream.makeAsyncIterator()
        _ = await enteredIterator.next()

        // A concurrent `session/update`, sent over the very same connection
        // while the permission request is still pending, must still be
        // delivered — proving the connection's read loop was not blocked
        // behind the still-suspended permission handler.
        try await agentConn.sessionUpdate(
            UpdateSessionNotification(sessionId: session, update: .stateUpdate(.running(RunningStateUpdate())))
        )
        #expect(await updates.next() == .stateUpdate(.running(RunningStateUpdate())))

        // Only now release the gate — the assertion above already proved the
        // request was genuinely still pending, not merely fast.
        gate.continuation.finish()
        let response = try await permission.value
        #expect(response.outcome == .cancelled)

        await agentConn.close()
        await client.close()
    }
}
