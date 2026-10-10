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

/// A client whose `requestPermission(_:)` handler tells the test that it
/// started, waits for a gate, and then gives a fixed outcome. The gate stands
/// for a human who still looks at the prompt.
///
/// When the task of a handler is cancelled, the handler tells the test, and
/// still waits for the gate. After the gate opens, that handler throws
/// `CancellationError`: it stands for a client that removes the prompt when
/// the agent withdraws the request.
struct GatedPermissionClient: Client {
    /// Gets the session of each permission request that the handler starts.
    let entered: AsyncStream<SessionId>.Continuation

    /// Gets one value for each handler that ended, or `nil` when the test
    /// does not watch the end of the handler.
    let exited: AsyncStream<Void>.Continuation?

    /// Gets one value for each handler whose task is cancelled, or `nil`
    /// when the test does not watch the cancellation.
    let cancelled: AsyncStream<Void>.Continuation?

    /// The gate that each handler waits for.
    let gate: Gate

    /// The outcome that each handler gives after the gate opens.
    let outcome: RequestPermissionOutcome

    /// Makes a client whose permission handler waits for `gate`.
    ///
    /// - Parameters:
    ///   - entered: Gets the session of each permission request that the
    ///     handler starts.
    ///   - exited: Gets one value for each handler that ended. The default,
    ///     `nil`, records nothing.
    ///   - cancelled: Gets one value for each handler whose task is
    ///     cancelled. The default, `nil`, records nothing.
    ///   - gate: The gate that each handler waits for.
    ///   - outcome: The outcome that each handler gives after the gate opens.
    init(
        entered: AsyncStream<SessionId>.Continuation,
        exited: AsyncStream<Void>.Continuation? = nil,
        cancelled: AsyncStream<Void>.Continuation? = nil,
        gate: Gate,
        outcome: RequestPermissionOutcome
    ) {
        self.entered = entered
        self.exited = exited
        self.cancelled = cancelled
        self.gate = gate
        self.outcome = outcome
    }

    func sessionUpdate(_ notification: UpdateSessionNotification) async {}

    /// Waits for the gate, and then gives `outcome`.
    ///
    /// - Parameter params: The permission request.
    /// - Returns: The response with `outcome`.
    /// - Throws: `CancellationError` when the task of the handler was
    ///   cancelled before the gate opened.
    func requestPermission(_ params: RequestPermissionRequest) async throws -> RequestPermissionResponse {
        entered.yield(params.sessionId)
        await withTaskCancellationHandler {
            await gate.wait()
        } onCancel: { [cancelled] in
            cancelled?.yield()
        }
        exited?.yield()
        try Task.checkCancellation()
        return RequestPermissionResponse(outcome: outcome)
    }

    func createElicitation(_ params: CreateElicitationRequest) async throws -> CreateElicitationResponse {
        throw RequestError.methodNotFound("createElicitation")
    }

    func elicitationComplete(_ notification: CompleteElicitationNotification) async {}
}
