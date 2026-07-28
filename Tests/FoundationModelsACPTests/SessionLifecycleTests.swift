import Foundation
import Testing

@testable import FoundationModelsACP

// MARK: - Session storage

/// Tracks the state `SessionManagingAgent` needs to serve real session
/// behavior: working directories, MCP servers, configuration options, replay
/// history, and any work in flight that `session/close` or `session/cancel`
/// must stop.
///
/// An actor rather than a lock-guarded class: every mutation here is already
/// reached through `await` from the agent's async handlers, and an actor's
/// isolation keeps the bookkeeping correct without a second concurrency
/// primitive to get wrong — the kind of concern M3's tester found a real
/// deadlock in for comparable shared state.
private actor SessionRegistry {
    /// One session's tracked state.
    struct Session {
        var cwd: AbsolutePath
        var additionalDirectories: [AbsolutePath]
        var mcpServers: [MCPServer]
        var configOptions: [SessionConfigOption]
        var history: [UpdateSessionNotification] = []
        var activeWork: Task<Void, Never>?
    }

    private var sessions: [SessionId: Session] = [:]

    /// Creates a session with a fresh id and the given initial state.
    ///
    /// - Returns: The new session's id.
    func createSession(
        cwd: AbsolutePath,
        additionalDirectories: [AbsolutePath],
        mcpServers: [MCPServer],
        configOptions: [SessionConfigOption]
    ) -> SessionId {
        let id = SessionId(rawValue: UUID().uuidString)
        sessions[id] = Session(
            cwd: cwd,
            additionalDirectories: additionalDirectories,
            mcpServers: mcpServers,
            configOptions: configOptions
        )
        return id
    }

    /// Every tracked session's public listing, optionally filtered by `cwd`.
    ///
    /// Sorted by id so a listing with more than one session is deterministic
    /// for tests, independent of dictionary iteration order.
    func listSessions(matchingCwd cwd: AbsolutePath?) -> [SessionInfo] {
        sessions
            .filter { cwd == nil || $0.value.cwd == cwd }
            .map { id, session in
                SessionInfo(
                    cwd: session.cwd,
                    sessionId: id,
                    additionalDirectories: session.additionalDirectories.isEmpty ? nil : session.additionalDirectories
                )
            }
            .sorted { $0.sessionId.rawValue < $1.sessionId.rawValue }
    }

    /// Looks up a tracked session by id.
    ///
    /// - Throws: `RequestError.resourceNotFound` for an unknown id.
    func session(_ id: SessionId) throws -> Session {
        guard let session = sessions[id] else { throw RequestError.resourceNotFound(uri: id.rawValue) }
        return session
    }

    /// Appends one notification to a session's replay history.
    ///
    /// - Throws: `RequestError.resourceNotFound` for an unknown id.
    func recordHistory(_ id: SessionId, _ update: UpdateSessionNotification) throws {
        guard sessions[id] != nil else { throw RequestError.resourceNotFound(uri: id.rawValue) }
        sessions[id]?.history.append(update)
    }

    /// Registers a session's in-flight work, so a later cancel can stop it.
    ///
    /// - Throws: `RequestError.resourceNotFound` for an unknown id.
    func beginWork(_ id: SessionId, _ task: Task<Void, Never>) throws {
        guard sessions[id] != nil else { throw RequestError.resourceNotFound(uri: id.rawValue) }
        sessions[id]?.activeWork = task
    }

    /// Removes and returns a session's in-flight work, if any — freeing the
    /// slot regardless of whether the caller goes on to cancel the task.
    func takeActiveWork(_ id: SessionId) -> Task<Void, Never>? {
        guard let task = sessions[id]?.activeWork else { return nil }
        sessions[id]?.activeWork = nil
        return task
    }

    /// Removes a session outright, so it no longer appears in `listSessions`.
    ///
    /// Distinct from freeing a session's active work: this drops the whole
    /// record, history included, whereas closing a session keeps it listed
    /// and resumable.
    ///
    /// - Throws: `RequestError.resourceNotFound` for an unknown id.
    func deleteSession(_ id: SessionId) throws {
        guard sessions.removeValue(forKey: id) != nil else {
            throw RequestError.resourceNotFound(uri: id.rawValue)
        }
    }

    /// Applies a new value to one configuration option, returning the full
    /// updated set.
    ///
    /// - Throws: `RequestError.resourceNotFound` for an unknown session or
    ///   option id; `RequestError.invalidParams` when the value's shape does
    ///   not match the option's own variant.
    func setConfigOption(
        sessionId: SessionId,
        configId: SessionConfigId,
        value: SetSessionConfigOptionRequest.Value
    ) throws -> [SessionConfigOption] {
        guard var session = sessions[sessionId] else {
            throw RequestError.resourceNotFound(uri: sessionId.rawValue)
        }
        guard let index = session.configOptions.firstIndex(where: { $0.configId == configId }) else {
            throw RequestError.resourceNotFound(uri: configId.rawValue)
        }
        switch (session.configOptions[index].type, value) {
        case (.boolean, .boolean(let newValue)):
            session.configOptions[index].type = .boolean(SessionConfigBoolean(currentValue: newValue))
        case (.select(let current), .id(let newValue)):
            session.configOptions[index].type = .select(
                SessionConfigSelect(currentValue: newValue, options: current.options)
            )
        default:
            throw RequestError.invalidParams
        }
        sessions[sessionId] = session
        return session.configOptions
    }
}

// MARK: - The real M5 agent

/// An `Agent` implementing the actual M5 session lifecycle — creation,
/// listing, resume with replay, close-cancels-and-frees, delete, and
/// config-option updates — backed by a `SessionRegistry` and the connection
/// the factory closure hands it, so replay and config-option pushes can call
/// back into the client as ordinary `session/update` notifications.
private final class SessionManagingAgent: Agent {
    /// The connection the factory handed this agent, captured so replay and
    /// config-option pushes can call back into the client.
    let connection: AgentSideConnection

    /// The session state this agent serves.
    let registry: SessionRegistry

    /// The configuration options every new session starts with.
    let initialConfigOptions: [SessionConfigOption]

    /// Creates an agent bound to its own connection and a fresh registry.
    ///
    /// - Parameters:
    ///   - connection: The connection the factory handed this agent.
    ///   - initialConfigOptions: The options every session created through
    ///     this agent starts with.
    init(connection: AgentSideConnection, initialConfigOptions: [SessionConfigOption] = []) {
        self.connection = connection
        self.registry = SessionRegistry()
        self.initialConfigOptions = initialConfigOptions
    }

    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(
            info: Implementation(name: "session-managing-agent", version: "0.0.0"),
            protocolVersion: .v2,
            capabilities: AgentCapabilities(session: SessionCapabilities(delete: SessionDeleteCapabilities()))
        )
    }

    func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        let id = await registry.createSession(
            cwd: params.cwd,
            additionalDirectories: params.additionalDirectories ?? [],
            mcpServers: params.mcpServers ?? [],
            configOptions: initialConfigOptions
        )
        return NewSessionResponse(sessionId: id, configOptions: initialConfigOptions.isEmpty ? nil : initialConfigOptions)
    }

    func listSessions(_ params: ListSessionsRequest) async throws -> ListSessionsResponse {
        ListSessionsResponse(sessions: await registry.listSessions(matchingCwd: params.cwd))
    }

    func resumeSession(_ params: ResumeSessionRequest) async throws -> ResumeSessionResponse {
        let session = try await registry.session(params.sessionId)
        guard session.cwd == params.cwd else {
            // "as long as the request `cwd` matches the session's `cwd`" —
            // ResumeSessionRequest.additionalDirectories' own doc comment.
            throw RequestError.invalidParams
        }

        switch params.replayFrom {
        case nil:
            break  // Plain reconnect: replay nothing.
        case .start:
            for update in session.history {
                try await connection.sessionUpdate(update)
            }
        case .unknown(_, let payload):
            // The schema's own guidance for a cursor this revision does not
            // recognize: preserve the raw payload — already true, since it
            // decoded into `.unknown` instead of being dropped — and reject
            // the request rather than guessing where to replay from.
            throw RequestError(code: .invalidParams, message: "Unrecognized replayFrom cursor", data: payload)
        }
        return ResumeSessionResponse(configOptions: session.configOptions.isEmpty ? nil : session.configOptions)
    }

    func closeSession(_ params: CloseSessionRequest) async throws -> CloseSessionResponse {
        _ = try await registry.session(params.sessionId)  // resourceNotFound for an unknown id
        await cancelOngoingWork(params.sessionId)
        return CloseSessionResponse()
    }

    func deleteSession(_ params: DeleteSessionRequest) async throws -> DeleteSessionResponse {
        try await registry.deleteSession(params.sessionId)
        return DeleteSessionResponse()
    }

    func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        _ = try await registry.session(params.sessionId)
        let task = Task<Void, Never> {
            do {
                // Stands in for real foreground work: never actually reaches
                // this sleep's end in a test, only its cancellation.
                try await Task.sleep(for: .seconds(3600))
            } catch {
                // Cancelled by `session/cancel` or `session/close`.
            }
        }
        try await registry.beginWork(params.sessionId, task)
        return PromptResponse()
    }

    func sessionCancel(_ params: CancelSessionNotification) async {
        await cancelOngoingWork(params.sessionId)
    }

    func setSessionConfigOption(
        _ params: SetSessionConfigOptionRequest
    ) async throws -> SetSessionConfigOptionResponse {
        let updated = try await registry.setConfigOption(
            sessionId: params.sessionId,
            configId: params.configId,
            value: params.value
        )
        let notification = UpdateSessionNotification(
            sessionId: params.sessionId,
            update: .configOptionUpdate(ConfigOptionUpdate(configOptions: updated))
        )
        try? await registry.recordHistory(params.sessionId, notification)
        try? await connection.sessionUpdate(notification)
        return SetSessionConfigOptionResponse(configOptions: updated)
    }

    /// Cancels a session's in-flight work, if any, and confirms it with the
    /// same `idle`/`cancelled` `state_update` a real `session/cancel` would
    /// send — the spec's own words for `session/close`: "treat it as if
    /// `session/cancel` was called."
    ///
    /// A no-op when nothing is in flight, so calling this from both
    /// `sessionCancel` and `closeSession` never double-sends the
    /// confirmation for one turn.
    ///
    /// - Parameter sessionId: The session to cancel work for.
    private func cancelOngoingWork(_ sessionId: SessionId) async {
        guard let task = await registry.takeActiveWork(sessionId) else { return }
        task.cancel()
        await task.value
        let notification = UpdateSessionNotification(
            sessionId: sessionId,
            update: .stateUpdate(.idle(IdleStateUpdate(stopReason: .cancelled)))
        )
        try? await registry.recordHistory(sessionId, notification)
        try? await connection.sessionUpdate(notification)
    }
}

// MARK: - An agent advertising no delete capability

/// An `Agent` implementing only the session baseline — no `deleteSession`
/// override — so `session/delete` against it exercises the protocol's own
/// method-not-found default over the real wire, not just the bare protocol
/// call `AgentProtocolTests` already covers.
private struct SessionBaselineOnlyAgent: Agent {
    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(
            info: Implementation(name: "baseline-only-agent", version: "0.0.0"),
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

// MARK: - A client that only observes

/// A `Client` used only to open the connection; every test observes updates
/// through `ClientSideConnection.updates(for:)` instead of this handler.
private struct PassiveClient: Client {
    func sessionUpdate(_ notification: UpdateSessionNotification) async {}

    func requestPermission(
        _ params: RequestPermissionRequest
    ) async throws -> RequestPermissionResponse {
        throw RequestError.methodNotFound("requestPermission")
    }
}

// MARK: - Fixtures

/// A single boolean configuration option, reused by the tests that need only
/// one to exercise replay and reconnect.
private let primaryConfigOption = SessionConfigOption(
    configId: SessionConfigId(rawValue: "primary-option"),
    name: "Primary Option",
    category: .mode,
    type: .boolean(SessionConfigBoolean(currentValue: false))
)

/// One boolean configuration option per category the schema documents, so
/// the config-option round-trip test exercises all four, not just one.
private let fourCategoryConfigOptions: [SessionConfigOption] = [
    SessionConfigOption(
        configId: SessionConfigId(rawValue: "mode-option"), name: "Mode", category: .mode,
        type: .boolean(SessionConfigBoolean(currentValue: false))
    ),
    SessionConfigOption(
        configId: SessionConfigId(rawValue: "model-option"), name: "Model", category: .model,
        type: .boolean(SessionConfigBoolean(currentValue: false))
    ),
    SessionConfigOption(
        configId: SessionConfigId(rawValue: "model-config-option"), name: "Model Config", category: .modelConfig,
        type: .boolean(SessionConfigBoolean(currentValue: false))
    ),
    SessionConfigOption(
        configId: SessionConfigId(rawValue: "thought-level-option"), name: "Thought Level", category: .thoughtLevel,
        type: .boolean(SessionConfigBoolean(currentValue: false))
    ),
]

// MARK: - Tests

/// `session/new` / `list` / `resume` / `close` / `delete`, real session
/// behavior over `InMemoryTransport` rather than protocol shape alone.
@Suite struct SessionLifecycleTests {
    // MARK: session/new, session/list

    @Test(.timeLimit(.minutes(1)))
    func newSessionCreatesASessionThatListSessionsReports() async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agentConn = await AgentSideConnection(stream: agentEnd) { conn in SessionManagingAgent(connection: conn) }
        let client = await ClientSideConnection(stream: clientEnd) { _ in PassiveClient() }

        let cwd = try #require(AbsolutePath(rawValue: "/work/one"))
        let created = try await client.newSession(NewSessionRequest(cwd: cwd))

        let listed = try await client.listSessions(ListSessionsRequest())
        #expect(listed.sessions.map(\.sessionId) == [created.sessionId])
        #expect(listed.sessions.first?.cwd == cwd)

        await agentConn.close()
        await client.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func listSessionsFiltersByCwd() async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agentConn = await AgentSideConnection(stream: agentEnd) { conn in SessionManagingAgent(connection: conn) }
        let client = await ClientSideConnection(stream: clientEnd) { _ in PassiveClient() }

        let cwdOne = try #require(AbsolutePath(rawValue: "/work/one"))
        let cwdTwo = try #require(AbsolutePath(rawValue: "/work/two"))
        let sessionOne = try await client.newSession(NewSessionRequest(cwd: cwdOne)).sessionId
        _ = try await client.newSession(NewSessionRequest(cwd: cwdTwo))

        let filtered = try await client.listSessions(ListSessionsRequest(cwd: cwdOne))
        #expect(filtered.sessions.map(\.sessionId) == [sessionOne])

        await agentConn.close()
        await client.close()
    }

    // MARK: session/resume, replayFrom

    @Test(.timeLimit(.minutes(1)))
    func resumeSessionWithReplayFromStartReplaysTheFullHistoryInOrder() async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agentConn = await AgentSideConnection(stream: agentEnd) { conn in
            SessionManagingAgent(connection: conn, initialConfigOptions: [primaryConfigOption])
        }
        let client = await ClientSideConnection(stream: clientEnd) { _ in PassiveClient() }

        let cwd = try #require(AbsolutePath(rawValue: "/work"))
        let session = try await client.newSession(NewSessionRequest(cwd: cwd)).sessionId

        // Two config changes happen before anyone subscribes, so they land
        // only in the agent's own history — proving replay reconstructs it
        // rather than merely re-broadcasting a live stream.
        _ = try await client.setSessionConfigOption(
            SetSessionConfigOptionRequest(configId: primaryConfigOption.configId, sessionId: session, value: .boolean(true))
        )
        _ = try await client.setSessionConfigOption(
            SetSessionConfigOptionRequest(configId: primaryConfigOption.configId, sessionId: session, value: .boolean(false))
        )

        var updates = client.updates(for: session).makeAsyncIterator()
        _ = try await client.resumeSession(
            ResumeSessionRequest(cwd: cwd, sessionId: session, replayFrom: .start(ReplayFromStart()))
        )

        let first = try #require(await updates.next())
        guard case .configOptionUpdate(let firstUpdate) = first else {
            Issue.record("expected the first historical config_option_update, got \(first)")
            return
        }
        #expect(firstUpdate.configOptions.first?.type == .boolean(SessionConfigBoolean(currentValue: true)))

        let second = try #require(await updates.next())
        guard case .configOptionUpdate(let secondUpdate) = second else {
            Issue.record("expected the second historical config_option_update, got \(second)")
            return
        }
        #expect(secondUpdate.configOptions.first?.type == .boolean(SessionConfigBoolean(currentValue: false)))

        await agentConn.close()
        await client.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func resumeSessionWithoutReplayFromSendsNoUpdates() async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agentConn = await AgentSideConnection(stream: agentEnd) { conn in
            SessionManagingAgent(connection: conn, initialConfigOptions: [primaryConfigOption])
        }
        let client = await ClientSideConnection(stream: clientEnd) { _ in PassiveClient() }

        let cwd = try #require(AbsolutePath(rawValue: "/work"))
        let session = try await client.newSession(NewSessionRequest(cwd: cwd)).sessionId

        // A history entry exists before anyone subscribes, so there is
        // something a buggy resume *could* replay.
        _ = try await client.setSessionConfigOption(
            SetSessionConfigOptionRequest(configId: primaryConfigOption.configId, sessionId: session, value: .boolean(true))
        )

        var updates = client.updates(for: session).makeAsyncIterator()
        _ = try await client.resumeSession(ResumeSessionRequest(cwd: cwd, sessionId: session))

        // Nothing replayed by the omitted-`replayFrom` resume: the very next
        // update observed is the one triggered after it, carrying `false` —
        // not the pre-existing history entry carrying `true`.
        _ = try await client.setSessionConfigOption(
            SetSessionConfigOptionRequest(configId: primaryConfigOption.configId, sessionId: session, value: .boolean(false))
        )
        let onlyUpdate = try #require(await updates.next())
        guard case .configOptionUpdate(let update) = onlyUpdate else {
            Issue.record("expected the post-resume config_option_update, got \(onlyUpdate)")
            return
        }
        #expect(update.configOptions.first?.type == .boolean(SessionConfigBoolean(currentValue: false)))

        await agentConn.close()
        await client.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func resumeSessionWithAnUnrecognizedReplayFromCursorIsRejectedRatherThanGuessed() async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agentConn = await AgentSideConnection(stream: agentEnd) { conn in SessionManagingAgent(connection: conn) }
        let client = await ClientSideConnection(stream: clientEnd) { _ in PassiveClient() }

        let cwd = try #require(AbsolutePath(rawValue: "/work"))
        let session = try await client.newSession(NewSessionRequest(cwd: cwd)).sessionId
        let payload = JSONValue.object(["offset": .number(42)])
        let cursor = ReplayFrom.unknown("checkpoint", payload)

        do {
            _ = try await client.resumeSession(ResumeSessionRequest(cwd: cwd, sessionId: session, replayFrom: cursor))
            Issue.record("expected the unrecognized cursor to be rejected")
        } catch let error as RequestError {
            // Not just "some error" — specifically the rejection this branch
            // throws, with the cursor's own payload still attached, proving
            // it was preserved rather than dropped on the way to the error.
            #expect(error.code == .invalidParams)
            #expect(error.data == payload)
        }

        await agentConn.close()
        await client.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func resumeSessionWithACwdThatDoesNotMatchTheSessionsIsRejected() async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agentConn = await AgentSideConnection(stream: agentEnd) { conn in SessionManagingAgent(connection: conn) }
        let client = await ClientSideConnection(stream: clientEnd) { _ in PassiveClient() }

        let cwd = try #require(AbsolutePath(rawValue: "/work"))
        let otherCwd = try #require(AbsolutePath(rawValue: "/elsewhere"))
        let session = try await client.newSession(NewSessionRequest(cwd: cwd)).sessionId

        await #expect(throws: RequestError.self) {
            _ = try await client.resumeSession(ResumeSessionRequest(cwd: otherCwd, sessionId: session))
        }

        await agentConn.close()
        await client.close()
    }

    // MARK: session/close

    @Test(.timeLimit(.minutes(1)))
    func closeSessionCancelsOngoingWorkAndKeepsTheSessionListed() async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agentConn = await AgentSideConnection(stream: agentEnd) { conn in SessionManagingAgent(connection: conn) }
        let client = await ClientSideConnection(stream: clientEnd) { _ in PassiveClient() }

        let cwd = try #require(AbsolutePath(rawValue: "/work"))
        let session = try await client.newSession(NewSessionRequest(cwd: cwd)).sessionId

        var updates = client.updates(for: session).makeAsyncIterator()
        _ = try await client.prompt(PromptRequest(prompt: [.text(TextContent(text: "go"))], sessionId: session))

        _ = try await client.closeSession(CloseSessionRequest(sessionId: session))

        // "treat it as if `session/cancel` was called": the same
        // idle/cancelled confirmation a real cancel would send, proving the
        // in-flight work was actually stopped and its slot freed rather than
        // merely forgotten.
        let update = try #require(await updates.next())
        #expect(update == .stateUpdate(.idle(IdleStateUpdate(stopReason: .cancelled))))

        // Close is not delete: the session survives in a later listing.
        let listed = try await client.listSessions(ListSessionsRequest())
        #expect(listed.sessions.map(\.sessionId) == [session])

        await agentConn.close()
        await client.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func closeSessionWithNoWorkInFlightSucceedsAsANoOpAndSendsNoUpdate() async throws {
        // The other close test covers the cancel-something path; this covers
        // `cancelOngoingWork`'s no-op guard, so both branches of that
        // condition are exercised, not just the one with work to cancel.
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agentConn = await AgentSideConnection(stream: agentEnd) { conn in SessionManagingAgent(connection: conn) }
        let client = await ClientSideConnection(stream: clientEnd) { _ in PassiveClient() }

        let cwd = try #require(AbsolutePath(rawValue: "/work"))
        let session = try await client.newSession(NewSessionRequest(cwd: cwd)).sessionId

        var updates = client.updates(for: session).makeAsyncIterator()
        _ = try await client.closeSession(CloseSessionRequest(sessionId: session))

        // No cancellation confirmation, because there was nothing to cancel —
        // proven the same way `resumeSessionWithoutReplayFromSendsNoUpdates`
        // proves absence: the next observed update is a distinguishable one
        // triggered afterward, not a spurious idle/cancelled.
        _ = try await client.prompt(PromptRequest(prompt: [.text(TextContent(text: "go"))], sessionId: session))
        _ = try await client.closeSession(CloseSessionRequest(sessionId: session))
        let update = try #require(await updates.next())
        #expect(update == .stateUpdate(.idle(IdleStateUpdate(stopReason: .cancelled))))

        let listed = try await client.listSessions(ListSessionsRequest())
        #expect(listed.sessions.map(\.sessionId) == [session])

        await agentConn.close()
        await client.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func closeSessionOnAnUnknownSessionFails() async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agentConn = await AgentSideConnection(stream: agentEnd) { conn in SessionManagingAgent(connection: conn) }
        let client = await ClientSideConnection(stream: clientEnd) { _ in PassiveClient() }

        await #expect(throws: RequestError.self) {
            _ = try await client.closeSession(CloseSessionRequest(sessionId: SessionId(rawValue: "no-such-session")))
        }

        await agentConn.close()
        await client.close()
    }

    // MARK: session/delete

    @Test(.timeLimit(.minutes(1)))
    func deleteSessionRemovesTheSessionFromListingAndIsDistinctFromClose() async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agentConn = await AgentSideConnection(stream: agentEnd) { conn in SessionManagingAgent(connection: conn) }
        let client = await ClientSideConnection(stream: clientEnd) { _ in PassiveClient() }

        let cwd = try #require(AbsolutePath(rawValue: "/work"))
        let toDelete = try await client.newSession(NewSessionRequest(cwd: cwd)).sessionId
        let toKeep = try await client.newSession(NewSessionRequest(cwd: cwd)).sessionId

        _ = try await client.deleteSession(DeleteSessionRequest(sessionId: toDelete))

        let listed = try await client.listSessions(ListSessionsRequest())
        #expect(listed.sessions.map(\.sessionId) == [toKeep])

        // Distinct handler, not merely a distinct wire method name: closing
        // the now-deleted session fails, because delete actually removed its
        // state rather than routing to the same cleanup close performs.
        await #expect(throws: RequestError.self) {
            _ = try await client.closeSession(CloseSessionRequest(sessionId: toDelete))
        }

        await agentConn.close()
        await client.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func deleteSessionIsMethodNotFoundWhenCapabilityIsNotAdvertised() async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agentConn = await AgentSideConnection(stream: agentEnd) { _ in SessionBaselineOnlyAgent() }
        let client = await ClientSideConnection(stream: clientEnd) { _ in PassiveClient() }

        do {
            _ = try await client.deleteSession(DeleteSessionRequest(sessionId: SessionId(rawValue: "session-1")))
            Issue.record("expected method-not-found")
        } catch let error as RequestError {
            #expect(error.code == .methodNotFound)
            #expect(error.data == .object(["method": .string("session/delete")]))
        }

        await agentConn.close()
        await client.close()
    }

    // MARK: session/set_config_option, config_option_update

    @Test(.timeLimit(.minutes(1)))
    func setSessionConfigOptionRoundTripsAndEmitsConfigOptionUpdateForEachCategory() async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agentConn = await AgentSideConnection(stream: agentEnd) { conn in
            SessionManagingAgent(connection: conn, initialConfigOptions: fourCategoryConfigOptions)
        }
        let client = await ClientSideConnection(stream: clientEnd) { _ in PassiveClient() }

        let cwd = try #require(AbsolutePath(rawValue: "/work"))
        let session = try await client.newSession(NewSessionRequest(cwd: cwd)).sessionId
        var updates = client.updates(for: session).makeAsyncIterator()

        for option in fourCategoryConfigOptions {
            let response = try await client.setSessionConfigOption(
                SetSessionConfigOptionRequest(configId: option.configId, sessionId: session, value: .boolean(true))
            )
            let updatedEntry = try #require(response.configOptions.first { $0.configId == option.configId })
            #expect(updatedEntry.type == .boolean(SessionConfigBoolean(currentValue: true)))
            #expect(updatedEntry.category == option.category)

            let update = try #require(await updates.next())
            guard case .configOptionUpdate(let configUpdate) = update else {
                Issue.record("expected a config_option_update, got \(update)")
                continue
            }
            #expect(configUpdate.configOptions == response.configOptions)
        }

        await agentConn.close()
        await client.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func setSessionConfigOptionOnAnUnknownOptionFails() async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agentConn = await AgentSideConnection(stream: agentEnd) { conn in
            SessionManagingAgent(connection: conn, initialConfigOptions: [primaryConfigOption])
        }
        let client = await ClientSideConnection(stream: clientEnd) { _ in PassiveClient() }

        let cwd = try #require(AbsolutePath(rawValue: "/work"))
        let session = try await client.newSession(NewSessionRequest(cwd: cwd)).sessionId

        await #expect(throws: RequestError.self) {
            _ = try await client.setSessionConfigOption(
                SetSessionConfigOptionRequest(
                    configId: SessionConfigId(rawValue: "no-such-option"), sessionId: session, value: .boolean(true)
                )
            )
        }

        await agentConn.close()
        await client.close()
    }

    // MARK: Wire invariants: absolute cwd

    @Test func newSessionRequestRejectsARelativeCwdAtDecodeTime() throws {
        #expect(throws: DecodingError.self) {
            try WireRoundTrip.decode(NewSessionRequest.self, from: #"{"cwd":"relative/path"}"#)
        }
    }

    @Test func resumeSessionRequestRejectsARelativeCwdAtDecodeTime() throws {
        #expect(throws: DecodingError.self) {
            try WireRoundTrip.decode(ResumeSessionRequest.self, from: #"{"cwd":"relative/path","sessionId":"s"}"#)
        }
    }

    @Test func listSessionsRequestRejectsARelativeCwdFilterAtDecodeTime() throws {
        #expect(throws: DecodingError.self) {
            try WireRoundTrip.decode(ListSessionsRequest.self, from: #"{"cwd":"relative/path"}"#)
        }
    }

    // MARK: v1's `modes` field is gone

    @Test func newSessionResponseIgnoresALegacyV1ModesFieldRatherThanFailingToDecode() throws {
        let decoded = try WireRoundTrip.decode(
            NewSessionResponse.self,
            from: #"{"sessionId":"s","modes":{"currentModeId":"code","availableModes":[]}}"#
        )
        #expect(decoded.sessionId == SessionId(rawValue: "s"))
        // Re-encoding must not resurrect the v1 field: `NewSessionResponse`
        // has nothing named `modes` to write it back into.
        #expect(try WireRoundTrip.encode(decoded) == .object(["sessionId": .string("s")]))
    }
}
