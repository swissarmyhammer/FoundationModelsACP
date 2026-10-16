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

/// Thrown when a schema document does not have the expected shape.
struct UnexpectedSchemaShapeError: Error {}

/// Thrown when the stdout of the agent ends before a matching line comes.
struct AgentOutputEndedError: Error {}

/// A real `acp-test-agent` child process, driven over raw stdio pipes with no
/// dependency on this library's own transport types — proving the schema
/// conformance of the actual bytes a black-box ACP client would see.
///
/// `@unchecked Sendable`: `process`/`stdin`/`stdout` are `let`-bound and never
/// mutated after `init`, and the only mutable state (`stdoutBuffer`) is a
/// `Mutex`. The reads use no clock: each read ends with a matching line, or
/// with the end of the stdout of the agent.
final class LiveAgentProcess: @unchecked Sendable {
    /// The byte that ends each JSON-RPC line on the wire (`\n`).
    private static let lineTerminator: UInt8 = 0x0A

    private let process: Process
    private let stdin: Pipe
    private let stdout: Pipe
    /// The bytes read from stdout that no read used yet.
    private let stdoutBuffer = Mutex<Data>(Data())
    /// The stdout chunks of the agent. It ends at the end of stdout.
    private let stdoutChunks: AsyncStream<Data>

    /// The exit of the agent. The termination handler, set before launch,
    /// records it. Thus an exit before `shutdown()` is not lost.
    private let childExit = ProcessExit()

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
        // below only awaits the chunks it yields, so nothing here risks the
        // pool-exhaustion deadlock a blocking `.availableData` read from an
        // `async` body would (see `../Tests/FoundationModelsACPTests/TransportProcessSupport.swift`'s `terminateAndAwaitExit`, which
        // documents the same hazard for reaping child processes).
        let (chunks, continuation) = AsyncStream<Data>.makeStream()
        stdoutChunks = chunks
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                // The end of stdout: the agent exited.
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            continuation.yield(chunk)
        }

        // Set before launch, so the handler sees each exit, also an early one.
        let childExit = childExit
        process.terminationHandler = { _ in childExit.record() }

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
    /// - Throws: `AgentOutputEndedError` if stdout ends before a matching
    ///   response arrives.
    func request(
        id: Int,
        method: String,
        params: [String: Any]
    ) async throws -> (sent: [String: Any], received: [String: Any]) {
        let envelope: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        try send(envelope)
        let received = try await nextLine { object in
            (object["id"] as? Int) == id && (object["result"] != nil || object["error"] != nil)
        }
        return (envelope, received)
    }

    /// Waits for the next JSON-RPC notification with the given method from
    /// the agent.
    ///
    /// - Parameter method: The JSON-RPC method name to wait for.
    /// - Returns: The notification envelope received, as real wire bytes for
    ///   the caller to inspect or validate against the schema.
    /// - Throws: `AgentOutputEndedError` if stdout ends before a matching
    ///   notification arrives.
    func notification(method: String) async throws -> [String: Any] {
        try await nextLine { object in
            (object["method"] as? String) == method && object["id"] == nil
        }
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
        // The throwing write fails when the agent is gone. Thus the test
        // fails at the send, and does not wait for a reply that cannot come.
        try stdin.fileHandleForWriting.write(contentsOf: data + Data([Self.lineTerminator]))
    }

    /// Reads stdout until a line satisfying `predicate` decodes, buffering
    /// (and discarding) any lines that do not match — the caller is
    /// responsible for interleaving reads with the traffic it expects.
    ///
    /// - Parameter predicate: The condition that the line must satisfy.
    /// - Returns: The first matching line.
    /// - Throws: `AgentOutputEndedError` if stdout ends first.
    private func nextLine(where predicate: ([String: Any]) -> Bool) async throws -> [String: Any] {
        var chunks = stdoutChunks.makeAsyncIterator()
        while true {
            let lineData: Data? = stdoutBuffer.withLock { buffer in
                guard let newlineIndex = buffer.firstIndex(of: Self.lineTerminator) else { return nil }
                let line = Data(buffer[buffer.startIndex..<newlineIndex])
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                return line
            }
            guard let lineData else {
                guard let chunk = await chunks.next() else { throw AgentOutputEndedError() }
                stdoutBuffer.withLock { $0.append(chunk) }
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
    ///
    /// The wait ends also when the child exited before this call: the
    /// termination handler recorded that exit.
    func shutdown() async {
        let process = process
        await childExit.wait {
            if process.isRunning {
                process.terminate()
            }
        }
    }
}

/// The exit of a child process, as its termination handler records it.
///
/// A waiter that starts after the exit ends at once. It uses no clock.
private final class ProcessExit: Sendable {
    /// `true` after the exit, and the callers of `wait(stopping:)` that wait
    /// for it.
    private let state = Mutex<(exited: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    /// Records the exit, and resumes each waiter.
    func record() {
        let waiters = state.withLock { state in
            state.exited = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Waits until the exit. When the child still runs, it calls `stop`
    /// after the waiter is registered, so the exit cannot come between the
    /// check and the wait.
    ///
    /// - Parameter stop: Tells the child to exit.
    func wait(stopping stop: () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let exited = state.withLock { state -> Bool in
                if !state.exited {
                    state.waiters.append(continuation)
                }
                return state.exited
            }
            if exited {
                continuation.resume()
            } else {
                stop()
            }
        }
    }
}
