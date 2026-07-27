/// The JSON-RPC error object, as a Swift `Error`.
///
/// ACP v2 defines the error object in the schema — code, message, and an
/// optional structured `data` — so the wire type is generated and this is an
/// alias for it rather than a second, hand-maintained copy. What the schema
/// cannot state is that it is throwable, and what the named constructors below
/// add is a message for each predefined code.
///
/// Thrown by a request call when the peer answers with an error, and thrown
/// *by* a request handler to send a specific error response; any other thrown
/// error is reported as `internalError`.
///
/// Structured details go in `data`. Never encode them into `message`: the
/// message is a short human-readable sentence, and a peer that has to parse it
/// is parsing prose.
public typealias RequestError = ACPError

extension ACPError: Error {}

extension RequestError {
    /// Invalid JSON was received (`-32700`).
    public static let parseError = RequestError(code: .parseError, message: "Parse error")

    /// The message is not a valid JSON-RPC request object (`-32600`).
    public static let invalidRequest = RequestError(code: .invalidRequest, message: "Invalid request")

    /// The requested method does not exist, or is gated behind a capability
    /// the peer did not negotiate (`-32601`).
    ///
    /// - Parameter method: The unrecognized method name, reported in `data`.
    /// - Returns: The typed method-not-found error.
    public static func methodNotFound(_ method: String) -> RequestError {
        RequestError(
            code: .methodNotFound,
            message: "Method not found",
            data: .object(["method": .string(method)])
        )
    }

    /// The request parameters are invalid for the method (`-32602`).
    public static let invalidParams = RequestError(code: .invalidParams, message: "Invalid params")

    /// The handler failed while processing the request (`-32603`).
    ///
    /// - Parameter detail: Optional human-readable failure detail, reported
    ///   in `data`.
    /// - Returns: The typed internal error.
    public static func internalError(detail: String? = nil) -> RequestError {
        RequestError(
            code: .internalError,
            message: "Internal error",
            data: detail.map { .object(["detail": .string($0)]) }
        )
    }

    /// The call was aborted, by a cancellation from the caller or by the
    /// responder shutting down or running out of resources (`-32800`).
    public static let requestCancelled = RequestError(code: .requestCancelled, message: "Request cancelled")

    /// The agent requires authentication before this call (`-32000`, ACP).
    public static let authenticationRequired = RequestError(
        code: .authenticationRequired,
        message: "Authentication required"
    )

    /// A referenced resource does not exist (`-32002`, ACP).
    ///
    /// - Parameter uri: The missing resource's URI, reported in `data`.
    /// - Returns: The typed resource-not-found error.
    public static func resourceNotFound(uri: String) -> RequestError {
        RequestError(
            code: .resourceNotFound,
            message: "Resource not found",
            data: .object(["uri": .string(uri)])
        )
    }
}

extension RequestError {
    /// Decodes a peer's wire error object into a typed error.
    ///
    /// Tolerant by design: a peer's error object is untrusted input, so a
    /// missing or mistyped `code` degrades to `internalError`'s code and a
    /// missing or mistyped `message` degrades to a generic placeholder,
    /// rather than this connection layer refusing to surface the error at
    /// all.
    ///
    /// - Parameter wire: The response envelope's `error` member.
    init(wire: JSONValue) {
        guard case .object(let fields) = wire else {
            self = .internalError(detail: "malformed error response")
            return
        }
        let code: ErrorCode
        if case .number(let value) = fields["code", default: .null] {
            code = ErrorCode(wireValue: Int(value))
        } else {
            code = .internalError
        }
        let message: String
        if case .string(let value) = fields["message", default: .null] {
            message = value
        } else {
            message = "Unknown error"
        }
        self = RequestError(code: code, message: message, data: fields["data"])
    }

    /// The JSON-RPC wire form of the error, for embedding as a response's
    /// `error` member. Absent `data` is omitted, never encoded as JSON null.
    var wireValue: JSONValue {
        var fields: [String: JSONValue] = [
            "code": .number(Double(code.wireValue)),
            "message": .string(message),
        ]
        fields["data"] = data
        return .object(fields)
    }
}
