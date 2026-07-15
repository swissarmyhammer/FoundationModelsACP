/// A file path that is guaranteed absolute — the ACP wire invariant (spec §4).
///
/// All paths crossing the protocol boundary must be absolute; a relative path
/// is rejected at construction and at decode so it becomes a compile- or
/// decode-time error instead of a silent interop bug.
public struct AbsolutePath: RawRepresentable, Codable, Hashable, Sendable {
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

    /// Decodes the path from a bare JSON string, enforcing absoluteness.
    ///
    /// - Parameter decoder: The decoder positioned at the path value.
    /// - Throws: `DecodingError.dataCorrupted` when the string is a relative
    ///   path; `DecodingError.typeMismatch` when the value is not a string.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let path = AbsolutePath(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "ACP paths must be absolute; got \"\(raw)\""
            )
        }
        self = path
    }

    /// Encodes the path as a bare JSON string.
    ///
    /// - Parameter encoder: The encoder to write the path into.
    /// - Throws: Rethrows any error from the underlying encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
