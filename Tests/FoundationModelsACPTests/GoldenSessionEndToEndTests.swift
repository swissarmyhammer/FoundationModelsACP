import Foundation
import Synchronization
import Testing

@testable import FoundationModelsACP

/// The per-test time limit, in minutes, for the golden session below.
private let standardTestTimeout = 1  // minute

/// The representative full v2 session (plan.md M9, *Testing strategy*):
/// `initialize`, `session/new`, `session/prompt`, a streamed turn (thought and
/// message chunks, a tool call with a content chunk and a display terminal
/// reference, the terminal's own upserts), a `session/request_permission`
/// round trip, and the closing `idle`.
///
/// Driven over a live `InMemoryTransport` pair with real `AgentSideConnection`
/// / `ClientSideConnection` — not `ReplayTransport` — because the permission
/// round trip is an agent-initiated *request* the client must answer
/// reactively; see `ReplayTransport`'s own doc comment for why a statically
/// scripted replay cannot correlate that safely. Still fully deterministic:
/// no model, no network, no clock — every identifier the scripted turn uses
/// is fixed, and the driver awaits each step in a fixed order, so the agent's
/// emitted byte stream is reproducible and can be pinned against a golden
/// fixture byte-for-byte.
@Suite struct GoldenSessionEndToEndTests {
    // MARK: - Fixed identifiers

    fileprivate static let sessionId = SessionId(rawValue: "golden-session")
    fileprivate static let userMessageId = MessageId(rawValue: "user-msg-1")
    fileprivate static let thoughtMessageId = MessageId(rawValue: "agent-thought-1")
    fileprivate static let agentMessageId = MessageId(rawValue: "agent-msg-1")
    fileprivate static let toolCallId = ToolCallId(rawValue: "call-1")
    fileprivate static let terminalId = TerminalId(rawValue: "term-1")
    fileprivate static let permissionOptionId = PermissionOptionId(rawValue: "allow-once")
    fileprivate static let workingDirectory = AbsolutePath(rawValue: "/work")!

    // MARK: - The scripted agent

    /// An `Agent` running one fixed, deterministic turn: no clock, no model,
    /// no randomness anywhere an identifier is generated — everything a
    /// golden byte comparison depends on is a literal constant above.
    ///
    /// A `Fixed` type alias shortens every reference to those constants below
    /// to `Fixed.toolCallId` rather than the outer suite's full name.
    private final class GoldenSessionAgent: Agent {
        private typealias Fixed = GoldenSessionEndToEndTests

        let connection: AgentSideConnection

        init(connection: AgentSideConnection) {
            self.connection = connection
        }

        func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
            InitializeResponse(
                info: Implementation(name: "golden-agent", version: "1.0.0"),
                protocolVersion: .v2,
                capabilities: AgentCapabilities(session: SessionCapabilities())
            )
        }

        func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
            NewSessionResponse(sessionId: Fixed.sessionId)
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

        /// Acknowledges at once; the turn itself starts only once `connection`
        /// confirms the response has been written — see
        /// `AgentSideConnection.afterRespondingToCurrentRequest(_:)`.
        func prompt(_ params: PromptRequest) async throws -> PromptResponse {
            connection.afterRespondingToCurrentRequest { [self] in
                await runTurn(prompt: params.prompt)
            }
            return PromptResponse()
        }

        func sessionCancel(_ params: CancelSessionNotification) async {}

        /// The fixed script: streamed thought/message content, a tool call
        /// with a content chunk and a display terminal reference, the
        /// terminal's own upserts, a permission round trip, then `idle`.
        ///
        /// - Parameter prompt: The prompt's content blocks, echoed as the
        ///   user message.
        private func runTurn(prompt: [ContentBlock]) async {
            await send(update: .stateUpdate(.running(RunningStateUpdate())))
            for block in prompt {
                await send(update: .userMessageChunk(ContentChunk(content: block, messageId: Fixed.userMessageId)))
            }
            await send(
                update: .agentThoughtChunk(
                    ContentChunk(content: .text(TextContent(text: "Planning to run ls.")), messageId: Fixed.thoughtMessageId)
                )
            )
            await send(
                update: .agentMessageChunk(
                    ContentChunk(content: .text(TextContent(text: "Running ls now.")), messageId: Fixed.agentMessageId)
                )
            )

            await send(
                update: .toolCallUpdate(
                    ToolCallUpdate(
                        toolCallId: Fixed.toolCallId,
                        kind: .value(.execute),
                        rawInput: .value(.object(["command": .string("ls")])),
                        status: .value(.pending),
                        title: .value("Run ls")
                    )
                )
            )
            await send(
                update: .toolCallContentChunk(
                    ToolCallContentChunk(content: .terminal(Terminal(terminalId: Fixed.terminalId)), toolCallId: Fixed.toolCallId)
                )
            )
            await send(
                update: .terminalUpdate(
                    TerminalUpdate(terminalId: Fixed.terminalId, command: .value("ls"), cwd: .value(Fixed.workingDirectory))
                )
            )
            await send(
                update: .terminalOutputChunk(
                    TerminalOutputChunk(data: Data("total 0\n".utf8).base64EncodedString(), terminalId: Fixed.terminalId)
                )
            )
            await send(
                update: .terminalUpdate(TerminalUpdate(terminalId: Fixed.terminalId, exitStatus: .value(TerminalExitStatus(exitCode: 0))))
            )
            await send(update: .toolCallUpdate(ToolCallUpdate(toolCallId: Fixed.toolCallId, status: .value(.completed))))

            await send(update: .stateUpdate(.requiresAction(RequiresActionStateUpdate())))
            _ = try? await connection.requestPermission(
                RequestPermissionRequest(
                    options: [PermissionOption(kind: .allowOnce, name: "Allow", optionId: Fixed.permissionOptionId)],
                    sessionId: Fixed.sessionId,
                    title: "Run ls?",
                    subject: .toolCall(
                        ToolCallPermissionSubject(toolCall: ToolCallUpdate(toolCallId: Fixed.toolCallId, title: .value("Run ls")))
                    )
                )
            )
            await send(update: .stateUpdate(.running(RunningStateUpdate())))

            await send(update: .stateUpdate(.idle(IdleStateUpdate(stopReason: .endTurn))))
        }

        /// Sends one `session/update` notification, swallowing a closed
        /// connection — the test closes both ends once it finishes
        /// observing.
        ///
        /// - Parameter update: The update payload to send.
        private func send(update: SessionUpdate) async {
            try? await connection.sessionUpdate(UpdateSessionNotification(sessionId: Fixed.sessionId, update: update))
        }
    }

    /// A `Client` that grants the one permission request this session's
    /// script issues, with a fixed outcome — no human, no randomness.
    private struct GoldenSessionClient: Client {
        func sessionUpdate(_ notification: UpdateSessionNotification) async {}

        func requestPermission(
            _ params: RequestPermissionRequest
        ) async throws -> RequestPermissionResponse {
            RequestPermissionResponse(outcome: .selected(SelectedPermissionOutcome(optionId: GoldenSessionEndToEndTests.permissionOptionId)))
        }
    }

    // MARK: - Byte capture

    /// Everything written through a `CapturingTransport`, guarded for
    /// concurrent writers — a class (not the struct wrapper itself) so the
    /// `Mutex` inside is not itself a stored property of a `Copyable` value
    /// type.
    private final class CapturedBytes: Sendable {
        private let storage = Mutex<Data>(Data())

        func append(_ data: Data) {
            storage.withLock { $0.append(data) }
        }

        var data: Data {
            storage.withLock { $0 }
        }
    }

    /// Wraps a transport, capturing every chunk written through it — the
    /// agent's full emitted byte stream, in write order, for golden
    /// comparison. Unlike `ReplayTransport`, the wrapped `bytes` stream is a
    /// live peer's real traffic, not a pre-recorded script.
    private struct CapturingTransport: ACPTransport {
        let underlying: any ACPTransport
        let captured = CapturedBytes()

        var bytes: AsyncThrowingStream<Data, any Error> { underlying.bytes }

        func write(_ data: Data) async throws {
            captured.append(data)
            try await underlying.write(data)
        }
    }

    // MARK: - Test

    @Test(.timeLimit(.minutes(standardTestTimeout)))
    func goldenSessionReproducesExpectedStateAndByteStreamExactly() async throws {
        let (clientEnd, rawAgentEnd) = InMemoryTransport.pair()
        let capture = CapturingTransport(underlying: rawAgentEnd)
        let agentConn = await AgentSideConnection(stream: capture) { conn in GoldenSessionAgent(connection: conn) }
        let client = await ClientSideConnection(stream: clientEnd) { _ in GoldenSessionClient() }

        var updates = client.updates(for: Self.sessionId).makeAsyncIterator()

        let initResponse = try await client.initialize(
            InitializeRequest(info: Implementation(name: "golden-client", version: "1.0.0"), protocolVersion: .v2)
        )
        #expect(initResponse.protocolVersion == .v2)

        let newSessionResponse = try await client.newSession(NewSessionRequest(cwd: Self.workingDirectory))
        #expect(newSessionResponse.sessionId == Self.sessionId)

        let promptResponse = try await client.prompt(
            PromptRequest(prompt: [.text(TextContent(text: "Please run ls."))], sessionId: Self.sessionId)
        )
        #expect(promptResponse == PromptResponse())

        // Drain the session's updates through the closing idle, applying
        // each to an aggregator so the test asserts accumulated *state*, not
        // only that some bytes happened to match.
        var aggregator = SessionUpdateAggregator()
        var sawRequiresAction = false
        var stopReason: StopReason?
        while let update = await updates.next() {
            aggregator.apply(update)
            if case .stateUpdate(.requiresAction) = update {
                sawRequiresAction = true
            }
            if case .stateUpdate(.idle(let idle)) = update {
                stopReason = idle.stopReason
                break
            }
        }

        #expect(sawRequiresAction, "the permission-gated pause never reported requires_action")
        #expect(stopReason == .endTurn)

        let echoedUser = try #require(aggregator.messages[Self.userMessageId])
        #expect(echoedUser == [.text(TextContent(text: "Please run ls."))])
        #expect(aggregator.messages[Self.thoughtMessageId] == [.text(TextContent(text: "Planning to run ls."))])
        #expect(aggregator.messages[Self.agentMessageId] == [.text(TextContent(text: "Running ls now."))])

        let toolCall = try #require(aggregator.toolCalls[Self.toolCallId])
        #expect(toolCall.status == .value(.completed))
        #expect(toolCall.title == .value("Run ls"))
        guard case .value(let toolCallContent) = toolCall.content, case .terminal(let displayed)? = toolCallContent.first else {
            Issue.record("expected the tool call's content to carry a display terminal reference")
            return
        }
        #expect(displayed.terminalId == Self.terminalId)

        let terminal = try #require(aggregator.terminals[Self.terminalId])
        #expect(terminal.output == Data("total 0\n".utf8))
        #expect(terminal.exitStatus == .value(TerminalExitStatus(exitCode: 0)))

        await agentConn.close()
        await client.close()

        try expectGolden(actual: capture.captured.data, matchesFixture: "full-session-agent.ndjson")
    }
}
