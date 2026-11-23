import Foundation

/// A source of the bytes of a session file. (D212 of Testudo.)
///
/// The readers read a file only through this protocol. The bounded
/// metadata reader reads some windows of the file, and the streaming reader
/// reads one block at a time. Thus no reader keeps a full file in memory.
public protocol SessionByteSource: Sendable {
    /// The number of bytes of the file.
    var size: Int { get }

    /// Reads the bytes of a range of the file.
    ///
    /// - Parameters:
    ///   - offset: The place of the first byte, from 0.
    ///   - length: The number of bytes to read.
    /// - Returns: The bytes. There are fewer than `length` bytes only at
    ///   the end of the file.
    /// - Throws: An error when the read fails.
    func read(offset: Int, length: Int) throws -> Data
}

/// A file that the readers read with `pread`. It does not map the file and
/// it does not read the full file.
public struct FileByteSource: SessionByteSource {
    /// The handle of the open file. The handle closes the file when the last
    /// copy of the source goes.
    private let handle: FileHandle

    /// The number of bytes of the file when the source opened it.
    public let size: Int

    /// Opens a file for reads.
    ///
    /// - Parameter url: The URL of the file.
    /// - Throws: An error when the file does not open.
    public init(forReadingFrom url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        self.handle = handle
        self.size = Int(clamping: try handle.seekToEnd())
    }

    /// Reads the bytes of a range of the file with `pread`.
    ///
    /// - Parameters:
    ///   - offset: The place of the first byte, from 0.
    ///   - length: The number of bytes to read.
    /// - Returns: The bytes. There are fewer than `length` bytes only at
    ///   the end of the file.
    /// - Throws: A `POSIXError` when `pread` fails.
    public func read(offset: Int, length: Int) throws -> Data {
        precondition(offset >= 0 && length >= 0, "a read needs an offset and a length that are not negative")
        var data = Data(count: length)
        let descriptor = handle.fileDescriptor
        let count = try data.withUnsafeMutableBytes { buffer in
            try Self.read(descriptor, into: buffer, at: offset)
        }
        data.count = count
        return data
    }

    /// Fills a buffer with `pread` calls, until the buffer is full or the
    /// file ends.
    ///
    /// - Returns: The number of bytes read.
    private static func read(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer, at offset: Int) throws -> Int {
        guard let base = buffer.baseAddress else {
            return 0
        }
        var total = 0
        while total < buffer.count {
            let result = pread(descriptor, base + total, buffer.count - total, off_t(offset + total))
            if result == 0 {
                break
            }
            if result < 0 {
                let code = errno
                guard code == EINTR else {
                    throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
                }
                continue
            }
            total += result
        }
        return total
    }
}
