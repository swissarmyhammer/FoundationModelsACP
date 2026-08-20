import Foundation
import Synchronization

/// Anchors `Bundle(for:)` to this test bundle so the helper executable's
/// build-products directory can be located at runtime.
private final class BundleToken {}

/// Shared paths and process plumbing for the schema-conformance suite.
enum TestSupport {
    /// The repository root, derived from this file's location rather than the
    /// test runner's working directory: `Tests/FoundationModelsACPIntegrationTests/`
    /// → `IntegrationTests` → the repository root.
    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // FoundationModelsACPIntegrationTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // IntegrationTests
        .deletingLastPathComponent()  // repository root

    /// The built `acp-test-agent` helper executable, alongside this test
    /// bundle in the package's build-products directory. `../Package.swift`
    /// declares it as an `.executable` product so this sibling package can
    /// build it and find it here.
    static var helperAgentURL: URL {
        Bundle(for: BundleToken.self)
            .bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("acp-test-agent")
    }

    /// Reads and JSON-decodes a repository-tree-relative file into a
    /// `JSONSerialization` object graph.
    ///
    /// - Parameter treeRelativePath: The path relative to `repositoryRoot`.
    /// - Returns: The decoded top-level JSON value.
    /// - Throws: An error when the file cannot be read or parsed.
    static func jsonObject(atTreeRelativePath treeRelativePath: String) throws -> Any {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(treeRelativePath))
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Reads a repository-tree-relative newline-delimited JSON file, decoding
    /// every non-empty line.
    ///
    /// - Parameter treeRelativePath: The path relative to `repositoryRoot`.
    /// - Returns: One decoded JSON value per non-empty line, in file order.
    /// - Throws: An error when the file cannot be read, or a line fails to parse.
    static func ndjsonObjects(atTreeRelativePath treeRelativePath: String) throws -> [Any] {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(treeRelativePath))
        let text = String(decoding: data, as: UTF8.self)
        return try text.split(separator: "\n").map { line in
            try JSONSerialization.jsonObject(with: Data(line.utf8), options: [.fragmentsAllowed])
        }
    }
}

/// Thrown when a bounded wait elapses before its condition or operation
/// completes.
struct TimedOutError: Error {}

/// Carries a non-`Sendable` value across a `@Sendable` closure boundary.
///
/// Safe only when the caller guarantees the boxed value is not touched
/// concurrently — here, a `JSONSerialization` object graph that is produced
/// on one task and read only after `withTimeout` hands it back.
private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
}

/// Runs `operation`, throwing `TimedOutError` if it exceeds `duration`.
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

/// A real `acp-test-agent` child process, driven over raw stdio pipes with no
/// dependency on this library's own transport types — proving the schema
/// conformance of the actual bytes a black-box ACP client would see.
///
/// `@unchecked Sendable`: `process`/`stdin`/`stdout` are `let`-bound and never
/// mutated after `init`, and the only mutable state (`stdoutBuffer`) is a
/// `Mutex`.
final class LiveAgentProcess: @unchecked Sendable {
    private let process: Process
    private let stdin: Pipe
    private let stdout: Pipe
    private let stdoutBuffer = Mutex<Data>(Data())

    /// Launches `acp-test-agent`.
    ///
    /// - Throws: An error when the process fails to launch.
    init() throws {
        process = Process()
        process.executableURL = TestSupport.helperAgentURL
        stdin = Pipe()
        stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()  // discarded; the agent logs here

        // `readabilityHandler` fires on a Dispatch-managed background queue,
        // not a Swift Concurrency cooperative-pool thread — the async reader
        // below only ever polls the already-collected buffer, so nothing
        // here risks the pool-exhaustion deadlock a blocking `.availableData`
        // read from an `async` body would (see `../Tests/FoundationModelsACPTests/TransportProcessSupport.swift`'s `terminateAndAwaitExit`, which
        // documents the same hazard for reaping child processes).
        stdout.fileHandleForReading.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stdoutBuffer.withLock { $0.append(chunk) }
        }

        try process.run()
    }

    /// Sends one JSON-RPC request and waits for the line-delimited response
    /// carrying a matching `id`.
    ///
    /// - Parameters:
    ///   - id: The request id.
    ///   - method: The JSON-RPC method name.
    ///   - params: The request params, as a `JSONSerialization` value.
    /// - Returns: The request envelope sent and the response envelope
    ///   received (an object with `id` and either `result` or `error`) — both
    ///   real wire bytes, for the caller to validate against the schema.
    /// - Throws: `TimedOutError` if no matching response arrives in time.
    func request(
        id: Int,
        method: String,
        params: [String: Any]
    ) async throws -> (sent: [String: Any], received: [String: Any]) {
        let envelope: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        try send(envelope)
        // `[String: Any]` (a `JSONSerialization` object graph) is not
        // `Sendable`; `withTimeout`'s generic bound requires one, so the
        // racing closure returns a boxed, `@unchecked Sendable` wrapper
        // instead — safe here because nothing else touches the value until
        // it is unboxed on this task after the race resolves.
        let receivedBox = try await withTimeout(.seconds(10)) {
            UncheckedBox(value: try await self.nextLine { object in
                (object["id"] as? Int) == id && (object["result"] != nil || object["error"] != nil)
            })
        }
        return (envelope, receivedBox.value)
    }

    /// Sends one JSON-RPC notification (no `id`, no response expected).
    ///
    /// - Parameters:
    ///   - method: The JSON-RPC method name.
    ///   - params: The notification params, as a `JSONSerialization` value.
    /// - Returns: The notification envelope sent, for the caller to validate
    ///   against the schema.
    /// - Throws: An error if the bytes cannot be written.
    @discardableResult
    func notify(method: String, params: [String: Any]) throws -> [String: Any] {
        let envelope: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        try send(envelope)
        return envelope
    }

    private func send(_ envelope: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.fragmentsAllowed])
        stdin.fileHandleForWriting.write(data)
        stdin.fileHandleForWriting.write(Data([0x0A]))
    }

    /// Reads stdout until a line satisfying `predicate` decodes, buffering
    /// (and discarding) any lines that do not match — the caller is
    /// responsible for interleaving reads with the traffic it expects.
    private func nextLine(where predicate: ([String: Any]) -> Bool) async throws -> [String: Any] {
        while true {
            let lineData: Data? = stdoutBuffer.withLock { buffer in
                guard let newlineIndex = buffer.firstIndex(of: 0x0A) else { return nil }
                let line = Data(buffer[buffer.startIndex..<newlineIndex])
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                return line
            }
            guard let lineData else {
                try await Task.sleep(for: .milliseconds(20))
                continue
            }
            guard !lineData.isEmpty,
                let object = try? JSONSerialization.jsonObject(with: lineData, options: [.fragmentsAllowed]) as? [String: Any],
                predicate(object)
            else { continue }
            return object
        }
    }

    /// Terminates the child process and awaits its exit.
    func shutdown() async {
        stdout.fileHandleForReading.readabilityHandler = nil
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
            if process.isRunning {
                process.terminate()
            }
        }
    }
}
