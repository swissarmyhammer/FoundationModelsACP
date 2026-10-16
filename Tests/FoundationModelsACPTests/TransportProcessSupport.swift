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

/// Reads `bytes` until `isDone` holds for the data read so far, or until the
/// stream ends. It uses no clock: the end of the child's stdout also ends the
/// wait.
///
/// - Parameters:
///   - iterator: The iterator of the child's stdout.
///   - data: The data read so far. The read chunks are added to it.
///   - isDone: The condition that ends the read.
/// - Throws: Rethrows a failure of the stream.
func read(
    _ iterator: inout AsyncThrowingStream<Data, any Error>.Iterator,
    into data: inout Data,
    until isDone: (Data) -> Bool
) async throws {
    while !isDone(data), let chunk = try await iterator.next() {
        data.append(chunk)
    }
}

/// Terminates `process` (if still running) and asynchronously awaits its exit.
///
/// `Process.waitUntilExit()` blocks its calling thread until the child exits.
/// Called directly from an `async` test body, that blocks a Swift Concurrency
/// cooperative-pool worker; enough concurrently-reaped children (as under
/// `--maximum-repetitions` stress) can exhaust the pool and deadlock, since
/// nothing is left to run the delivery of the child's own termination. Driving
/// the wait through `terminationHandler` instead lets Foundation signal
/// completion off the cooperative pool, so awaiting it never occupies a
/// worker thread while blocked.
///
/// - Parameter process: The child process to terminate and reap.
func terminateAndAwaitExit(_ process: Process) async {
    await withCheckedContinuation { continuation in
        process.terminationHandler = { _ in continuation.resume() }
        if process.isRunning {
            process.terminate()
        }
    }
}

/// A do-nothing client that answers the reverse-direction methods a handshake
/// never invokes, so a `ClientSideConnection` can drive an agent in tests.
struct HandshakeClient: Client {
    /// Ignores streamed session updates.
    ///
    /// - Parameter notification: The session-update notification.
    func sessionUpdate(_ notification: UpdateSessionNotification) async {}

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

    /// Never called during a handshake; reports method-not-found if it is.
    ///
    /// - Parameter params: The elicitation request.
    /// - Returns: Never returns normally.
    /// - Throws: `RequestError.methodNotFound` always.
    func createElicitation(
        _ params: CreateElicitationRequest
    ) async throws -> CreateElicitationResponse {
        throw RequestError.methodNotFound("createElicitation")
    }

    /// Ignores elicitation-completion notices; a handshake never sends one.
    ///
    /// - Parameter notification: The completion notification.
    func elicitationComplete(_ notification: CompleteElicitationNotification) async {}
}

/// The `InitializeRequest` a handshake test sends: the minimum a client must
/// supply — its own implementation identity and the protocol version.
func handshakeInitializeRequest() -> InitializeRequest {
    InitializeRequest(
        info: Implementation(name: "acp-test-client", version: "0.0.0"),
        protocolVersion: .latest
    )
}
