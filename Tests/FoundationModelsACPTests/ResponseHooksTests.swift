import Foundation
import Synchronization
import Testing

@testable import FoundationModelsACP

// MARK: - Fixtures

/// The request that each `ResponseHooks` unit test uses. Its value has no
/// effect.
private let unitRequestId: RequestId = .number(1)

/// The longest time that a test waits for a released closure, in seconds.
private let releaseTimeoutSeconds = 5

/// The longest time that a test waits for a released closure.
private let releaseTimeout: Duration = .seconds(releaseTimeoutSeconds)

/// The number of warnings that `ResponseHooks` logs when it drops one late
/// closure.
private let dropWarningCount = 1

/// The time limit of each test in this suite, in minutes.
private let hooksTestTimeout = 1

/// The number of closures that the discard-order test appends.
private let discardOrderEntryCount = 3

/// Records the order in which `onDiscard` handlers run, safe to share
/// between tasks.
private final class DiscardOrder: Sendable {
    /// The guarded registration indexes, in call order.
    private let indexes = Mutex<[Int]>([])

    /// The registration indexes of the handlers that ran, in call order.
    var calls: [Int] { indexes.withLock { $0 } }

    /// Records that the handler with this registration index ran.
    ///
    /// - Parameter index: The registration index of the handler.
    func record(_ index: Int) {
        indexes.withLock { $0.append(index) }
    }
}

/// The one session that `DeferringAgent` makes.
private let hooksSessionId = SessionId(rawValue: "hooks-session")

/// The working directory of the test session. Its value has no effect.
private let hooksWorkingDirectory = AbsolutePath(rawValue: "/work")

/// The prompt that each end-to-end test sends.
private let hooksPrompt = PromptRequest(
    prompt: [.text(TextContent(text: "hello"))],
    sessionId: hooksSessionId
)

// MARK: - The deferring agent

/// The state that a test and `DeferringAgent` share.
private final class DeferralProbe: Sendable {
    /// Gets one element when the closure that the handler deferred runs.
    let deferredClosureRan = AsyncStream<Void>.makeStream()

    /// Keeps the child task of the handler alive. The first element lets the
    /// child task defer its late closure. The end of the stream stops the
    /// child task.
    let childGate = AsyncStream<Void>.makeStream()

    /// Gets one element when the child task deferred its late closure.
    let lateClosureDeferred = AsyncStream<Void>.makeStream()

    /// A weak reference to the object that the closure of the handler
    /// captures.
    let handlerCapture = WeakReference()

    /// A weak reference to the object that the late closure captures.
    let lateCapture = WeakReference()

    /// Records if the late closure runs.
    let lateClosureRun = AtomicFlag()

    /// The child task that the handler starts.
    let childTask = Mutex<Task<Void, Never>?>(nil)

    /// Stops the child task and waits until it ends.
    func stopChildTask() async {
        childGate.continuation.finish()
        await childTask.withLock { $0 }?.value
    }
}

/// An agent whose prompt handler defers one closure, and starts a child
/// task. The child task inherits the response hooks of the request. After
/// the first element of `DeferralProbe.childGate`, the child task defers a
/// late closure, after the response was written.
private struct DeferringAgent: Agent {
    /// The connection that the factory gave this agent.
    let connection: AgentSideConnection

    /// The state that the test reads.
    let probe: DeferralProbe

    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(
            info: Implementation(name: "deferring-agent", version: "0.0.0"),
            protocolVersion: .v2,
            capabilities: AgentCapabilities(session: SessionCapabilities())
        )
    }

    func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: hooksSessionId)
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

    /// Defers one closure that captures a tracked object, and starts the
    /// child task.
    ///
    /// - Parameter params: The prompt request.
    /// - Returns: The response that names a new message.
    func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        let captured = probe.handlerCapture.makeObject()
        connection.afterRespondingToCurrentRequest { [probe] in
            withExtendedLifetime(captured) {}
            probe.deferredClosureRan.continuation.yield()
        }
        let child = Task { [connection, probe] in
            await Self.runChildTask(connection: connection, probe: probe)
        }
        probe.childTask.withLock { $0 = child }
        return PromptResponse(messageId: MessageId(rawValue: "hooks-message"))
    }

    func sessionCancel(_ params: CancelSessionNotification) async {}

    /// The body of the child task. It waits for the gate, defers the late
    /// closure, and then waits until the gate ends.
    ///
    /// - Parameters:
    ///   - connection: The connection of the agent.
    ///   - probe: The state that the test reads.
    private static func runChildTask(connection: AgentSideConnection, probe: DeferralProbe) async {
        var gate = probe.childGate.stream.makeAsyncIterator()
        guard await gate.next() != nil else { return }
        deferLateClosure(connection: connection, probe: probe)
        probe.lateClosureDeferred.continuation.yield()
        while await gate.next() != nil {}
    }

    /// Defers the late closure. The tracked object goes out of scope when
    /// this function returns, so only the closure can keep it.
    ///
    /// - Parameters:
    ///   - connection: The connection of the agent.
    ///   - probe: The state that the test reads.
    private static func deferLateClosure(connection: AgentSideConnection, probe: DeferralProbe) {
        let captured = probe.lateCapture.makeObject()
        connection.afterRespondingToCurrentRequest { [probe] in
            withExtendedLifetime(captured) {}
            probe.lateClosureRun.set()
        }
    }
}

/// A client that only opens the connection.
private struct QuietClient: Client {
    func sessionUpdate(_ notification: UpdateSessionNotification) async {}

    func requestPermission(_ params: RequestPermissionRequest) async throws -> RequestPermissionResponse {
        throw RequestError.methodNotFound("requestPermission")
    }

    func createElicitation(_ params: CreateElicitationRequest) async throws -> CreateElicitationResponse {
        throw RequestError.methodNotFound("createElicitation")
    }

    func elicitationComplete(_ notification: CompleteElicitationNotification) async {}
}

// MARK: - Unit tests of ResponseHooks

/// `ResponseHooks` releases each closure when it runs or discards the
/// closures, and does not keep a closure that comes after that.
@Suite struct ResponseHooksTests {
    @Test(.timeLimit(.minutes(hooksTestTimeout)))
    func runAllReleasesEachClosureAfterItRuns() async {
        let reference = WeakReference()
        let run = AtomicFlag()
        let hooks = ResponseHooks(logger: .disabled, requestId: unitRequestId)
        appendTrackedClosure(to: hooks, reference: reference, run: run)

        await hooks.runAll()

        #expect(run.isSet)
        #expect(!reference.isAlive)
    }

    @Test(.timeLimit(.minutes(hooksTestTimeout)))
    func aClosureAppendedAfterRunAllIsDroppedWithAWarning() async {
        let log = LogCapture()
        let reference = WeakReference()
        let run = AtomicFlag()
        let hooks = ResponseHooks(logger: log.logger, requestId: unitRequestId)
        await hooks.runAll()

        appendTrackedClosure(to: hooks, reference: reference, run: run)
        await hooks.runAll()

        #expect(!reference.isAlive)
        #expect(!run.isSet)
        #expect(log.messages.count == dropWarningCount)
        #expect(log.messages.first?.contains("dropped") == true)
    }

    @Test(.timeLimit(.minutes(hooksTestTimeout)))
    func discardAllReleasesTheClosuresAndDoesNotRunThem() async {
        let reference = WeakReference()
        let run = AtomicFlag()
        let hooks = ResponseHooks(logger: .disabled, requestId: unitRequestId)
        appendTrackedClosure(to: hooks, reference: reference, run: run)

        hooks.discardAll()
        await hooks.runAll()

        #expect(!reference.isAlive)
        #expect(!run.isSet)
    }

    @Test(.timeLimit(.minutes(hooksTestTimeout)))
    func aClosureAppendedAfterDiscardAllIsDroppedWithAWarning() async {
        let log = LogCapture()
        let reference = WeakReference()
        let run = AtomicFlag()
        let hooks = ResponseHooks(logger: log.logger, requestId: unitRequestId)
        hooks.discardAll()

        appendTrackedClosure(to: hooks, reference: reference, run: run)
        await hooks.runAll()

        #expect(!reference.isAlive)
        #expect(!run.isSet)
        #expect(log.messages.count == dropWarningCount)
        #expect(log.messages.first?.contains("dropped") == true)
    }

    @Test(.timeLimit(.minutes(hooksTestTimeout)))
    func discardAllCallsEachOnDiscardOneTimeInRegistrationOrder() async {
        let order = DiscardOrder()
        let run = AtomicFlag()
        let hooks = ResponseHooks(logger: .disabled, requestId: unitRequestId)
        for index in 0..<discardOrderEntryCount {
            hooks.append({ run.set() }, onDiscard: { order.record(index) })
        }

        hooks.discardAll()
        hooks.discardAll()
        await hooks.runAll()

        #expect(order.calls == Array(0..<discardOrderEntryCount))
        #expect(!run.isSet)
    }

    @Test(.timeLimit(.minutes(hooksTestTimeout)))
    func runAllRunsTheWorkAndDoesNotCallOnDiscard() async {
        let discards = CallCount()
        let run = AtomicFlag()
        let hooks = ResponseHooks(logger: .disabled, requestId: unitRequestId)
        hooks.append({ run.set() }, onDiscard: { discards.increment() })

        await hooks.runAll()
        hooks.discardAll()

        #expect(run.isSet)
        #expect(discards.value == 0)
    }

    @Test(.timeLimit(.minutes(hooksTestTimeout)))
    func aLateAppendWithOnDiscardAfterRunAllCallsOnDiscardAndLogsOneWarning() async {
        let log = LogCapture()
        let discards = CallCount()
        let reference = WeakReference()
        let run = AtomicFlag()
        let hooks = ResponseHooks(logger: log.logger, requestId: unitRequestId)
        await hooks.runAll()

        appendTrackedClosure(to: hooks, reference: reference, run: run) { discards.increment() }
        await hooks.runAll()
        hooks.discardAll()

        #expect(discards.value == oneDiscardCall)
        #expect(!reference.isAlive)
        #expect(!run.isSet)
        #expect(log.messages.count == dropWarningCount)
        #expect(log.messages.first?.contains("dropped") == true)
    }

    /// Appends a closure that captures a tracked object and records that it
    /// ran. The tracked object goes out of scope when this function returns,
    /// so only the closure can keep it.
    ///
    /// - Parameters:
    ///   - hooks: The collector to append to.
    ///   - reference: Keeps a weak reference to the captured object.
    ///   - run: Records if the closure runs.
    ///   - onDiscard: The handler for a discarded closure, or `nil` for no
    ///     handler.
    private func appendTrackedClosure(
        to hooks: ResponseHooks,
        reference: WeakReference,
        run: AtomicFlag,
        onDiscard: (@Sendable () -> Void)? = nil
    ) {
        let captured = reference.makeObject()
        hooks.append(
            {
                withExtendedLifetime(captured) {}
                run.set()
            },
            onDiscard: onDiscard
        )
    }
}

// MARK: - End-to-end tests through AgentSideConnection

/// `AgentSideConnection.afterRespondingToCurrentRequest(_:)` does not keep a
/// deferred closure after it runs, and drops a closure that comes after the
/// response, also while a task that the handler started is alive.
@Suite struct DeferredWorkLifetimeTests {
    /// Connects a `DeferringAgent` to a client over `InMemoryTransport`,
    /// opens the session, and sends the prompt.
    ///
    /// - Parameters:
    ///   - probe: The state that the agent and the test share.
    ///   - log: Gets the diagnostics of the agent side.
    /// - Returns: The agent and client connections.
    /// - Throws: Any error from `session/new` or `session/prompt`.
    private func prompt(
        probe: DeferralProbe,
        log: LogCapture
    ) async throws -> (agent: AgentSideConnection, client: ClientSideConnection) {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agent = await AgentSideConnection(stream: agentEnd, logger: log.logger) { connection in
            DeferringAgent(connection: connection, probe: probe)
        }
        let client = await ClientSideConnection(stream: clientEnd) { _ in QuietClient() }
        _ = try await client.newSession(NewSessionRequest(cwd: hooksWorkingDirectory))
        _ = try await client.prompt(hooksPrompt)
        return (agent, client)
    }

    @Test(.timeLimit(.minutes(hooksTestTimeout)))
    func aDeferredClosureIsReleasedWhileATaskOfTheHandlerIsAlive() async throws {
        let probe = DeferralProbe()
        let (agent, client) = try await prompt(probe: probe, log: LogCapture())
        var ran = probe.deferredClosureRan.stream.makeAsyncIterator()
        _ = try #require(await ran.next())

        try await waitUntil(timeout: releaseTimeout) { !probe.handlerCapture.isAlive }

        await probe.stopChildTask()
        await agent.close()
        await client.close()
    }

    @Test(.timeLimit(.minutes(hooksTestTimeout)))
    func aClosureDeferredByAChildTaskAfterTheResponseIsDroppedWithAWarning() async throws {
        let probe = DeferralProbe()
        let log = LogCapture()
        let (agent, client) = try await prompt(probe: probe, log: log)
        var ran = probe.deferredClosureRan.stream.makeAsyncIterator()
        _ = try #require(await ran.next())

        probe.childGate.continuation.yield()
        var deferred = probe.lateClosureDeferred.stream.makeAsyncIterator()
        _ = try #require(await deferred.next())

        #expect(!probe.lateCapture.isAlive)
        #expect(!probe.lateClosureRun.isSet)
        #expect(log.messages.contains { $0.contains("dropped") })
        await probe.stopChildTask()
        await agent.close()
        await client.close()
    }

    @Test(.timeLimit(.minutes(hooksTestTimeout)))
    func anAgentCallOutsideAnInboundRequestRunsNothingAndSignalsDiscard() async {
        let (_, agentEnd) = InMemoryTransport.pair()
        let agent = await AgentSideConnection(stream: agentEnd) { connection in
            DeferringAgent(connection: connection, probe: DeferralProbe())
        }
        let discards = CallCount()
        let reference = WeakReference()
        let run = AtomicFlag()

        TrackedWork.register(
            reference: reference,
            run: run,
            onDiscard: { discards.increment() },
            with: agent.afterRespondingToCurrentRequest(_:onDiscard:)
        )

        #expect(discards.value == oneDiscardCall)
        #expect(!reference.isAlive)
        #expect(!run.isSet)
        await agent.close()
    }
}
