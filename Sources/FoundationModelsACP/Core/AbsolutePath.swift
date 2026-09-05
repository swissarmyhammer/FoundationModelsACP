/// A file-system path on the ACP wire: the schema's `AbsolutePath` `$def`.
///
/// The schema gives this definition the type `string`. It states the rule in
/// prose only: the path must be absolute. The protocol names no validator.
/// The agent owns the file system, so the agent checks the path and answers
/// JSON-RPC invalid params when the path is not absolute. This type carries
/// the value as sent, so that check can run. It does not refuse a value.
/// Wire coding comes from ``WireRawValueCodable``.
public struct AbsolutePath: WireRawValueCodable, Hashable, Sendable {
    /// The path string, as sent on the wire.
    public let rawValue: String

    /// Creates a path from its wire string.
    ///
    /// - Parameter rawValue: The path string, accepted as given.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}
