/// The ACP protocol version — a bare integer on the wire, never a string.
///
/// The doc set and schema directory are *labelled* "v1", but the value
/// exchanged during `initialize` is the integer `1`. Decoding rejects string
/// forms like `"v1"` or `"1.0.0"` with a `DecodingError` (spec §3).
/// Wire coding comes from ``WireRawValueCodable``.
public struct ProtocolVersion: WireRawValueCodable, Hashable, Sendable {
    /// The wire value, e.g. `1` for protocol v1.
    public let rawValue: UInt16

    /// Creates a version from its wire integer.
    ///
    /// - Parameter rawValue: The bare protocol version integer.
    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// Protocol version 1 — wire value `1`.
    public static let v1 = ProtocolVersion(rawValue: 1)

    /// The most recent protocol version this package implements.
    public static let latest = v1
}
