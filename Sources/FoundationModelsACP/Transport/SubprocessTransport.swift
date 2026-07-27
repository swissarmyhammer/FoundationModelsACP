import Foundation
import Synchronization

/// A client-side transport that spawns and drives an external ACP agent.
///
/// Launches a child process, wires its standard streams to the ACP wire — the
/// child's stdout becomes this transport's `bytes`, and `write(_:)` feeds the
/// child's stdin — and forwards the child's stderr to this process's stderr so
/// the child's diagnostics never pollute the wire.
///
/// The child is signaled to exit exactly once: on `close()`, on `deinit`, and
/// when the byte stream is torn down (connection close or task cancellation,
/// which stops the read loop consuming `bytes`). No zombie outlives the
/// connection, and a still-running child is terminated when its driver goes
/// away.
///
/// The exit itself is observed asynchronously through `terminationHandler`,
/// installed once at spawn time, rather than through a blocking
/// `waitUntilExit()` call: that call ties up its calling thread until the
/// child exits, and on the Swift Concurrency cooperative pool enough of those
/// in flight at once — several connections tearing down together — can
/// exhaust every worker thread and deadlock the process, since nothing is
/// left to run the notification that would free any of them.
/// `terminationHandler` delivers the same exit off that pool, so `close()`
/// and `deinit` (which cannot `await`) never block on it.
///
/// Marked `@unchecked Sendable` because it stores a `Process` and its pipes,
/// which are not `Sendable`: every mutation is serialized — writes through the
/// `input` lock, the recorded exit through the `exitStatus` lock, and the
/// one-shot reap through the `reaped` lock — and `bytes` is an immutable
/// `Sendable` stream.
public final class SubprocessTransport: ACPTransport, @unchecked Sendable {
    /// Incoming byte chunks read from the child's standard output.
    public let bytes: AsyncThrowingStream<Data, any Error>

    /// The spawned child process.
    private let process: Process

    /// The pipe feeding the child's standard input.
    private let inputPipe: Pipe

    /// Serializes writes to the child's stdin; the guarded value is the write
    /// descriptor.
    private let input: Mutex<Int32>

    /// The child's exit status once `terminationHandler` observes it — `nil`
    /// while still running. `isRunning` and `terminationStatus` read this
    /// instead of querying `process` so they never depend on a blocking wait.
    private let exitStatus = Mutex<Int32?>(nil)

    /// Guards one-shot reaping so `close()`, `deinit`, and stream teardown race
    /// safely; `true` once the child has been signaled to exit.
    private let reaped = Mutex<Bool>(false)

    /// Spawns the agent process and starts driving it.
    ///
    /// - Parameters:
    ///   - executableURL: The agent executable to launch.
    ///   - arguments: The command-line arguments passed to the agent.
    ///   - environment: The child's environment; `nil` inherits this process's.
    ///   - currentDirectoryURL: The child's working directory; `nil` inherits
    ///     this process's.
    /// - Throws: An error from `Process.run()` when the child cannot be spawned.
    public init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil
    ) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectoryURL { process.currentDirectoryURL = currentDirectoryURL }

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()

        self.process = process
        self.inputPipe = inputPipe
        self.input = Mutex(inputPipe.fileHandleForWriting.fileDescriptor)
        self.bytes = stream

        try process.run()

        // Observes the child's exit off the Swift Concurrency cooperative
        // pool (see the class doc) instead of a blocking `waitUntilExit()`,
        // and closes stdin once it happens so a write racing the exit fails
        // cleanly rather than into a half-torn-down pipe.
        process.terminationHandler = { [weak self] finished in
            self?.exitStatus.withLock { $0 = finished.terminationStatus }
            try? inputPipe.fileHandleForWriting.close()
        }

        Self.forwardStderr(from: errorPipe.fileHandleForReading)
        // Reap when the consumer tears the stream down (connection close or
        // cancellation), so a stalled child never lingers past its driver.
        continuation.onTermination = { [weak self] _ in self?.reap() }
        ByteReader.read(outputPipe.fileHandleForReading.fileDescriptor, into: continuation)
    }

    deinit {
        reap()
    }

    /// Whether the child process is still running.
    public var isRunning: Bool {
        exitStatus.withLock { $0 == nil }
    }

    /// The child's exit status once it has terminated, or `nil` while running.
    public var terminationStatus: Int32? {
        exitStatus.withLock { $0 }
    }

    /// Writes one whole frame to the child's stdin as an indivisible unit.
    ///
    /// - Parameter data: The framed bytes to send.
    /// - Throws: `DescriptorError.writeFailed` when the child's stdin rejects
    ///   the bytes (for example after the child has exited).
    public func write(_ data: Data) async throws {
        try input.withLock { descriptor in
            try fullWrite(descriptor, data)
        }
    }

    /// Terminates the child if it is still running. Idempotent; does not
    /// block waiting for the exit — see the class doc for why.
    public func close() {
        reap()
    }

    /// Signals the child to exit if still running. Runs its body exactly once
    /// across all callers (`close()`, `deinit`, and stream teardown); never
    /// blocks, so `deinit` — which cannot `await` — can call it directly.
    /// `terminationHandler`, installed at spawn, records the exit and closes
    /// stdin once it actually happens.
    private func reap() {
        let alreadyReaped = reaped.withLock { flag -> Bool in
            defer { flag = true }
            return flag
        }
        guard !alreadyReaped else { return }
        if process.isRunning {
            process.terminate()
        }
    }

    /// Forwards the child's stderr to this process's stderr, byte for byte, so
    /// the child's diagnostics stay off the ACP wire.
    ///
    /// - Parameter handle: The read end of the child's stderr pipe.
    private static func forwardStderr(from handle: FileHandle) {
        handle.readabilityHandler = { source in
            let chunk = source.availableData
            if chunk.isEmpty {
                source.readabilityHandler = nil
            } else {
                FileHandle.standardError.write(chunk)
            }
        }
    }
}
