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

// MARK: - Flattened object members

extension JSONValue {
    /// Decodes the JSON object at a decoder, dropping named members.
    ///
    /// This is how a generated union captures the payload of a variant it
    /// cannot name. Two kinds of member are dropped, and for the same reason —
    /// something else already owns them, so keeping a second copy here lets the
    /// two disagree. The discriminator is held as the case's own associated
    /// value; and where the union is nested in a struct, that struct's own
    /// properties are decoded and re-encoded by the struct.
    ///
    /// - Parameters:
    ///   - decoder: The decoder positioned at the object.
    ///   - members: The wire names to drop.
    /// - Throws: `DecodingError` when the value is not a JSON object, since a
    ///   discriminated variant is always one.
    public init(from decoder: any Decoder, excludingMembers members: [String]) throws {
        guard case .object(var remaining) = try JSONValue(from: decoder) else {
            throw DecodingError.typeMismatch(
                [String: JSONValue].self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "an unrecognized variant must be a JSON object"
                )
            )
        }
        for member in members {
            remaining.removeValue(forKey: member)
        }
        self = .object(remaining)
    }

    /// Encodes an object's members as members of the encoder's own object,
    /// rather than as a nested value.
    ///
    /// The inverse of `init(from:excludingMembers:)`: it writes a captured
    /// payload back beside the members its owners encode for themselves, which
    /// is what makes an unrecognized variant round-trip.
    ///
    /// `reserved` names those owners' members, and a payload declaring one is
    /// rejected rather than written. Two keyed containers over the same encoder
    /// share one object and the last write wins, so a payload carrying the
    /// discriminator would silently overwrite the tag its own case holds, and
    /// one carrying an enclosing struct's property would overwrite that
    /// property — in both cases re-encoding to a document that says something
    /// the value did not. Decoding never produces such a payload, since
    /// `init(from:excludingMembers:)` drops exactly these names; a value built
    /// in Swift can, and this is the boundary that catches it.
    ///
    /// - Parameters:
    ///   - encoder: The encoder positioned at the enclosing object.
    ///   - reserved: Member names the enclosing object encodes itself.
    /// - Throws: `EncodingError.invalidValue` when the value is not an object,
    ///   which has no members to flatten, or when it declares a reserved
    ///   member; otherwise rethrows from the encoder.
    public func encodeMembers(to encoder: any Encoder, reserving reserved: [String]) throws {
        guard case .object(let members) = self else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "only a JSON object has members to flatten"
                )
            )
        }
        let claimed = reserved.filter { members[$0] != nil }.sorted()
        guard claimed.isEmpty else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription:
                        "flattened payload declares \(claimed.joined(separator: ", ")), which the enclosing object owns"
                )
            )
        }
        var container = encoder.container(keyedBy: MemberKey.self)
        for (name, value) in members {
            try container.encode(value, forKey: MemberKey(name))
        }
    }

    /// A coding key for an arbitrary JSON object member name.
    private struct MemberKey: CodingKey {
        let stringValue: String

        var intValue: Int? { nil }

        init(_ stringValue: String) {
            self.stringValue = stringValue
        }

        init?(stringValue: String) {
            self.init(stringValue)
        }

        init?(intValue: Int) {
            nil
        }
    }
}
