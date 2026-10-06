import Foundation
import Testing

@testable import FoundationModelsACP

// MARK: - Fixtures

/// The time limit of each test in this suite, in minutes.
private let clientHooksTestTimeout = 1

/// The number of permission round trips that the ordering test examines.
private let orderingRunCount = 100

/// The event that deferred work records in the `EventLog`.
private let hookEvent = "hook"

/// The kind that `LoggingTransport` records for a response frame.
private let responseFrame = "response"

/// The kind that `LoggingTransport` records for an outbound request frame.
private let outboundRequestFrame = "other"

/// The permission request that the agent sends in each test.
private let permissionRequest = RequestPermissionRequest(
    options: [PermissionOption(kind: .allowOnce, name: "Allow", optionId: PermissionOptionId(rawValue: "allow"))],
    sessionId: StubAgent.sessionId,
    title: "Permission needed"
)

/// The prompt that the client sends after the deferred work ran.
private let followUpPrompt = PromptRequest(
    prompt: [.text(TextContent(text: "next"))],
    sessionId: StubAgent.sessionId
)

/// The handler body that a test gives to `ScriptedPermissionClient`. It gets
/// the connection of the client.
private typealias PermissionScript = @Sendable (ClientSideConnection) async -> Void

/// A client whose `requestPermission(_:)` handler runs a script that the test
/// gives, and then answers `cancelled`.
private struct ScriptedPermissionClient: Client {
    /// The connection that the factory gave this client.
    let connection: ClientSideConnection

    /// The body of the permission handler.
    let script: PermissionScript

    func sessionUpdate(_ notification: UpdateSessionNotification) async {}

    /// Runs the script on the dispatch task of the request, then answers.
    ///
    /// - Parameter params: The permission request.
    /// - Returns: The `cancelled` outcome.
    func requestPermission(_ params: RequestPermissionRequest) async throws -> RequestPermissionResponse {
        await script(connection)
        return RequestPermissionResponse(outcome: .cancelled)
    }

    func createElicitation(_ params: CreateElicitationRequest) async throws -> CreateElicitationResponse {
        throw RequestError.methodNotFound("createElicitation")
    }

    func elicitationComplete(_ notification: CompleteElicitationNotification) async {}
}

/// The two ends of one test connection.
private struct ConnectedPair {
    /// The agent side, which sends `session/request_permission`.
    let agent: AgentSideConnection

    /// The client side, whose outgoing frames go to the event log.
    let client: ClientSideConnection

    /// Closes the two sides.
    func close() async {
        await client.close()
        await agent.close()
    }
}

// MARK: - Tests

/// `ClientSideConnection.afterRespondingToCurrentRequest(_:onDiscard:)` runs
/// deferred work only after the connection wrote the response of the
/// current request, and calls `onDiscard` one time when the work can never
/// run.
@Suite struct ClientResponseHooksTests {
    /// Connects a `StubAgent` to a `ScriptedPermissionClient` over
    /// `InMemoryTransport`. The client transport records each outgoing frame
    /// in `log`.
    ///
    /// - Parameters:
    ///   - log: Gets the kind of each frame that the client writes.
    ///   - script: The body of the permission handler of the client.
    /// - Returns: The two connected sides.
    private func connect(log: EventLog, script: @escaping PermissionScript) async -> ConnectedPair {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let agent = await AgentSideConnection(stream: agentEnd) { _ in StubAgent() }
        let client = await ClientSideConnection(stream: LoggingTransport(underlying: clientEnd, log: log)) {
            ScriptedPermissionClient(connection: $0, script: script)
        }
        return ConnectedPair(agent: agent, client: client)
    }

    @Test(.timeLimit(.minutes(clientHooksTestTimeout)))
    func hookRunsAfterPermissionResponseIsWritten() async throws {
        let log = EventLog()
        let hookRan = AsyncStream<Void>.makeStream()
        let pair = await connect(log: log) { connection in
            connection.afterRespondingToCurrentRequest {
                await log.record(hookEvent)
                hookRan.continuation.yield()
            }
        }

        _ = try await pair.agent.requestPermission(permissionRequest)
        var ran = hookRan.stream.makeAsyncIterator()
        _ = try #require(await ran.next())

        #expect(await log.events == [responseFrame, hookEvent])
        await pair.close()
    }

    @Test(.timeLimit(.minutes(clientHooksTestTimeout)))
    func callOutsideInboundRequestRunsNothingAndSignalsDiscard() async {
        let pair = await connect(log: EventLog()) { _ in }
        let discards = CallCount()
        let reference = WeakReference()
        let run = AtomicFlag()

        TrackedWork.register(
            reference: reference,
            run: run,
            onDiscard: { discards.increment() },
            with: pair.client.afterRespondingToCurrentRequest(_:onDiscard:)
        )

        #expect(discards.value == oneDiscardCall)
        #expect(!reference.isAlive)
        #expect(!run.isSet)
        await pair.close()
    }

    @Test(.timeLimit(.minutes(clientHooksTestTimeout)))
    func closeBeforeResponseDiscardsWorkAndSignalsDiscard() async throws {
        let entered = AsyncStream<Void>.makeStream()
        let gate = AsyncStream<Void>.makeStream()
        let discarded = AsyncStream<Void>.makeStream()
        let discards = CallCount()
        let reference = WeakReference()
        let run = AtomicFlag()
        let pair = await connect(log: EventLog()) { connection in
            TrackedWork.register(
                reference: reference,
                run: run,
                onDiscard: {
                    discards.increment()
                    discarded.continuation.yield()
                },
                with: connection.afterRespondingToCurrentRequest(_:onDiscard:)
            )
            entered.continuation.yield()
            var release = gate.stream.makeAsyncIterator()
            _ = await release.next()
        }
        let permission = Task { try await pair.agent.requestPermission(permissionRequest) }
        var enteredIterator = entered.stream.makeAsyncIterator()
        _ = try #require(await enteredIterator.next())

        await pair.client.close()
        gate.continuation.finish()
        var discardedIterator = discarded.stream.makeAsyncIterator()
        _ = try #require(await discardedIterator.next())
        _ = await pair.client.closed

        #expect(discards.value == oneDiscardCall)
        #expect(!run.isSet)
        #expect(!reference.isAlive)
        await pair.agent.close()
        _ = try? await permission.value
    }

    @Test(.timeLimit(.minutes(clientHooksTestTimeout)))
    func outboundRequestAfterHookIsWrittenAfterResponse() async throws {
        let log = EventLog()
        let hookRan = AsyncStream<Void>.makeStream()
        let pair = await connect(log: log) { connection in
            connection.afterRespondingToCurrentRequest { hookRan.continuation.yield() }
        }
        var waiter = hookRan.stream.makeAsyncIterator()

        for run in 0..<orderingRunCount {
            await log.reset()
            let permission = Task { try await pair.agent.requestPermission(permissionRequest) }
            _ = try #require(await waiter.next())
            _ = try await pair.client.prompt(followUpPrompt)
            _ = try await permission.value

            #expect(await log.events == [responseFrame, outboundRequestFrame], "run \(run)")
        }
        await pair.close()
    }
}
