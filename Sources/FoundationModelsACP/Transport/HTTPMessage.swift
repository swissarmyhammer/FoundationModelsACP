import Foundation

// The minimal HTTP/1.1 that the ACP HTTP transport speaks: whole requests
// with a `Content-Length` body, whole responses, and one chunked response
// that streams the agent-to-client messages.

/// The status codes that the ACP HTTP transport answers with.
enum HTTPStatus: Int, Sendable {
    /// The agent-to-client stream opened.
    case ok = 200

    /// The message reached the connection.
    case accepted = 202

    /// The connection closed.
    case noContent = 204

    /// The request did not parse, or it named no connection.
    case badRequest = 400

    /// The credential is not the credential of the connection.
    case forbidden = 403

    /// The connection id names no open connection.
    case notFound = 404

    /// The HTTP method has no meaning for a connection.
    case methodNotAllowed = 405

    /// The agent-to-client stream of the connection is already open.
    case conflict = 409

    /// The body is larger than the transport accepts.
    case contentTooLarge = 413

    /// The header section is larger than the transport accepts.
    case headerFieldsTooLarge = 431

    /// The request uses a transfer coding that the transport does not read.
    case notImplemented = 501

    /// The server stopped, so it opens no connection.
    case serviceUnavailable = 503

    /// The reason phrase of the status line.
    var reasonPhrase: String {
        switch self {
        case .ok: "OK"
        case .accepted: "Accepted"
        case .noContent: "No Content"
        case .badRequest: "Bad Request"
        case .forbidden: "Forbidden"
        case .notFound: "Not Found"
        case .methodNotAllowed: "Method Not Allowed"
        case .conflict: "Conflict"
        case .contentTooLarge: "Content Too Large"
        case .headerFieldsTooLarge: "Request Header Fields Too Large"
        case .notImplemented: "Not Implemented"
        case .serviceUnavailable: "Service Unavailable"
        }
    }
}

/// The header names that the transport reads, in the lower case that
/// ``HTTPRequest`` keeps.
enum HTTPHeaderName {
    /// The credential of the client.
    static let authorization = "authorization"

    /// The length of the body.
    static let contentLength = "content-length"

    /// A transfer coding of the body, which the transport does not read.
    static let transferEncoding = "transfer-encoding"
}

/// The bytes that end one line of an HTTP message.
private let lineEnd = "\r\n"

/// A request that does not parse.
enum HTTPParseError: Error, Equatable {
    /// The request line or a header line is not HTTP/1.1.
    case malformed

    /// The header section is larger than
    /// ``HTTPRequestParser/maximumHeaderBytes``.
    case headerTooLarge

    /// The body is larger than ``HTTPRequestParser/maximumBodyBytes``.
    case bodyTooLarge

    /// The request has a `Transfer-Encoding`; the transport reads only a
    /// `Content-Length` body.
    case unsupportedTransferEncoding

    /// The response that refuses a request with this error.
    var response: HTTPResponse {
        switch self {
        case .malformed: .refusal(.badRequest, "the request is not HTTP/1.1")
        case .headerTooLarge: .refusal(.headerFieldsTooLarge, "the header section is too large")
        case .bodyTooLarge: .refusal(.contentTooLarge, "the body is too large")
        case .unsupportedTransferEncoding: .refusal(.notImplemented, "send the body with a Content-Length")
        }
    }
}

/// One HTTP request of a client.
struct HTTPRequest: Sendable {
    /// The method, for example `POST`.
    let method: String

    /// The request target, for example `/acp`.
    let target: String

    /// The header fields, keyed by the lower-case field name.
    let headers: [String: String]

    /// The body.
    let body: Data

    /// Creates a request.
    ///
    /// - Parameters:
    ///   - method: The method.
    ///   - target: The request target.
    ///   - headers: The header fields; the names match in any case.
    ///   - body: The body.
    init(method: String, target: String, headers: [String: String], body: Data) {
        self.method = method
        self.target = target
        self.headers = Dictionary(
            headers.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        self.body = body
    }

    /// The value of one header field.
    ///
    /// - Parameter name: The field name, in any case.
    /// - Returns: The value, or `nil` when the request has no such field.
    func header(named name: String) -> String? {
        headers[name.lowercased()]
    }

    /// The credential of an `Authorization: Bearer <token>` header, or `nil`
    /// when the request has no bearer credential. The scheme matches in any
    /// case.
    var bearerToken: String? {
        let bearerScheme = "bearer"
        guard let value = header(named: HTTPHeaderName.authorization) else { return nil }
        let parts = value.split(separator: " ", maxSplits: 1)
        guard let scheme = parts.first, scheme.lowercased() == bearerScheme, let credential = parts.dropFirst().first
        else { return nil }
        let token = credential.trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }
}

/// Splits a byte stream of a client into whole HTTP requests.
///
/// Chunk boundaries may fall anywhere: bytes of an unfinished request stay
/// until a later chunk completes it.
struct HTTPRequestParser {
    /// The largest header section that the parser accepts.
    static let maximumHeaderBytes = 64 * 1024

    /// The largest body that the parser accepts.
    static let maximumBodyBytes = 16 * 1024 * 1024

    /// The bytes that end the header section.
    private static let headerEnd = Data((lineEnd + lineEnd).utf8)

    /// Bytes of requests that are not complete yet.
    private var buffer = Data()

    /// Appends a chunk and returns the requests that it completed.
    ///
    /// - Parameter chunk: The next bytes of the client.
    /// - Returns: The complete requests, in arrival order.
    /// - Throws: `HTTPParseError` when a request does not parse. The parser
    ///   is then of no further use, because the stream lost its framing.
    mutating func append(_ chunk: Data) throws(HTTPParseError) -> [HTTPRequest] {
        buffer.append(chunk)
        var requests: [HTTPRequest] = []
        while let request = try nextRequest() {
            requests.append(request)
        }
        return requests
    }

    /// Takes the first complete request out of the buffer.
    ///
    /// - Returns: The request, or `nil` when the buffer holds no complete
    ///   request.
    /// - Throws: `HTTPParseError` when the request does not parse.
    private mutating func nextRequest() throws(HTTPParseError) -> HTTPRequest? {
        guard let headerEnd = buffer.firstRange(of: Self.headerEnd) else {
            guard buffer.count <= Self.maximumHeaderBytes else { throw .headerTooLarge }
            return nil
        }
        guard buffer.distance(from: buffer.startIndex, to: headerEnd.lowerBound) <= Self.maximumHeaderBytes else {
            throw .headerTooLarge
        }
        let head = try HTTPRequestHead(parsing: buffer[buffer.startIndex..<headerEnd.lowerBound])
        guard buffer.distance(from: headerEnd.upperBound, to: buffer.endIndex) >= head.contentLength else {
            return nil
        }
        let bodyEnd = buffer.index(headerEnd.upperBound, offsetBy: head.contentLength)
        let body = Data(buffer[headerEnd.upperBound..<bodyEnd])
        buffer = Data(buffer[bodyEnd...])
        return HTTPRequest(method: head.method, target: head.target, headers: head.headers, body: body)
    }
}

/// The request line and the header fields of one request.
private struct HTTPRequestHead {
    /// The number of parts of a request line: method, target and version.
    private static let requestLineParts = 3

    /// The prefix of each HTTP/1 version.
    private static let versionPrefix = "HTTP/1."

    /// The method.
    let method: String

    /// The request target.
    let target: String

    /// The header fields, keyed by the lower-case field name. A field that
    /// repeats keeps each value, separated by a comma.
    let headers: [String: String]

    /// The length of the body.
    let contentLength: Int

    /// Parses a header section.
    ///
    /// - Parameter bytes: The header section, without its empty last line.
    /// - Throws: `HTTPParseError` when the section is not an HTTP/1.1
    ///   request that the transport reads.
    init(parsing bytes: Data) throws(HTTPParseError) {
        guard let text = String(data: bytes, encoding: .utf8) else { throw .malformed }
        var lines = text.components(separatedBy: lineEnd)[...]
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == Self.requestLineParts, let version = requestLine.last,
            version.hasPrefix(Self.versionPrefix)
        else {
            throw .malformed
        }
        method = String(requestLine[0])
        target = String(requestLine[1])
        headers = try Self.fields(of: lines)
        contentLength = try Self.contentLength(of: headers)
    }

    /// Parses the header lines.
    ///
    /// - Parameter lines: The lines after the request line.
    /// - Returns: The fields, keyed by the lower-case field name.
    /// - Throws: `HTTPParseError.malformed` when a line is not a field.
    private static func fields(of lines: ArraySlice<String>) throws(HTTPParseError) -> [String: String] {
        var fields: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { throw .malformed }
            let name = line[..<colon]
            guard !name.isEmpty, !name.contains(where: \.isWhitespace) else { throw .malformed }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[name.lowercased()] = fields[name.lowercased()].map { "\($0), \(value)" } ?? value
        }
        return fields
    }

    /// Reads the length of the body.
    ///
    /// - Parameter headers: The fields of the request.
    /// - Returns: The `Content-Length`, or 0 when the request has none.
    /// - Throws: `HTTPParseError` when the request has a transfer coding, or
    ///   a length that is not a count of bytes the transport accepts.
    private static func contentLength(of headers: [String: String]) throws(HTTPParseError) -> Int {
        guard headers[HTTPHeaderName.transferEncoding] == nil else { throw .unsupportedTransferEncoding }
        guard let raw = headers[HTTPHeaderName.contentLength] else { return 0 }
        guard let length = Int(raw), length >= 0 else { throw .malformed }
        guard length <= HTTPRequestParser.maximumBodyBytes else { throw .bodyTooLarge }
        return length
    }
}

/// One whole HTTP response of the server.
struct HTTPResponse: Sendable {
    /// The status.
    let status: HTTPStatus

    /// The header fields. The response adds `Content-Length` itself.
    let headers: [String: String]

    /// The body.
    let body: Data

    /// Creates a response.
    ///
    /// - Parameters:
    ///   - status: The status.
    ///   - headers: The header fields, with no `Content-Length`.
    ///   - body: The body.
    init(status: HTTPStatus, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// A response that refuses a request, with the reason as a text body.
    ///
    /// - Parameters:
    ///   - status: The status that names the refusal.
    ///   - reason: Why the transport refused the request.
    /// - Returns: The response.
    static func refusal(_ status: HTTPStatus, _ reason: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(reason.utf8))
    }

    /// The bytes of the response on the wire.
    ///
    /// - Returns: The status line, the header fields in name order, and the
    ///   body.
    func serialized() -> Data {
        var fields = headers
        fields["Content-Length"] = String(body.count)
        return Self.head(status: status, fields: fields) + body
    }

    /// The head of the chunked response that streams the agent-to-client
    /// messages, one chunk for each message.
    static let streamHead = head(
        status: .ok,
        fields: [
            "Cache-Control": "no-store",
            "Content-Type": "application/x-ndjson",
            "Transfer-Encoding": "chunked",
        ]
    )

    /// The chunk that ends a chunked response.
    static let lastChunk = Data("0\(lineEnd)\(lineEnd)".utf8)

    /// Frames one chunk of a chunked response.
    ///
    /// - Parameter data: The bytes of the chunk; not empty.
    /// - Returns: The hexadecimal length, the bytes and the line ends.
    static func chunk(_ data: Data) -> Data {
        let hexadecimal = 16
        return Data((String(data.count, radix: hexadecimal) + lineEnd).utf8) + data + Data(lineEnd.utf8)
    }

    /// Writes a status line and header fields.
    ///
    /// - Parameters:
    ///   - status: The status.
    ///   - fields: The header fields.
    /// - Returns: The head, with the empty line that ends it.
    private static func head(status: HTTPStatus, fields: [String: String]) -> Data {
        var text = "HTTP/1.1 \(status.rawValue) \(status.reasonPhrase)\(lineEnd)"
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            text += "\(name): \(value)\(lineEnd)"
        }
        return Data((text + lineEnd).utf8)
    }
}
