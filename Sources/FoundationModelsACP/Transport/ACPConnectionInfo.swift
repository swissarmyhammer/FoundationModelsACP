/// The id of one ACP connection: the `Acp-Connection-Id` of the HTTP
/// transport.
public struct ACPConnectionId: Hashable, Sendable {
    /// The opaque id string as it crosses the wire.
    public let rawValue: String

    /// Creates an id that wraps the given wire string.
    ///
    /// - Parameter rawValue: The opaque id string.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// What a transport knows about the peer of one connection.
public struct ACPConnectionInfo: Hashable, Sendable {
    /// The id of the connection.
    public let id: ACPConnectionId

    /// The bearer token of the connection, or `nil` when it sent none.
    public let bearerToken: String?

    /// Creates the information of one connection.
    ///
    /// - Parameters:
    ///   - id: The id of the connection.
    ///   - bearerToken: The bearer token of the connection, or `nil`.
    public init(id: ACPConnectionId, bearerToken: String?) {
        self.id = id
        self.bearerToken = bearerToken
    }
}

extension ACPTransport {
    /// No connection information: the default for a transport with no
    /// connection header.
    public var connectionInfo: ACPConnectionInfo? { nil }
}
