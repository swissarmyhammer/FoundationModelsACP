import Synchronization

/// Gives the close reason of one `Connection` to each task that waits for it.
///
/// The signal fires one time. Each waiter, also a waiter that starts after the
/// signal fired, gets the same reason.
///
/// A plain class guarded by a lock rather than an actor: `wait()` must record
/// the waiter and `fire(_:)` must read the waiters in one step. Then no
/// waiter can come between the two steps and never get the reason.
final class ConnectionCloseSignal: Sendable {
    /// The life cycle of the signal.
    private enum State {
        /// The signal did not fire. The continuations of the tasks that wait.
        case waiting([CheckedContinuation<ConnectionCloseReason, Never>])

        /// The signal fired with this reason.
        case fired(ConnectionCloseReason)
    }

    /// The guarded state.
    private let state = Mutex(State.waiting([]))

    /// Waits until the signal fires, and gives its reason. Gives the reason
    /// at once when the signal already fired.
    ///
    /// The wait does not stop when the task is cancelled, as `Task.value`.
    ///
    /// - Returns: The reason of the signal.
    func wait() async -> ConnectionCloseReason {
        await withCheckedContinuation { continuation in
            let firedReason = state.withLock { state -> ConnectionCloseReason? in
                switch state {
                case .waiting(let waiters):
                    state = .waiting(waiters + [continuation])
                    return nil
                case .fired(let reason):
                    return reason
                }
            }
            if let firedReason {
                continuation.resume(returning: firedReason)
            }
        }
    }

    /// Fires the signal: gives `reason` to each waiter. A call after the
    /// first call has no effect.
    ///
    /// - Parameter reason: The reason that each waiter gets.
    func fire(_ reason: ConnectionCloseReason) {
        let waiters = state.withLock { state -> [CheckedContinuation<ConnectionCloseReason, Never>] in
            guard case .waiting(let waiters) = state else { return [] }
            state = .fired(reason)
            return waiters
        }
        for waiter in waiters {
            waiter.resume(returning: reason)
        }
    }
}
