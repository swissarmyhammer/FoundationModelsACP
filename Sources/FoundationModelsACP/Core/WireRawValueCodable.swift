/// Shared Codable implementation for `RawRepresentable` wire newtypes.
///
/// ACP newtypes (`ProtocolVersion`, `AbsolutePath`, `LineNumber`, and the
/// generated ID types) cross the wire as their **bare raw value** — no keyed
/// wrapper — and re-validate through `init?(rawValue:)` on decode so wire
/// invariants (spec §4) hold for received data too. Conforming types get both
/// `Codable` requirements from the extension below; invariant-carrying types
/// override `invalidWireValueDescription(_:)` to explain a rejection.
public protocol WireRawValueCodable: RawRepresentable, Codable where RawValue: Codable {
    /// Describes why `rawValue` was rejected, for `DecodingError` messages.
    ///
    /// - Parameter rawValue: The decoded raw value that `init?(rawValue:)`
    ///   returned `nil` for.
    /// - Returns: A human-readable statement of the violated wire invariant.
    static func invalidWireValueDescription(_ rawValue: RawValue) -> String
}

extension WireRawValueCodable {
    /// Default rejection message for types whose `init(rawValue:)` cannot
    /// fail; kept for protocol completeness.
    ///
    /// - Parameter rawValue: The rejected raw value.
    /// - Returns: A generic invalid-value description naming the type.
    public static func invalidWireValueDescription(_ rawValue: RawValue) -> String {
        "Invalid \(Self.self) wire value: \(rawValue)"
    }

    /// Decodes the bare raw value and validates it through `init?(rawValue:)`.
    ///
    /// - Parameter decoder: The decoder positioned at the bare wire value.
    /// - Throws: `DecodingError.typeMismatch` when the wire value is not the
    ///   raw value's JSON type; `DecodingError.dataCorrupted` when the value
    ///   violates the type's wire invariant.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(RawValue.self)
        guard let value = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: Self.invalidWireValueDescription(raw)
            )
        }
        self = value
    }

    /// Encodes the newtype as its bare raw value — no keyed wrapper.
    ///
    /// - Parameter encoder: The encoder to write the raw value into.
    /// - Throws: Rethrows any error from the underlying encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
