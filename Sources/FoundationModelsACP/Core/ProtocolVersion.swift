/// The ACP protocol version — a bare integer on the wire, never a string.
///
/// The doc set and schema directory are *labelled* "v1", but the value
/// exchanged during `initialize` is the integer `1`. Decoding rejects string
/// forms like `"v1"` or `"1.0.0"` with a `DecodingError` (spec §3).
public struct ProtocolVersion: RawRepresentable, Codable, Hashable, Sendable {
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

    /// Decodes the version from a bare JSON integer.
    ///
    /// - Parameter decoder: The decoder positioned at the version value.
    /// - Throws: `DecodingError.typeMismatch` when the value is not an
    ///   integer (e.g. the strings `"v1"` or `"1.0.0"`).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(UInt16.self))
    }

    /// Encodes the version as a bare JSON integer.
    ///
    /// - Parameter encoder: The encoder to write the version into.
    /// - Throws: Rethrows any error from the underlying encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
