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
        ExtensionMeta.payload(type, in: sahObject(of: meta), member: key)
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
        let updatedSAHObject = try ExtensionMeta.inject(payload, into: sahObject(of: meta), member: key)
        return try ExtensionMeta.inject(updatedSAHObject, into: meta, member: metaKey)
    }

    /// Gives the SAH object of a `_meta` value: `_meta.sah`.
    ///
    /// - Parameter meta: The `_meta` value, or `nil`.
    /// - Returns: The value of `_meta.sah`, or `nil` when `meta` is not an
    ///   object or has no `sah` member.
    private static func sahObject(of meta: JSONValue?) -> JSONValue? {
        ExtensionMeta.payload(JSONValue.self, in: meta, member: metaKey)
    }
}
