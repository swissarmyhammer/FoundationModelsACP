import Foundation

/// Typed JSON-RPC 2.0 error (spec §3): the standard codes plus ACP's custom
/// ones, carrying structured `data` rather than smuggling JSON through the
/// message string.
///
/// Thrown by `Connection.request(method:params:timeout:)` when the peer
/// answers with an error, and thrown *by* request handlers to send a specific
/// error response (any other thrown error is reported as `-32603`).
public struct RequestError: Error, Codable, Hashable, Sendable {
    /// JSON-RPC error code: `-32700` parse, `-32600` invalid request,
    /// `-32601` method-not-found, `-32602` invalid params, `-32603` internal,
    /// plus ACP's `-32000` auth-required and `-32002` resource-not-found.
    public var code: Int

    /// Short, single-sentence description of the error.
    public var message: String

    /// Optional structured details about the error.
    public var data: JSONValue?

    /// Creates a `RequestError`.
    ///
    /// - Parameters:
    ///   - code: The JSON-RPC error code.
    ///   - message: Short description of the error.
    ///   - data: Optional structured details.
    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    /// Invalid JSON was received (`-32700`).
    public static let parseError = RequestError(code: -32700, message: "Parse error")

    /// The message is not a valid JSON-RPC request object (`-32600`).
    public static let invalidRequest = RequestError(code: -32600, message: "Invalid request")

    /// The requested method does not exist (`-32601`).
    ///
    /// - Parameter method: The unrecognized method name, reported in `data`.
    /// - Returns: The typed method-not-found error.
    public static func methodNotFound(_ method: String) -> RequestError {
        RequestError(
            code: -32601,
            message: "Method not found",
            data: .object(["method": .string(method)])
        )
    }

    /// The request parameters are invalid for the method (`-32602`).
    public static let invalidParams = RequestError(code: -32602, message: "Invalid params")

    /// The handler failed while processing the request (`-32603`).
    ///
    /// - Parameter detail: Optional human-readable failure detail, reported in `data`.
    /// - Returns: The typed internal error.
    public static func internalError(detail: String? = nil) -> RequestError {
        RequestError(
            code: -32603,
            message: "Internal error",
            data: detail.map { .object(["detail": .string($0)]) }
        )
    }

    /// The agent requires authentication before this call (`-32000`, ACP).
    public static let authRequired = RequestError(code: -32000, message: "Authentication required")

    /// A referenced resource does not exist (`-32002`, ACP).
    ///
    /// - Parameter uri: The missing resource's URI, reported in `data`.
    /// - Returns: The typed resource-not-found error.
    public static func resourceNotFound(uri: String) -> RequestError {
        RequestError(
            code: -32002,
            message: "Resource not found",
            data: .object(["uri": .string(uri)])
        )
    }
}

extension RequestError {
    /// Builds the typed error from a decoded JSON-RPC `error` member,
    /// degrading missing or mistyped fields to internal-error defaults
    /// instead of failing the whole response.
    ///
    /// - Parameter wire: The decoded `error` value from a response envelope.
    init(wire: JSONValue) {
        guard case .object(let fields) = wire else {
            self = .internalError(detail: "malformed error object")
            return
        }
        if case .number(let code) = fields["code", default: .null] {
            self.code = Int(code)
        } else {
            self.code = -32603
        }
        if case .string(let message) = fields["message", default: .null] {
            self.message = message
        } else {
            self.message = "Unknown error"
        }
        self.data = fields["data"]
    }

    /// The JSON-RPC wire form of the error, for embedding as a response's
    /// `error` member. Absent `data` is omitted, never encoded as JSON null.
    var wireValue: JSONValue {
        var fields: [String: JSONValue] = [
            "code": .number(Double(code)),
            "message": .string(message),
        ]
        fields["data"] = data
        return .object(fields)
    }
}

/// Failures raised locally by `Connection`, never received from the peer.
public enum ConnectionError: Error, Hashable, Sendable {
    /// The transport reached EOF or failed, or the connection was closed;
    /// every pending request is rejected with this error (spec §5:
    /// fail loud on disconnect, never hang callers).
    case closed

    /// The per-request timeout elapsed before the peer answered.
    case timedOut
}
