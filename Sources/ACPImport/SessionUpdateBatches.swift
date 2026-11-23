import Foundation
import FoundationModelsACP

/// The parser of the records of one format, line by line. A parser keeps
/// the state of the read between the lines, and gives its updates in parts.
protocol SessionRecordParser: Sendable {
    /// The updates of the lines read since the last ``takeUpdates()``.
    var updates: [SessionUpdate] { get set }

    /// The number of updates of the read, also of the updates that
    /// ``takeUpdates()`` gave.
    var emittedCount: Int { get }

    /// The number of JSON records, and of the records of the format.
    var jsonRecords: Int { get }
    var recognized: Int { get }

    /// Reads one line of the file. A line that is not JSON is skipped and
    /// counted.
    mutating func read(line: Data.SubSequence)
}

extension SessionRecordParser {
    /// Gives the updates of the lines read since the last call, and forgets
    /// them.
    mutating func takeUpdates() -> [SessionUpdate] {
        defer { updates = [] }
        return updates
    }

    /// The error of a file that ends with no update, or `nil` when the file
    /// gave an update.
    var endOfFileError: ImportReadError? {
        guard emittedCount == 0 else {
            return nil
        }
        return recognized == 0 && jsonRecords > 0 ? .notThisFormat : .noReadableRecord
    }
}

/// Reads the complete lines of a file, one block at a time.
///
/// The reader keeps in memory only the block that it reads now and the
/// start of the line that continues in the next block. A line longer than a
/// block grows that start until its line break arrives. A last line with no
/// line break is not complete and is not given.
struct LineReader: Sendable {
    /// The bytes of the file.
    private let source: any SessionByteSource

    /// The number of bytes of the file when the read started.
    private let size: Int

    /// The number of bytes of each read.
    private let blockSize: Int

    /// The place of the next read.
    private var offset = 0

    /// The bytes of the line that continues in the next block.
    private var partialLine = Data()

    /// Makes a reader that starts at the start of the file.
    ///
    /// - Parameters:
    ///   - source: The bytes of the file.
    ///   - blockSize: The number of bytes of each read. It is more than 0.
    init(source: any SessionByteSource, blockSize: Int) {
        precondition(blockSize > 0, "a block has at least one byte")
        self.source = source
        self.size = source.size
        self.blockSize = blockSize
    }

    /// `true` when the reader read the last block.
    var isAtEnd: Bool { offset >= size }

    /// Gives the bytes after the last line break of the file, as one line,
    /// and forgets them, or `nil` when there are none. Call it only at the
    /// end of the file. A line with only white space, and a line end `\r`,
    /// are not kept, as ``ImportSupport/lines(of:)`` does.
    ///
    /// - Returns: The last line, or `nil`.
    mutating func takeLastLine() -> Data? {
        defer { partialLine = Data() }
        var line = partialLine
        if line.last == UInt8(ascii: "\r") { line.removeLast() }
        guard !line.allSatisfy({ $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }) else { return nil }
        return line
    }

    /// The number of bytes of the line that continues in the next block.
    var bufferedByteCount: Int { partialLine.count }

    /// Reads the next block.
    ///
    /// - Returns: The lines that end in the block, with no line end. Empty
    ///   lines are not given.
    mutating func nextLines() throws -> [Data.SubSequence] {
        let block = try source.read(offset: offset, length: min(blockSize, size - offset))
        guard !block.isEmpty else {
            // The file is shorter than at the start of the read.
            offset = size
            partialLine = Data()
            return []
        }
        offset += block.count
        let lineBreak = UInt8(ascii: "\n")
        guard let firstBreak = block.firstIndex(of: lineBreak), let lastBreak = block.lastIndex(of: lineBreak) else {
            partialLine.append(block)
            return []
        }
        partialLine.append(block[block.startIndex..<firstBreak])
        let firstLine = partialLine
        partialLine = Data(block[(lastBreak + 1)...])
        let middle = firstBreak < lastBreak ? ImportSupport.lines(of: block[(firstBreak + 1)..<lastBreak]) : []
        return ImportSupport.lines(of: firstLine) + middle
    }
}

/// The session updates of a full session file, in batches. (D212 of
/// Testudo.)
///
/// Each step of the iterator reads blocks of the file until a block gives
/// updates, and gives the updates of that block as one batch. Thus the
/// first batch arrives before the end of the file, and the memory holds at
/// most one block, one line and the updates of one block. The iterator
/// reads a block only when the consumer asks for the next batch.
///
/// The iterator stops with a `CancellationError` when its task is
/// cancelled. At the end of a file with no update, it throws
/// ``ImportReadError/notThisFormat`` or ``ImportReadError/noReadableRecord``.
public struct SessionUpdateBatches: AsyncSequence, Sendable {
    /// One batch: the updates of the lines of one block, in the order of the
    /// file.
    public typealias Element = [SessionUpdate]

    /// The default number of bytes of each read: 256 KB.
    public static let defaultBlockSize = 262_144

    /// The bytes of the file.
    private let source: any SessionByteSource

    /// The number of bytes of each read.
    private let blockSize: Int

    /// The parser of the format, before the first line.
    private let parser: any SessionRecordParser

    /// Makes the batches of a file.
    init(source: any SessionByteSource, blockSize: Int, parser: any SessionRecordParser) {
        self.source = source
        self.blockSize = blockSize
        self.parser = parser
    }

    /// Makes an iterator that starts at the start of the file.
    public func makeAsyncIterator() -> Iterator {
        Iterator(lines: LineReader(source: source, blockSize: blockSize), parser: parser)
    }

    /// The iterator of the batches.
    public struct Iterator: AsyncIteratorProtocol, Sendable {
        /// The reader of the lines.
        private var lines: LineReader

        /// The parser of the format.
        private var parser: any SessionRecordParser

        /// `true` after the iterator gave its end.
        private var isFinished = false

        init(lines: LineReader, parser: any SessionRecordParser) {
            self.lines = lines
            self.parser = parser
        }

        /// Reads blocks until one gives updates.
        ///
        /// - Returns: The next batch, or `nil` at the end of the file.
        /// - Throws: A `CancellationError` when the task is cancelled, an
        ///   ``ImportReadError`` at the end of a file with no update, or the
        ///   error of a read.
        public mutating func next() async throws -> [SessionUpdate]? {
            while !isFinished {
                try Task.checkCancellation()
                guard !lines.isAtEnd else {
                    isFinished = true
                    // A last line with no line break is a record when it is
                    // complete JSON, as in ``ImportSupport/lines(of:)``. A
                    // line that an agent writes now is not complete JSON,
                    // and the parser skips it.
                    if let last = lines.takeLastLine() {
                        parser.read(line: last[...])
                    }
                    let updates = parser.takeUpdates()
                    if !updates.isEmpty {
                        return updates
                    }
                    if let error = parser.endOfFileError {
                        throw error
                    }
                    return nil
                }
                for line in try lines.nextLines() {
                    parser.read(line: line)
                }
                let updates = parser.takeUpdates()
                if !updates.isEmpty {
                    return updates
                }
            }
            return nil
        }
    }
}
