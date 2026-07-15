/// A 1-based line number — the ACP wire invariant (spec §4).
///
/// ACP line numbers start at 1; `0` and negative values are rejected at
/// construction and at decode so an off-by-one (0-based) producer surfaces as
/// a decode-time error instead of a silent interop bug.
public struct LineNumber: RawRepresentable, Codable, Hashable, Sendable {
    /// The 1-based line number, always >= 1.
    public let rawValue: Int

    /// Creates a line number, rejecting non-positive input.
    ///
    /// - Parameter rawValue: The candidate line number.
    /// - Returns: `nil` unless `rawValue` is at least 1.
    public init?(rawValue: Int) {
        guard rawValue >= 1 else { return nil }
        self.rawValue = rawValue
    }

    /// Decodes the line number from a bare JSON integer, enforcing 1-basing.
    ///
    /// - Parameter decoder: The decoder positioned at the line number value.
    /// - Throws: `DecodingError.dataCorrupted` when the integer is zero or
    ///   negative; `DecodingError.typeMismatch` when the value is not an
    ///   integer.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(Int.self)
        guard let line = LineNumber(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "ACP line numbers are 1-based; got \(raw)"
            )
        }
        self = line
    }

    /// Encodes the line number as a bare JSON integer.
    ///
    /// - Parameter encoder: The encoder to write the line number into.
    /// - Throws: Rethrows any error from the underlying encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
