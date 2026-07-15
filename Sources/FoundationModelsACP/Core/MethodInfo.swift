/// The participant that serves a method — the side that receives the call
/// and produces the response or handles the notification.
public enum MethodSide: String, Hashable, Sendable {
    /// Served by the agent (e.g. `session/prompt`).
    case agent

    /// Served by the client (e.g. `fs/read_text_file`).
    case client

    /// Protocol-level plumbing served by both participants (the `$/…`
    /// methods, e.g. `$/cancel_request`).
    case protocolLevel = "protocol"
}

/// Whether a method is a request expecting a response or a one-way
/// notification.
public enum MethodKind: String, Hashable, Sendable {
    /// A JSON-RPC request; the serving side replies with a result or error.
    case request

    /// A JSON-RPC notification; no reply is ever sent.
    case notification
}

/// One routing-table entry for a stable ACP method.
///
/// Entries are generated from the vendored routing manifest and schema —
/// never hand-wired — so the wire name, handler name, side, kind, and
/// parameter/result types always agree with the vendored protocol revision.
public struct MethodInfo: Hashable, Sendable {
    /// The method name as it crosses the wire (e.g. `session/new`).
    public let wireMethod: String

    /// The Swift handler name the method dispatches to (e.g. `newSession`).
    public let handlerName: String

    /// The participant that serves the method.
    public let side: MethodSide

    /// Whether the method is a request or a notification.
    public let kind: MethodKind

    /// The generated Swift type name of the method's parameters.
    public let paramsTypeName: String

    /// The generated Swift type name of the method's result; `nil` for
    /// notifications, which have no reply.
    public let resultTypeName: String?

    /// The upstream deprecation message, when the method is deprecated
    /// (e.g. `session/set_mode`); `nil` otherwise.
    public let deprecationMessage: String?

    /// Creates a routing-table entry.
    ///
    /// - Parameters:
    ///   - wireMethod: The wire method name.
    ///   - handlerName: The Swift handler name.
    ///   - side: The serving participant.
    ///   - kind: Request or notification.
    ///   - paramsTypeName: The parameters' Swift type name.
    ///   - resultTypeName: The result's Swift type name; `nil` for
    ///     notifications.
    ///   - deprecationMessage: The deprecation message, if deprecated.
    public init(
        wireMethod: String,
        handlerName: String,
        side: MethodSide,
        kind: MethodKind,
        paramsTypeName: String,
        resultTypeName: String?,
        deprecationMessage: String?
    ) {
        self.wireMethod = wireMethod
        self.handlerName = handlerName
        self.side = side
        self.kind = kind
        self.paramsTypeName = paramsTypeName
        self.resultTypeName = resultTypeName
        self.deprecationMessage = deprecationMessage
    }
}

/// One routing-table entry for a method the protocol has not stabilized.
///
/// The unstable routing manifest carries only names and sides — the vendored
/// stable schema defines no parameter or result types for these methods — so
/// unstable entries honestly omit kind and type information.
public struct UnstableMethodInfo: Hashable, Sendable {
    /// The method name as it crosses the wire (e.g. `session/fork`).
    public let wireMethod: String

    /// The Swift handler name derived from the manifest's routing key
    /// (e.g. `sessionFork`).
    public let handlerName: String

    /// The participant that serves the method.
    public let side: MethodSide

    /// Creates an unstable routing-table entry.
    ///
    /// - Parameters:
    ///   - wireMethod: The wire method name.
    ///   - handlerName: The Swift handler name.
    ///   - side: The serving participant.
    public init(wireMethod: String, handlerName: String, side: MethodSide) {
        self.wireMethod = wireMethod
        self.handlerName = handlerName
        self.side = side
    }
}
