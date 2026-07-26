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
