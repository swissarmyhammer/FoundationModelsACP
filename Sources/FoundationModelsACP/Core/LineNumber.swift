/// A 1-based line number within a file.
///
/// The wire value is a bare unsigned integer. `0` is invalid, so the failable
/// initializer refuses it, and a decoder refuses it too. Wire coding comes
/// from ``WireRawValueCodable``.
public struct LineNumber: WireRawValueCodable, Hashable, Sendable, ExpressibleByIntegerLiteral {
    /// The wire value, `1` or more.
    public let rawValue: UInt32

    /// Creates a line number from its wire integer.
    ///
    /// - Parameter rawValue: The 1-based line number.
    /// - Returns: `nil` for `0`, which is not a line number.
    public init?(rawValue: UInt32) {
        guard rawValue >= 1 else { return nil }
        self.rawValue = rawValue
    }

    /// Creates a line number from an integer literal.
    ///
    /// A literal of `0` stops the program, because the value is a mistake in
    /// the source and not data from a peer.
    ///
    /// - Parameter value: The 1-based line number.
    public init(integerLiteral value: UInt32) {
        guard let line = LineNumber(rawValue: value) else {
            preconditionFailure("A line number is 1-based; 0 is not a line number.")
        }
        self = line
    }

    /// Describes why `rawValue` was rejected.
    ///
    /// - Parameter rawValue: The rejected wire value.
    /// - Returns: The violated wire invariant.
    public static func invalidWireValueDescription(of rawValue: UInt32) -> String {
        "Invalid LineNumber wire value: \(rawValue); a line number is 1-based"
    }
}
