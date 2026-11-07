import Synchronization

/// Holds the read loop of one `Connection` until the owner opens it.
///
/// A role connection starts its read loop before its factory builds the
/// role. Frames can already be in the transport at that time, for example an
/// `initialize` that the peer wrote while the process started. The read loop
/// waits on this gate before it reads the first frame, so no frame is
/// dispatched before the role is set.
///
/// A plain class guarded by a lock rather than an actor: `wait()` must record
/// the waiter and `open()` must read the waiter in one step.
final class InboundGate: Sendable {
    /// The life cycle of the gate.
    private enum State {
        /// The gate is closed and no task waits.
        case closed
        /// The gate is closed and this task waits.
        case waiting(CheckedContinuation<Void, Never>)
        /// The gate is open, or the waiting task was cancelled.
        case open
    }

    /// The guarded state.
    private let state = Mutex(State.closed)

    /// Runs when a task starts to wait on the closed gate. Only a test gives
    /// a value.
    private let onWait: (@Sendable () -> Void)?

    /// Creates a closed gate.
    ///
    /// - Parameter onWait: Runs when a task starts to wait on the closed
    ///   gate. Only a test gives a value.
    init(onWait: (@Sendable () -> Void)? = nil) {
        self.onWait = onWait
    }

    /// Waits until the gate opens. Returns at once when the gate is open.
    ///
    /// Only one task waits on a gate: the read loop. When that task is
    /// cancelled, the wait stops and the gate opens.
    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let parked = state.withLock { state -> Bool in
                    guard case .closed = state else { return false }
                    state = .waiting(continuation)
                    return true
                }
                if parked {
                    onWait?()
                } else {
                    continuation.resume()
                }
            }
        } onCancel: {
            open()
        }
    }

    /// Opens the gate and releases the waiting task. A call after the first
    /// call has no effect.
    func open() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            defer { state = .open }
            guard case .waiting(let continuation) = state else { return nil }
            return continuation
        }
        waiter?.resume()
    }
}
