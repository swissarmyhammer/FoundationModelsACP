import Foundation
import Synchronization

/// A client-side transport that spawns and drives an external ACP agent.
///
/// Launches a child process (for example `gemini --experimental-acp`), wires
/// its standard streams to the ACP wire — the child's stdout becomes this
/// transport's `bytes`, and `write(_:)` feeds the child's stdin — and forwards
/// the child's stderr to this process's stderr so the child's diagnostics never
/// pollute the wire.
///
/// The child is reaped exactly once: on `close()`, on `deinit`, and when the
/// byte stream is torn down (connection close or task cancellation, which stops
/// the read loop consuming `bytes`). No zombie outlives the connection, and a
/// still-running child is terminated when its driver goes away.
///
/// Marked `@unchecked Sendable` because it stores a `Process` and its pipes,
/// which are not `Sendable`: every mutation is serialized — writes through the
/// `input` lock and the one-shot reap through the `reaped` lock — and `bytes`
/// is an immutable `Sendable` stream.
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

    /// Guards one-shot reaping so `close()`, `deinit`, and stream teardown race
    /// safely; `true` once the child has been reaped.
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
        process.isRunning
    }

    /// The child's exit status once it has terminated, or `nil` while running.
    public var terminationStatus: Int32? {
        process.isRunning ? nil : process.terminationStatus
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

    /// Terminates and reaps the child, closing its stdin. Idempotent.
    public func close() {
        reap()
    }

    /// Terminates the child if still running, waits for it to exit so the OS
    /// collects it, and closes its stdin. Runs its body exactly once across all
    /// callers.
    private func reap() {
        let alreadyReaped = reaped.withLock { flag -> Bool in
            defer { flag = true }
            return flag
        }
        guard !alreadyReaped else { return }
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        try? inputPipe.fileHandleForWriting.close()
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
