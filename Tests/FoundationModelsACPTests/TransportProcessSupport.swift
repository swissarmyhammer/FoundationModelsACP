import Foundation

import FoundationModelsACP

/// Anchors `Bundle(for:)` to the test bundle so the helper executable's build
/// directory can be located at runtime.
private final class BundleToken {}

/// Test-only helpers for driving real child processes over pipes.
enum TransportTestSupport {
    /// The built `acp-test-agent` helper executable, alongside the test bundle
    /// in the package's build products directory.
    static var helperAgentURL: URL {
        Bundle(for: BundleToken.self)
            .bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("acp-test-agent")
    }
}

/// Thrown when a bounded wait elapses before its condition or operation
/// completes.
struct TimedOutError: Error {}

/// Runs `operation`, throwing `TimedOutError` if it exceeds `duration`.
///
/// Keeps process/pipe tests from hanging: the operation races a sleeping
/// timeout task, and whichever finishes first cancels the other.
///
/// - Parameters:
///   - duration: The longest the operation may run.
///   - operation: The asynchronous work to bound.
/// - Returns: The operation's value when it finishes in time.
/// - Throws: `TimedOutError` on timeout, or any error the operation throws.
func withTimeout<Value: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw TimedOutError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// Polls `condition` until it holds or `timeout` elapses.
///
/// - Parameters:
///   - timeout: The longest to wait for the condition.
///   - condition: The predicate to satisfy.
/// - Throws: `TimedOutError` if the condition never holds in time.
func waitUntil(timeout: Duration, _ condition: @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    guard condition() else { throw TimedOutError() }
}

/// A do-nothing client that answers the reverse-direction methods a handshake
/// never invokes, so a `ClientSideConnection` can drive an agent in tests.
struct HandshakeClient: Client {
    /// Ignores streamed session updates.
    ///
    /// - Parameter notification: The session-update notification.
    func sessionUpdate(_ notification: SessionNotification) async {}

    /// Never called during a handshake; reports method-not-found if it is.
    ///
    /// - Parameter params: The permission request.
    /// - Returns: Never returns normally.
    /// - Throws: `RequestError.methodNotFound` always.
    func requestPermission(
        _ params: RequestPermissionRequest
    ) async throws -> RequestPermissionResponse {
        throw RequestError.methodNotFound("requestPermission")
    }
}
