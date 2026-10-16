import Foundation
import Synchronization

@testable import FoundationModelsACP

/// The permission request that the agent sends in the permission suites.
extension RequestPermissionRequest {
    /// The one option that `stub(for:)` offers.
    static let stubOptionId = PermissionOptionId(rawValue: "allow")

    /// Makes a permission request with one `allowOnce` option, `stubOptionId`.
    ///
    /// - Parameter sessionId: The session of the request.
    /// - Returns: The permission request.
    static func stub(for sessionId: SessionId) -> RequestPermissionRequest {
        RequestPermissionRequest(
            options: [PermissionOption(kind: .allowOnce, name: "Allow", optionId: stubOptionId)],
            sessionId: sessionId,
            title: "Permission needed"
        )
    }
}

/// The outcome that the permission suites expect from a handler that is not
/// cancelled.
extension RequestPermissionOutcome {
    /// Selects the one option of `RequestPermissionRequest.stub(for:)`. It is
    /// not `cancelled`, so a test can tell the two outcomes apart.
    static let selectedStubOption = RequestPermissionOutcome.selected(
        SelectedPermissionOutcome(optionId: RequestPermissionRequest.stubOptionId)
    )
}

/// A release that each waiting task gets one time. A cancellation of a
/// waiting task does not end its wait, so a handler that waits here stands
/// for a handler that ignores cancellation.
final class Gate: Sendable {
    /// `true` after `open()`, and the tasks that wait for it.
    private let state = Mutex<(isOpen: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    /// Releases each waiting task, and each task that waits later.
    func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Waits until `open()` runs.
    func wait() async {
        await withCheckedContinuation { continuation in
            let isOpen = state.withLock { state in
                if !state.isOpen {
                    state.waiters.append(continuation)
                }
                return state.isOpen
            }
            if isOpen {
                continuation.resume()
            }
        }
    }
}

/// One event on a probe stream of `PermissionProbes`.
enum PermissionProbeEvent<Value: Sendable>: Sendable {
    /// The handler did the step that the probe records.
    case value(Value)

    /// A failure event came while a wait was possibly active. The value is
    /// the wait generation at the time of the event. A wait ignores an
    /// interrupt from a generation before its own.
    case interrupt(generation: Int)
}

/// The probes of a `GatedPermissionClient`: the steps of its handlers, as
/// streams that the test waits on.
///
/// Each wait ends on the step that it waits for, or on a failure event: the
/// client writes a frame before the step, a request of the test fails, or
/// the client connection shuts down. Thus a wait for a step that does not
/// come does not hang the test. It uses no clock.
final class PermissionProbes: Sendable {
    /// The sessions of the permission requests that reached the handler.
    let entered: AsyncStream<PermissionProbeEvent<SessionId>>

    /// One value for each permission handler that ended.
    let exited: AsyncStream<PermissionProbeEvent<Void>>

    /// One value for each permission handler whose task is cancelled.
    let cancelled: AsyncStream<PermissionProbeEvent<Void>>

    /// Feeds `entered`.
    private let enteredInput: AsyncStream<PermissionProbeEvent<SessionId>>.Continuation

    /// Feeds `exited`.
    private let exitedInput: AsyncStream<PermissionProbeEvent<Void>>.Continuation

    /// Feeds `cancelled`.
    private let cancelledInput: AsyncStream<PermissionProbeEvent<Void>>.Continuation

    /// The generation of the most recent wait. Each wait increments it.
    private let generation = Mutex(0)

    /// Makes the probes, with empty streams.
    init() {
        (entered, enteredInput) = AsyncStream.makeStream()
        (exited, exitedInput) = AsyncStream.makeStream()
        (cancelled, cancelledInput) = AsyncStream.makeStream()
    }

    /// Records that a handler started for a request of `sessionId`.
    ///
    /// - Parameter sessionId: The session of the request.
    func recordEntered(_ sessionId: SessionId) {
        enteredInput.yield(.value(sessionId))
    }

    /// Records that a handler ended.
    func recordExited() {
        exitedInput.yield(.value(()))
    }

    /// Records that the task of a handler is cancelled.
    func recordCancelled() {
        cancelledInput.yield(.value(()))
    }

    /// Ends the wait that is active now, if there is one. A wait that starts
    /// later does not see this interrupt.
    func interrupt() {
        let current = generation.withLock { $0 }
        enteredInput.yield(.interrupt(generation: current))
        exitedInput.yield(.interrupt(generation: current))
        cancelledInput.yield(.interrupt(generation: current))
    }

    /// Finishes each probe stream. Each wait, now and later, ends with `nil`.
    func finish() {
        enteredInput.finish()
        exitedInput.finish()
        cancelledInput.finish()
    }

    /// Waits for the next value of a probe stream.
    ///
    /// - Parameter stream: The probe stream.
    /// - Returns: The next value, or `nil` when an interrupt of this wait
    ///   came first, or when the stream finished.
    func nextValue<Value>(of stream: AsyncStream<PermissionProbeEvent<Value>>) async -> Value? {
        let ownGeneration = generation.withLock { value in
            value += 1
            return value
        }
        var iterator = stream.makeAsyncIterator()
        while let event = await iterator.next() {
            switch event {
            case .value(let value):
                return value
            case .interrupt(let eventGeneration) where eventGeneration >= ownGeneration:
                return nil
            case .interrupt:
                continue
            }
        }
        return nil
    }
}

/// A transport of the client side that interrupts the probe waits each time
/// the client writes a frame.
///
/// The gated handler writes nothing before the step that a test waits for.
/// Thus a frame that the client writes during a wait shows that the step
/// will not come, for example an error response in place of a call to the
/// handler.
private struct ProbeInterruptingTransport: ACPTransport {
    /// The transport that does the work.
    let underlying: any ACPTransport

    /// The probes to interrupt.
    let probes: PermissionProbes

    var bytes: AsyncThrowingStream<Data, any Error> { underlying.bytes }

    /// Interrupts the probe waits, and then writes `data`.
    ///
    /// - Parameter data: The outgoing bytes.
    /// - Throws: Any error from the underlying transport.
    func write(_ data: Data) async throws {
        probes.interrupt()
        try await underlying.write(data)
    }
}

/// A client whose `requestPermission(_:)` handler tells the test that it
/// started, waits for a gate, and then gives a fixed outcome. The gate stands
/// for a human who still looks at the prompt.
///
/// When the task of a handler is cancelled, the handler tells the test, and
/// still waits for the gate. After the gate opens, that handler throws
/// `CancellationError`: it stands for a client that removes the prompt when
/// the agent withdraws the request.
struct GatedPermissionClient: Client {
    /// Gets the steps of each handler.
    let probes: PermissionProbes

    /// The gate that each handler waits for.
    let gate: Gate

    /// The outcome that each handler gives after the gate opens.
    let outcome: RequestPermissionOutcome

    func sessionUpdate(_ notification: UpdateSessionNotification) async {}

    /// Waits for the gate, and then gives `outcome`.
    ///
    /// - Parameter request: The permission request.
    /// - Returns: The response with `outcome`.
    /// - Throws: `CancellationError` when the task of the handler was
    ///   cancelled before the gate opened.
    func requestPermission(_ request: RequestPermissionRequest) async throws -> RequestPermissionResponse {
        probes.recordEntered(request.sessionId)
        await withTaskCancellationHandler {
            await gate.wait()
        } onCancel: { [probes] in
            probes.recordCancelled()
        }
        probes.recordExited()
        try Task.checkCancellation()
        return RequestPermissionResponse(outcome: outcome)
    }

    func createElicitation(_ request: CreateElicitationRequest) async throws -> CreateElicitationResponse {
        throw RequestError.methodNotFound("createElicitation")
    }

    func elicitationComplete(_ notification: CompleteElicitationNotification) async {}
}

/// A `ClientSideConnection` that serves a `GatedPermissionClient`, the agent
/// end of its transport, and the probes of the handler.
///
/// Each permission suite makes its connection with `connect(outcome:clientTransport:)`.
/// A suite serves a `StubAgent` on `agentEnd` with `connectStubAgent()`, or
/// reads and writes raw frames on it.
struct GatedPermissionConnection {
    /// The client side.
    let client: ClientSideConnection

    /// The agent end of the transport. No connection serves it yet.
    let agentEnd: InMemoryTransport

    /// The gate of the permission handler.
    let gate: Gate

    /// The steps of the permission handlers.
    let probes: PermissionProbes

    /// A session that no test uses. The update stream of this session
    /// finishes when the client connection shuts down. That end finishes the
    /// probes.
    private static let shutdownProbeSession = SessionId(rawValue: "gated-permission-shutdown-probe")

    /// Connects a `GatedPermissionClient` to an `InMemoryTransport` pair.
    ///
    /// Each probe wait also ends when the client writes a frame during the
    /// wait, and when the client connection shuts down.
    ///
    /// - Parameters:
    ///   - outcome: The outcome that the handler gives after the gate opens.
    ///   - clientTransport: Makes the transport of the client side from the
    ///     client end of the pair. The default uses the client end as it is.
    /// - Returns: The connection.
    static func connect(
        outcome: RequestPermissionOutcome,
        clientTransport: (InMemoryTransport) -> any ACPTransport = { $0 }
    ) async -> GatedPermissionConnection {
        let gate = Gate()
        let probes = PermissionProbes()
        let (clientEnd, agentEnd) = InMemoryTransport.pair()
        let transport = ProbeInterruptingTransport(underlying: clientTransport(clientEnd), probes: probes)
        let client = await ClientSideConnection(stream: transport) { _ in
            GatedPermissionClient(probes: probes, gate: gate, outcome: outcome)
        }
        // The connection finishes each update stream when it shuts down,
        // before its handlers end. Thus a wait for a handler step ends when
        // the peer is gone or the connection closes.
        let shutdown = client.subscribe(to: shutdownProbeSession).updates
        Task {
            for await _ in shutdown {}
            probes.finish()
        }
        return GatedPermissionConnection(client: client, agentEnd: agentEnd, gate: gate, probes: probes)
    }

    /// Ends each probe wait, now and later. A test calls it when a request
    /// that it sent failed, because then the handler step does not come.
    func endWaits() {
        probes.finish()
    }

    /// Serves a `StubAgent` on `agentEnd`.
    ///
    /// - Returns: The agent side, which sends `session/request_permission`.
    func connectStubAgent() async -> AgentSideConnection {
        await AgentSideConnection(stream: agentEnd) { _ in StubAgent() }
    }

    /// Waits until the next permission request reaches the handler.
    ///
    /// - Returns: The session of the request, or `nil` when a failure event
    ///   ended the wait first.
    func waitUntilEntered() async -> SessionId? {
        await probes.nextValue(of: probes.entered)
    }

    /// Waits until the task of the next permission handler is cancelled.
    ///
    /// - Returns: `true` when a handler task is cancelled, or `false` when a
    ///   failure event ended the wait first.
    func waitUntilCancelled() async -> Bool {
        await probes.nextValue(of: probes.cancelled) != nil
    }

    /// Waits until the next permission handler ends.
    ///
    /// - Returns: `true` when a handler ended, or `false` when a failure
    ///   event ended the wait first.
    func waitUntilExited() async -> Bool {
        await probes.nextValue(of: probes.exited) != nil
    }

    /// Opens the gate, closes the client side, and closes the agent end of
    /// the transport. The open gate lets each waiting handler end, so the
    /// close does not wait for a human. Use it also when the test body
    /// throws.
    func close() async {
        gate.open()
        await client.close()
        agentEnd.close()
    }
}
