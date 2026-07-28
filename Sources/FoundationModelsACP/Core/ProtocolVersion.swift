/// The ACP protocol version — a bare integer on the wire, never a string.
///
/// The doc set and schema directory are *labelled* "v2", but the value
/// exchanged during `initialize` is the integer `2`. Decoding rejects string
/// forms like `"v2"` or `"2.0.0"` with a `DecodingError`. Wire coding comes
/// from ``WireRawValueCodable``.
public struct ProtocolVersion: WireRawValueCodable, Hashable, Sendable {
    /// The wire value, e.g. `2` for protocol v2.
    public let rawValue: UInt16

    /// Creates a version from its wire integer.
    ///
    /// - Parameter rawValue: The bare protocol version integer.
    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// Protocol version 2 — wire value `2`.
    public static let v2 = ProtocolVersion(rawValue: 2)

    /// The most recent protocol version this package implements.
    ///
    /// This package serves v2 only; there is no v1 constant because no v1
    /// surface is generated or spoken.
    public static let latest = v2
}

/// Thrown when a peer's `initialize` response names a protocol version other
/// than the one this side sent.
///
/// This package is v2-only by decision (`plan.md`, *Decision: v2 only*): there
/// is no v1 surface and no version-branching logic, so a peer that answers
/// with any version other than the one requested — lower, higher, or
/// otherwise unrecognized — is not a peer this side can serve. The spec's own
/// guidance is explicit about whose job that leaves it: *"The client should
/// disconnect, if it doesn't support this version."* Naming both versions
/// keeps that disconnect diagnosable instead of reading as a generic
/// handshake failure — the real-world friction point going v2-only creates.
public struct ProtocolVersionMismatchError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The protocol version this side sent in its `initialize` request.
    public let sent: ProtocolVersion

    /// The protocol version the peer answered with.
    public let received: ProtocolVersion

    /// Creates a version-mismatch error naming both sides of the handshake.
    ///
    /// - Parameters:
    ///   - sent: The version this side requested.
    ///   - received: The version the peer answered with.
    public init(sent: ProtocolVersion, received: ProtocolVersion) {
        self.sent = sent
        self.received = received
    }

    /// A diagnostic naming both versions explicitly, never a vague "handshake
    /// failed".
    public var description: String {
        "ACP protocol version mismatch: sent protocolVersion \(sent.rawValue), "
            + "peer answered protocolVersion \(received.rawValue). This side "
            + "implements ACP v2 only and cannot serve a peer speaking a "
            + "different protocol version."
    }
}
