import Foundation
import Testing

@testable import FoundationModelsACP

/// The time limit of the read-loop test, in minutes.
private let readLoopTestTimeout = 1

/// `session/request_permission`: a stable Client request that waits on a
/// human — `elicitation/create` is the other — restructured in v2 to separate
/// prompt copy (`title`/`description`) from structured context (the tagged
/// `subject`).
///
/// Two halves. The first is pure wire round-tripping of `RequestPermissionRequest`
/// and `RequestPermissionSubject`, complementing the generic tag-exhaustiveness
/// coverage `TaggedUnionRoundTripTests` already gives every union including this
/// one — what that generic coverage cannot give is a real `command` payload
/// (required `command` + `cwd`, optional `toolCallId`/`terminalId`) or the
/// proof that a relative `cwd` is carried as sent for the agent to validate.
/// The second half proves, with the real `Agent`/`Client` connection rather
/// than a raw `Connection` stand-in, that a pending permission request never
/// blocks the read loop that keeps other traffic — like a concurrent
/// `session/update` — flowing on the same connection.
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

    @Test func commandSubjectKeepsARelativeCwdAsSent() throws {
        // The schema states in prose that `cwd` must be absolute, and it
        // names no validator. `AbsolutePath` carries the wire value as sent,
        // same as every other path field
        // (`WireInvariantTests.relativePathDecodesAsTheSchemaSays`), so the
        // agent can validate it and answer invalid params. This pins that for
        // `CommandPermissionSubject.cwd`.
        let subject = try WireRoundTrip.expectLossless(RequestPermissionSubject.self, """
            {"type":"command","command":"npm test","cwd":"project"}
            """)
        guard case .command(let command) = subject else {
            Issue.record("expected .command, got \(subject)")
            return
        }
        #expect(command.cwd.rawValue == "project")
    }

    // MARK: - Elicitation is a stable sibling, not this suite's subject
    //
    // The vendored `schema-v2.0.0-alpha.8` holds elicitation on the stable
    // client surface: `elicitation/create` routes beside
    // `session/request_permission` as the other long-lived, human-gated
    // request, and `ElicitationLifecycleTests` covers its lifecycle the way
    // this suite covers permissions.
    // `ClientProtocolTests.clientCarriesNoUnstableOnlyMethod` still asserts
    // that no unstable-only handler name leaks onto `Client`.

    // MARK: - A pending permission request must not block the read loop

    /// The test sends `requestPermission` and `sessionUpdate` directly from
    /// the `StubAgent` side. The shared `GatedPermissionClient` waits for a
    /// gate and does not answer. It stands for a human who still looks at the
    /// prompt. `ConnectionTests.slowRequestHandlerDoesNotDelaySubsequentNotification`
    /// gives a raw handler the same role; this test uses the typed `Client`.
    @Test(.timeLimit(.minutes(readLoopTestTimeout)))
    func aPendingPermissionRequestDoesNotBlockAConcurrentSessionUpdate() async throws {
        let session = StubAgent.sessionId
        let entered = AsyncStream<SessionId>.makeStream()
        let gate = Gate()

        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agentConn = await AgentSideConnection(stream: agentEnd) { _ in StubAgent() }
        let client = await ClientSideConnection(stream: clientEnd) { _ in
            GatedPermissionClient(entered: entered.continuation, gate: gate, outcome: .cancelled)
        }
        var updates = client.subscribe(to: session).updates.makeAsyncIterator()

        // Fires `session/request_permission`; the client's handler suspends on
        // the gate rather than answering, so this stays pending for the rest
        // of the test until the gate is released below.
        let permission = Task {
            try await agentConn.requestPermission(.stub(for: session))
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
        #expect(await updates.nextUpdate() == .stateUpdate(.running(RunningStateUpdate())))

        // Only now release the gate — the assertion above already proved the
        // request was genuinely still pending, not merely fast.
        gate.open()
        let response = try await permission.value
        #expect(response.outcome == .cancelled)

        await agentConn.close()
        await client.close()
    }
}
