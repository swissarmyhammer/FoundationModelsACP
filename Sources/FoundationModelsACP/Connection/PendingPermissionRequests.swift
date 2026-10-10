import Foundation
import Synchronization

/// The inbound `session/request_permission` requests that the client did not
/// answer yet, recorded by session.
///
/// The spec says that a client that sends `session/cancel` MUST answer each
/// pending `session/request_permission` of that session with the `cancelled`
/// outcome. `ClientSideConnection` sends each permission request through
/// ``answer(_:using:)``, and calls ``cancelAll(in:)`` when it sends
/// `session/cancel`.
///
/// The handler of each request runs in its own task, so that a cancel can
/// answer the request before the handler returns. The connection then ignores
/// the late result of the handler.
///
/// A `$/cancel_request` for a pending permission request has a different
/// rule. The ACP v2 cancellation rules
/// (https://agentclientprotocol.com/protocol/v2/cancellation) say that the
/// receiver MUST send a valid response or a `-32800` error. Thus the
/// connection cancels the handler task and sends the result of the handler:
/// its answer, or `-32800` when it throws `CancellationError`. It does not
/// send the `cancelled` outcome, which is the answer to `session/cancel`
/// only. When `session/cancel` answered the request first, a later
/// `$/cancel_request` for it finds no request, and the connection sends no
/// second response.
final class PendingPermissionRequests: Sendable {
    /// The handler that answers one permission request: the
    /// `Client.requestPermission(_:)` of the served client.
    typealias Handler = @Sendable (RequestPermissionRequest) async throws -> RequestPermissionResponse

    /// The answers that wait, by session, and in each session by the identity
    /// of the answer.
    private let pending = Mutex<[SessionId: [ObjectIdentifier: PermissionAnswer]]>([:])

    /// Answers one permission request with the result of `handler`, or with
    /// the `cancelled` outcome when ``cancelAll(in:)`` names its session
    /// first.
    ///
    /// Call this on the task that dispatches the request. The handler runs in
    /// a new task, which keeps the task-local values of the dispatch task, so
    /// `afterRespondingToCurrentRequest` in the handler finds the request.
    ///
    /// When the dispatch task is cancelled (for example, by a
    /// `$/cancel_request` from the agent), the handler task is cancelled too,
    /// and the result of the handler is the answer. A `CancellationError`
    /// from the handler gives the `-32800` error, not the `cancelled`
    /// outcome (see the type documentation).
    ///
    /// When the cancel comes first, this method returns the `cancelled`
    /// outcome at once and cancels the handler task. The dispatch task then
    /// waits for the handler task after the connection wrote the response, so
    /// the connection close still waits for the handler.
    ///
    /// - Parameters:
    ///   - request: The permission request.
    ///   - handler: Gives the answer of the client.
    /// - Returns: The answer of the handler, or the `cancelled` outcome.
    /// - Throws: The error of the handler, when the handler answers first.
    func answer(
        _ request: RequestPermissionRequest,
        using handler: @escaping Handler
    ) async throws -> RequestPermissionResponse {
        let answer = PermissionAnswer()
        register(answer, for: request.sessionId)
        defer { unregister(answer, for: request.sessionId) }
        let handlerTask = Task { answer.resolve(.answered(await Self.result(of: handler, for: request))) }
        let resolution = await withTaskCancellationHandler {
            await answer.resolution()
        } onCancel: {
            handlerTask.cancel()
        }
        switch resolution {
        case .answered(let result):
            return try result.get()
        case .sessionCancelled:
            handlerTask.cancel()
            Connection.deferAfterCurrentResponse({ await handlerTask.value }, onDiscard: nil)
            return RequestPermissionResponse(outcome: .cancelled)
        }
    }

    /// Answers each pending permission request of one session with the
    /// `cancelled` outcome, and forgets the requests.
    ///
    /// A permission request that arrives after this call is not affected: it
    /// goes to the handler as usual.
    ///
    /// - Parameter sessionId: The session whose requests to cancel.
    func cancelAll(in sessionId: SessionId) {
        let answers = pending.withLock { $0.removeValue(forKey: sessionId) ?? [:] }
        for answer in answers.values {
            answer.resolve(.sessionCancelled)
        }
    }

    /// Records one answer that waits.
    ///
    /// - Parameters:
    ///   - answer: The answer of the request.
    ///   - sessionId: The session of the request.
    private func register(_ answer: PermissionAnswer, for sessionId: SessionId) {
        pending.withLock { $0[sessionId, default: [:]][ObjectIdentifier(answer)] = answer }
    }

    /// Forgets one answer. Does nothing when ``cancelAll(in:)`` forgot it
    /// before.
    ///
    /// - Parameters:
    ///   - answer: The answer of the request.
    ///   - sessionId: The session of the request.
    private func unregister(_ answer: PermissionAnswer, for sessionId: SessionId) {
        pending.withLock { pending in
            pending[sessionId]?.removeValue(forKey: ObjectIdentifier(answer))
            if pending[sessionId]?.isEmpty == true {
                pending.removeValue(forKey: sessionId)
            }
        }
    }

    /// Runs the handler, and keeps its error as a value.
    ///
    /// - Parameters:
    ///   - handler: Gives the answer of the client.
    ///   - request: The permission request.
    /// - Returns: The answer of the handler, or its error.
    private static func result(
        of handler: Handler,
        for request: RequestPermissionRequest
    ) async -> Result<RequestPermissionResponse, any Error> {
        do {
            return .success(try await handler(request))
        } catch {
            return .failure(error)
        }
    }
}

/// The answer of one pending permission request. The first resolution wins,
/// and the answer ignores each later one.
private final class PermissionAnswer: Sendable {
    /// What answered the request.
    enum Resolution: Sendable {
        /// The handler returned this answer, or threw this error.
        case answered(Result<RequestPermissionResponse, any Error>)

        /// `session/cancel` cancelled the session of the request.
        case sessionCancelled
    }

    /// The life cycle of the answer.
    private enum State {
        /// No resolution yet. The continuation is the task that waits, when
        /// it waits.
        case waiting(CheckedContinuation<Resolution, Never>?)

        /// The first resolution.
        case resolved(Resolution)
    }

    /// The guarded state.
    private let state = Mutex(State.waiting(nil))

    /// Sets the resolution, when the answer has none yet, and resumes the
    /// task that waits for it.
    ///
    /// - Parameter resolution: What answered the request.
    func resolve(_ resolution: Resolution) {
        let waiter: CheckedContinuation<Resolution, Never>? = state.withLock { state in
            guard case .waiting(let waiter) = state else { return nil }
            state = .resolved(resolution)
            return waiter
        }
        waiter?.resume(returning: resolution)
    }

    /// Waits for the first resolution. Call it one time.
    ///
    /// - Returns: The first resolution.
    func resolution() async -> Resolution {
        await withCheckedContinuation { continuation in
            let resolved: Resolution? = state.withLock { state in
                switch state {
                case .waiting:
                    state = .waiting(continuation)
                    return nil
                case .resolved(let resolution):
                    return resolution
                }
            }
            if let resolved {
                continuation.resume(returning: resolved)
            }
        }
    }
}
