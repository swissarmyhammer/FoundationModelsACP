/// A file path that is guaranteed absolute — the ACP wire invariant (spec §4).
///
/// All paths crossing the protocol boundary must be absolute; a relative path
/// is rejected at construction and at decode so it becomes a compile- or
/// decode-time error instead of a silent interop bug. Wire coding comes from
/// ``WireRawValueCodable``, which re-validates through `init?(rawValue:)`.
public struct AbsolutePath: WireRawValueCodable, Hashable, Sendable {
    /// The absolute path string, always beginning with `/`.
    public let rawValue: String

    /// Creates an absolute path, rejecting relative input.
    ///
    /// - Parameter rawValue: The candidate path string.
    /// - Returns: `nil` unless `rawValue` begins with `/`.
    public init?(rawValue: String) {
        guard rawValue.hasPrefix("/") else { return nil }
        self.rawValue = rawValue
    }

    /// Explains a rejected wire value in `DecodingError` messages.
    ///
    /// - Parameter rawValue: The relative path that was rejected.
    /// - Returns: A statement of the absolute-path wire invariant.
    public static func invalidWireValueDescription(_ rawValue: String) -> String {
        "ACP paths must be absolute; got \"\(rawValue)\""
    }
}
