import Foundation
import Synchronization

/// The number of calls of `onDiscard` that the contract permits for one
/// discarded closure.
let oneDiscardCall = 1

/// An object that a deferred closure captures. A test keeps only a weak
/// reference to it, to see when the closure is released.
final class CapturedObject: Sendable {}

/// A weak reference to a `CapturedObject`, safe to share between tasks.
final class WeakReference: Sendable {
    /// The storage of the weak reference.
    private struct Storage {
        /// The referenced object, or `nil` after it is released.
        weak var object: CapturedObject?
    }

    /// The guarded storage.
    private let storage = Mutex(Storage())

    /// `true` while the referenced object is in memory.
    var isAlive: Bool { storage.withLock { $0.object != nil } }

    /// Makes a new object, keeps a weak reference to it, and returns it.
    ///
    /// - Returns: The new object. The caller keeps the strong reference.
    func makeObject() -> CapturedObject {
        let object = CapturedObject()
        storage.withLock { $0.object = object }
        return object
    }
}

/// Records if a closure ran, safe to share between tasks.
final class RunRecord: Sendable {
    /// The guarded flag.
    private let flag = Atomic<Bool>(false)

    /// `true` after `markRan()`.
    var didRun: Bool { flag.load(ordering: .sequentiallyConsistent) }

    /// Records that the closure ran.
    func markRan() {
        flag.store(true, ordering: .sequentiallyConsistent)
    }
}

/// Defers work that a test can track: the work captures a tracked object and
/// records that it ran.
enum TrackedWork {
    /// A method that defers work and takes a handler for discarded work, for
    /// example `ClientSideConnection.afterRespondingToCurrentRequest(_:onDiscard:)`.
    typealias Deferral = (
        _ work: @escaping @Sendable () async -> Void,
        _ onDiscard: @escaping @Sendable () -> Void
    ) -> Void

    /// Defers the tracked work through `deferral`. The tracked object goes
    /// out of scope when this function returns, so only the work can keep it.
    ///
    /// - Parameters:
    ///   - reference: Keeps a weak reference to the captured object.
    ///   - run: Records if the work runs.
    ///   - onDiscard: The handler for discarded work.
    ///   - deferral: The method that defers the work.
    static func register(
        reference: WeakReference,
        run: RunRecord,
        onDiscard: @escaping @Sendable () -> Void,
        with deferral: Deferral
    ) {
        let captured = reference.makeObject()
        deferral(
            {
                withExtendedLifetime(captured) {}
                run.markRan()
            },
            onDiscard
        )
    }
}

/// Counts the calls of a closure, safe to share between tasks.
final class CallCount: Sendable {
    /// The guarded count.
    private let count = Atomic<Int>(0)

    /// The number of calls of `increment()`.
    var value: Int { count.load(ordering: .sequentiallyConsistent) }

    /// Records one call.
    func increment() {
        _ = count.add(1, ordering: .sequentiallyConsistent)
    }
}
