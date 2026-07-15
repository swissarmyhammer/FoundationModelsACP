import Foundation

/// Diagnostic sink for the transport layer (spec §5).
///
/// stdout is sacred: the wire owns it, so diagnostics must never be printed
/// there. Implementations route messages to stderr, a file, or a test capture.
public struct ACPLogger: Sendable {
    private let emit: @Sendable (String) -> Void

    /// Creates a logger that forwards each message to `emit`.
    ///
    /// - Parameter emit: Closure invoked once per diagnostic message.
    public init(_ emit: @escaping @Sendable (String) -> Void) {
        self.emit = emit
    }

    /// Emits one diagnostic message.
    ///
    /// - Parameter message: The diagnostic text.
    public func log(_ message: String) {
        emit(message)
    }

    /// Discards all messages.
    public static let disabled = ACPLogger { _ in }

    /// Writes each message as a line to standard error — never stdout.
    public static let standardError = ACPLogger { message in
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// Minimal bidirectional byte transport the ACP wire runs over (spec §5).
///
/// Stdio, in-memory, and replay transports all satisfy this: an async
/// sequence of incoming byte chunks plus a write function for outgoing
/// bytes. Framing is layered on top by `NDJSONCodec`; transports move
/// opaque bytes only.
public protocol ACPTransport: Sendable {
    /// Incoming byte chunks from the peer, in arrival order. The stream
    /// finishes at EOF and throws on transport failure. Chunk boundaries
    /// are arbitrary — they need not align with lines or UTF-8 codepoints.
    var bytes: AsyncThrowingStream<Data, any Error> { get }

    /// Writes one outgoing chunk to the peer.
    ///
    /// - Parameter data: The bytes to send, already framed by the caller.
    /// - Throws: A transport-specific error if the peer is gone.
    func write(_ data: Data) async throws
}

/// Incremental newline splitter for the read side of the wire.
///
/// Operates on raw bytes so chunk boundaries may fall anywhere — including
/// mid-line or mid-UTF-8-codepoint — without corrupting reassembly; bytes
/// after the last `\n` are retained until a later chunk completes the line.
public struct NDJSONFramer: Sendable {
    /// Bytes after the last seen newline, awaiting completion.
    private var buffer = Data()

    /// Creates an empty framer.
    public init() {}

    /// Appends a chunk and returns the complete lines it terminated.
    ///
    /// - Parameter chunk: The next incoming bytes.
    /// - Returns: Payloads of each newline-terminated line, without the newline.
    public mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            lines.append(Data(buffer[start..<newline]))
            start = buffer.index(after: newline)
        }
        buffer = Data(buffer[start...])
        return lines
    }

    /// Returns the retained unterminated tail, if any, and resets the framer.
    ///
    /// - Returns: The trailing partial line, or `nil` if none was buffered.
    public mutating func finish() -> Data? {
        defer { buffer = Data() }
        return buffer.isEmpty ? nil : buffer
    }
}

/// Newline-delimited JSON codec for the ACP wire (spec §5).
public enum NDJSONCodec {
    /// Decodes one framed line into a JSON value.
    ///
    /// - Parameters:
    ///   - line: The line payload, without its trailing newline.
    ///   - logger: Receives a diagnostic when the line is skipped as unparseable.
    /// - Returns: The decoded value, or `nil` when the line was skipped.
    public static func decode(line: Data, logger: ACPLogger) -> JSONValue? {
        // Tolerate CRLF peers: the framer split on \n, leaving a trailing \r.
        var payload = line
        while payload.last == 0x0D {
            payload = payload.dropLast()
        }
        // Blank lines carry no message; skip them without noise.
        guard payload.contains(where: { $0 != 0x20 && $0 != 0x09 }) else {
            return nil
        }
        do {
            // JSONDecoder handles JSON string escapes natively, including the
            // escaped slash some peers emit in method names (`session\/update`).
            return try JSONDecoder().decode(JSONValue.self, from: payload)
        } catch {
            let preview = String(decoding: payload.prefix(256), as: UTF8.self)
            logger.log("NDJSONCodec: skipping unparseable line \(preview.debugDescription): \(error)")
            return nil
        }
    }

    /// Encodes one message as a single newline-terminated line.
    ///
    /// - Parameter message: The message to serialize.
    /// - Returns: UTF-8 JSON followed by exactly one `\n`.
    /// - Throws: Rethrows encoding errors from `JSONEncoder`.
    public static func encode(_ message: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        // Compact output (never .prettyPrinted) is the newline guarantee:
        // JSON escapes all control characters inside strings, so the only
        // 0x0A in the result is the terminator appended here. Sorted keys
        // keep output deterministic; unescaped slashes keep it readable.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(message)
        data.append(0x0A)
        return data
    }

    /// Decodes a byte stream into a stream of framed JSON messages.
    ///
    /// - Parameters:
    ///   - bytes: Incoming byte chunks, e.g. an `ACPTransport`'s `bytes`.
    ///   - logger: Receives a diagnostic for each skipped line.
    /// - Returns: The decoded messages, finishing when `bytes` finishes.
    public static func messages(
        from bytes: AsyncThrowingStream<Data, any Error>,
        logger: ACPLogger
    ) -> AsyncThrowingStream<JSONValue, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var framer = NDJSONFramer()
                do {
                    for try await chunk in bytes {
                        for line in framer.append(chunk) {
                            if let value = decode(line: line, logger: logger) {
                                continuation.yield(value)
                            }
                        }
                    }
                    // Tolerate a peer that omits the final newline: the
                    // retained tail at EOF is parsed (or logged-and-skipped)
                    // like any other line.
                    if let tail = framer.finish(),
                        let value = decode(line: tail, logger: logger)
                    {
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
