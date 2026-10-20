import Foundation

/// The namespace of the SwissArmyHammer (SAH) extensions of ACP.
///
/// ACP lets a peer add methods with a name that starts with `_`, and data in
/// `_meta`. SAH uses both. This namespace holds one `Codable` type for each SAH
/// extension message and each SAH `_meta` payload, so that the agent and the
/// client use one definition of the wire:
///
/// - The GraphQL tunnel, in ``SAH/GraphQL``: the `_sah/graphql/*` messages and
///   the endpoint list.
/// - The `_meta` payloads: ``SAH/InitializeMeta`` under `_meta.sah` of the
///   `initialize` response, ``SAH/SessionMessage`` under `_meta.sah.message`,
///   and ``SAH/RuleDenial`` under `_meta["sah/ruleDenial"]`.
///
/// The types only carry data. They do not send or receive a message, and they
/// do not parse GraphQL: a GraphQL document, its variables and its result stay
/// text and JSON.
public enum SAH {
    /// The `_meta` member name of the SAH object: `_meta.sah`.
    public static let metaKey = "sah"

    /// The version of the SAH extensions that this library knows.
    ///
    /// ``SAH/InitializeMeta`` gives this value in `_meta.sah.version`. A change
    /// to the wire that an old peer cannot read increments it.
    public static let version = 1
}

// MARK: - _meta placement

extension SAH {
    /// Reads a SAH payload from one member of a JSON object.
    ///
    /// - Parameters:
    ///   - type: The payload type.
    ///   - object: The object that holds the member, or `nil`.
    ///   - key: The member name.
    /// - Returns: The payload, or `nil` when `object` is not an object, has no
    ///   member `key`, or has a member that is not a valid `type`.
    static func payload<Payload: Decodable>(
        _ type: Payload.Type,
        in object: JSONValue?,
        member key: String
    ) -> Payload? {
        guard case .object(let members)? = object, let value = members[key] else {
            return nil
        }
        guard let data = try? JSONEncoder().encode(value) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Writes a SAH payload into one member of a JSON object.
    ///
    /// The function keeps every other member of `object`. When `object` is
    /// `nil` or JSON `null`, it starts from an empty object. When `object` is
    /// a different value that is not an object, it returns `object` unchanged.
    /// It does not replace the value of the peer.
    ///
    /// - Parameters:
    ///   - payload: The payload to write.
    ///   - object: The object to write the member into.
    ///   - key: The member name.
    /// - Returns: The object with the member.
    /// - Throws: `EncodingError` when the payload cannot be encoded, for
    ///   example when a ``JSONValue`` in it holds a number that is not finite.
    static func inject(
        _ payload: some Encodable,
        into object: JSONValue?,
        member key: String
    ) throws -> JSONValue {
        guard var members = writableMembers(of: object) else {
            return object ?? .null
        }
        members[key] = try json(payload)
        return .object(members)
    }

    /// Reads a SAH payload from one member of `_meta.sah`.
    ///
    /// - Parameters:
    ///   - type: The payload type.
    ///   - meta: The `_meta` value, or `nil`.
    ///   - key: The member name in `_meta.sah`.
    /// - Returns: The payload, or `nil` when there is no valid payload.
    static func payload<Payload: Decodable>(
        _ type: Payload.Type,
        inSAHObjectOf meta: JSONValue?,
        member key: String
    ) -> Payload? {
        guard case .object(let members)? = meta else {
            return nil
        }
        return payload(type, in: members[metaKey], member: key)
    }

    /// Writes a SAH payload into one member of `_meta.sah`.
    ///
    /// The function keeps every other member of `_meta` and of `_meta.sah`.
    /// When `_meta` or `_meta.sah` is `nil` or JSON `null`, it starts from an
    /// empty object. When one of them is a different value that is not an
    /// object, it returns `meta` unchanged.
    ///
    /// - Parameters:
    ///   - payload: The payload to write.
    ///   - meta: The `_meta` value to write into.
    ///   - key: The member name in `_meta.sah`.
    /// - Returns: The `_meta` value to send.
    /// - Throws: `EncodingError` when the payload cannot be encoded.
    static func inject(
        _ payload: some Encodable,
        intoSAHObjectOf meta: JSONValue?,
        member key: String
    ) throws -> JSONValue {
        guard var members = writableMembers(of: meta),
            var sahMembers = writableMembers(of: members[metaKey])
        else {
            return meta ?? .null
        }
        sahMembers[key] = try json(payload)
        members[metaKey] = .object(sahMembers)
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

    /// Encodes a value as a ``JSONValue``.
    ///
    /// - Parameter value: The value to encode.
    /// - Returns: The JSON of the value.
    /// - Throws: `EncodingError` when the value cannot be encoded.
    private static func json(_ value: some Encodable) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}
