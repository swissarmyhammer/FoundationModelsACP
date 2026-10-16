import Synchronization

/// Lets one handler wait until its task is cancelled. It uses no clock: the
/// cancel handler of the task resumes the waiter.
final class CancelGate: Sendable {
    /// The state of the gate.
    private enum State {
        /// No waiter and no cancel yet.
        case open
        /// A waiter that the cancel resumes.
        case waiting(CheckedContinuation<Void, Never>)
        /// The cancel came. A later waiter resumes at once.
        case fired
    }

    /// The state, shared by the waiter and the cancel handler.
    private let state = Mutex<State>(.open)

    /// Suspends until the current task is cancelled.
    func waitForCancel() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let firedBefore = state.withLock { state -> Bool in
                    if case .fired = state { return true }
                    state = .waiting(continuation)
                    return false
                }
                if firedBefore { continuation.resume() }
            }
        } onCancel: {
            fire()
        }
    }

    /// Marks the gate as fired, and resumes the waiter if there is one.
    private func fire() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            defer { state = .fired }
            if case .waiting(let continuation) = state { return continuation }
            return nil
        }
        waiter?.resume()
    }
}

/// Suspends until the current task is cancelled. It uses no clock.
func waitForTaskCancellation() async {
    await CancelGate().waitForCancel()
}
