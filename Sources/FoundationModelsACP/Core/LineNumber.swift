/// A 1-based line number — the ACP wire invariant (spec §4).
///
/// ACP line numbers start at 1; `0` and negative values are rejected at
/// construction and at decode so an off-by-one (0-based) producer surfaces as
/// a decode-time error instead of a silent interop bug. Wire coding comes
/// from ``WireRawValueCodable``, which re-validates through `init?(rawValue:)`.
public struct LineNumber: WireRawValueCodable, Hashable, Sendable {
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

    /// Explains a rejected wire value in `DecodingError` messages.
    ///
    /// - Parameter rawValue: The non-positive line number that was rejected.
    /// - Returns: A statement of the 1-based wire invariant.
    public static func invalidWireValueDescription(_ rawValue: Int) -> String {
        "ACP line numbers are 1-based; got \(rawValue)"
    }
}
