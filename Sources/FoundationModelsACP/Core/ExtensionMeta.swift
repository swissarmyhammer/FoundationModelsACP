import Foundation

/// Reads and writes the payload of an extension under its own member of a
/// `_meta` object.
///
/// ACP lets each side put custom data in `_meta`
/// (https://agentclientprotocol.com/protocol/v2/extensibility). An extension
/// keeps its data under one member, its namespace, so that it does not clash
/// with the data of another extension. A side advertises the extensions it
/// serves this way, for example in the `_meta` of the `initialize` response:
///
/// ```swift
/// let meta = try ExtensionMeta.inject(capabilities, into: response.meta, member: "vendor")
/// ```
///
/// The peer reads them back with ``payload(_:in:member:)``. The ``SAH``
/// namespace writes `_meta.sah` with these functions.
public enum ExtensionMeta {
    /// Reads an extension payload from one member of a JSON object.
    ///
    /// - Parameters:
    ///   - type: The payload type.
    ///   - object: The object that holds the member, for example a `_meta`
    ///     value, or `nil`.
    ///   - key: The member name: the namespace of the extension.
    /// - Returns: The payload, or `nil` when `object` is not an object, has no
    ///   member `key`, or has a member that is not a valid `type`.
    public static func payload<Payload: Decodable>(
        _ type: Payload.Type,
        in object: JSONValue?,
        member key: String
    ) -> Payload? {
        guard case .object(let members)? = object, let value = members[key] else {
            return nil
        }
        return try? value.decoded(as: type)
    }

    /// Writes an extension payload into one member of a JSON object.
    ///
    /// The function keeps every other member of `object`. When `object` is
    /// `nil` or JSON `null`, it starts from an empty object. When `object` is
    /// a different value that is not an object, it returns `object` unchanged.
    /// It does not replace the value of the peer.
    ///
    /// - Parameters:
    ///   - payload: The payload to write.
    ///   - object: The object to write the member into, for example a `_meta`
    ///     value.
    ///   - key: The member name: the namespace of the extension.
    /// - Returns: The object with the member.
    /// - Throws: `EncodingError` when the payload cannot be encoded, for
    ///   example when a ``JSONValue`` in it holds a number that is not finite.
    public static func inject(
        _ payload: some Encodable,
        into object: JSONValue?,
        member key: String
    ) throws -> JSONValue {
        guard var members = writableMembers(of: object) else {
            return object ?? .null
        }
        members[key] = try JSONValue.encode(result: payload)
        return .object(members)
    }

    /// Gives the members that a write starts from.
    ///
    /// - Parameter value: The value to write into, or `nil`.
    /// - Returns: The members of an object, an empty set for `nil` or JSON
    ///   `null`, or `nil` for a different value, which a write must not
    ///   replace.
    private static func writableMembers(of value: JSONValue?) -> [String: JSONValue]? {
        switch value {
        case nil, .null?:
            return [:]
        case .object(let members)?:
            return members
        case .bool?, .number?, .string?, .array?:
            return nil
        }
    }
}
