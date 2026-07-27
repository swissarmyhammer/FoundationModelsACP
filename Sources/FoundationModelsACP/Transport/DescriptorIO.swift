import Darwin
import Foundation

/// A failure raised by a low-level file-descriptor read or write.
enum DescriptorError: Error, Equatable {
    /// A `write(2)` failed with the carried `errno`.
    case writeFailed(errno: Int32)

    /// A `read(2)` failed with the carried `errno`.
    case readFailed(errno: Int32)
}

/// Writes every byte of `data` to `descriptor` as one indivisible frame.
///
/// A single `write(2)` may transfer fewer bytes than requested — an ACP frame
/// routinely exceeds `PIPE_BUF`, so one syscall is not guaranteed to drain the
/// whole buffer — and may be interrupted by a signal. Looping until the buffer
/// is fully written, under the caller's serialization, is what lets a frame
/// reach the wire without interleaving with another writer's bytes.
///
/// - Parameters:
///   - descriptor: The file descriptor to write to.
///   - data: The framed bytes to write in full.
/// - Throws: `DescriptorError.writeFailed` carrying `errno` when the write fails.
func fullWrite(_ descriptor: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < raw.count {
            let written = Darwin.write(descriptor, base + offset, raw.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                throw DescriptorError.writeFailed(errno: errno)
            }
            offset += written
        }
    }
}

/// Streams a file descriptor's bytes on a dedicated reader thread.
///
/// Blocking `read(2)` runs on its own `Thread` rather than a cooperative
/// executor thread, so a stalled descriptor never starves Swift concurrency.
/// The stream finishes at EOF and throws `DescriptorError.readFailed` on error.
enum ByteReader {
    /// The read buffer size, large enough to drain a typical pipe burst in one
    /// syscall.
    private static let bufferSize = 64 * 1024

    /// Starts reading `descriptor` and returns its byte stream.
    ///
    /// - Parameter descriptor: The file descriptor to read until EOF.
    /// - Returns: A stream of byte chunks in arrival order.
    static func stream(from descriptor: Int32) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            read(descriptor, into: continuation)
        }
    }

    /// Starts a reader thread that yields `descriptor`'s bytes to `continuation`.
    ///
    /// - Parameters:
    ///   - descriptor: The file descriptor to read until EOF.
    ///   - continuation: The stream continuation fed each chunk, then finished.
    static func read(
        _ descriptor: Int32,
        into continuation: AsyncThrowingStream<Data, any Error>.Continuation
    ) {
        let thread = Thread { readLoop(descriptor, into: continuation) }
        thread.name = "FoundationModelsACP.ByteReader"
        thread.start()
    }

    /// Reads `descriptor` in a loop, yielding each chunk until EOF or error.
    ///
    /// - Parameters:
    ///   - descriptor: The file descriptor to read.
    ///   - continuation: The stream continuation to feed and finish.
    private static func readLoop(
        _ descriptor: Int32,
        into continuation: AsyncThrowingStream<Data, any Error>.Continuation
    ) {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 1)
        defer { buffer.deallocate() }
        while true {
            let count = Darwin.read(descriptor, buffer, bufferSize)
            if count > 0 {
                continuation.yield(Data(bytes: buffer, count: count))
            } else if count == 0 {
                continuation.finish()
                return
            } else if errno != EINTR {
                continuation.finish(throwing: DescriptorError.readFailed(errno: errno))
                return
            }
        }
    }
}
