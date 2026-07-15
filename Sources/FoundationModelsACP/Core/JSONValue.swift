/// Arbitrary JSON, preserved round-trip and never interpreted (spec §2, §3).
///
/// Used for the protocol's free-form fields — `_meta`, `rawInput`, `rawOutput`,
/// and MCP server environment values — where the ACP schema places no shape
/// constraints. Values decode into the matching case and re-encode to
/// equivalent JSON (modulo object key order).
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Decodes any JSON value into its matching case.
    ///
    /// - Parameter decoder: The decoder positioned at an arbitrary JSON value.
    /// - Throws: `DecodingError.dataCorrupted` if the value is not JSON
    ///   representable (unreachable with well-formed JSON input).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Value is not representable as JSON"
            )
        }
    }

    /// Encodes the value as bare JSON — no case discriminator, no wrapping.
    ///
    /// - Parameter encoder: The encoder to write the JSON value into.
    /// - Throws: Rethrows any error from the underlying encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}
