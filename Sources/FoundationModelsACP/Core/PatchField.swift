/// A field with three-state patch semantics: omitted, `null`, and a concrete
/// value are distinct wire states (ACP v2 upsert prose, e.g. `ToolCallUpdate`:
/// "omitted fields leave the existing tool call value unchanged, `null`
/// clears or unsets the value, and concrete values replace the previous
/// value").
///
/// A plain `Optional` cannot express this: `Codable`'s `decodeIfPresent`
/// collapses "absent" and "null" to the same `nil`, and `encodeIfPresent`
/// always omits the key for a `nil` value — so a client that means "clear"
/// cannot be told apart from one that means "leave unchanged", in either
/// direction.
///
/// `PatchField` itself does not conform to `Codable`: omitting a key from
/// inside a value's own `encode(to:)` is not expressible — by the time a
/// value's `encode(to:)` runs, the container has already committed to a slot
/// for it, and nothing that method does can retroactively decide not to have
/// asked for one. Coding instead lives on the *container*, one level up,
/// where the choice of whether to touch the key at all is still open:
/// `KeyedDecodingContainer.decodePatchField` (and its forgiving variants)
/// check key presence and nullity before ever delegating to `Wrapped`'s own
/// decode, and `KeyedEncodingContainer.encodePatch` chooses between
/// `encodeNil`, `encode`, or calling nothing before the key would be
/// written.
public enum PatchField<Wrapped: Codable & Hashable & Sendable>: Hashable, Sendable {
    /// The field was omitted: leave the stored value unchanged.
    case unchanged

    /// The field was explicitly `null`: clear the stored value.
    case cleared

    /// The field carried a concrete value: replace the stored value.
    case value(Wrapped)
}

extension KeyedDecodingContainer {
    /// Decodes a field with patch semantics, distinguishing an omitted key
    /// (`.unchanged`), an explicit `null` (`.cleared`), and a concrete value
    /// (`.value`) — the wire's three states, which `decodeIfPresent` alone
    /// collapses to two.
    ///
    /// - Parameters:
    ///   - type: The wrapped value type to decode.
    ///   - key: The field's coding key.
    /// - Returns: The field's patch state.
    /// - Throws: `DecodingError` when the key is present, non-null, and the
    ///   value does not decode as `Wrapped`.
    func decodePatchField<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> PatchField<T> {
        guard contains(key) else { return .unchanged }
        if try decodeNil(forKey: key) {
            return .cleared
        }
        return .value(try decode(T.self, forKey: key))
    }

    /// Runs the omitted/`null`/present guard sequence shared by every
    /// forgiving patch-semantics decode, delegating the final decode and any
    /// transform to `decodeValue` so `forgivingDecodePatchField` and
    /// `forgivingDecodePatchArray` cannot drift apart on the shared part.
    ///
    /// Degrading to `.unchanged` rather than `.cleared` when `decodeValue`
    /// returns `nil` is deliberate: a malformed value reads as noise, not as
    /// a deliberate clear signal, and leaving the stored value alone is the
    /// safer of the two degradations.
    ///
    /// - Parameters:
    ///   - key: The field's coding key.
    ///   - decodeValue: Decodes and transforms the present, non-null value;
    ///     a `nil` result degrades the field to `.unchanged`.
    /// - Returns: The field's patch state.
    private func forgivingDecodePatch<Value>(
        forKey key: Key,
        decodeValue: () -> Value?
    ) -> PatchField<Value> {
        guard contains(key) else { return .unchanged }
        guard let isNull = try? decodeNil(forKey: key) else { return .unchanged }
        guard !isNull else { return .cleared }
        guard let value = decodeValue() else { return .unchanged }
        return .value(value)
    }

    /// Decodes a field with patch semantics, degrading a present-but-malformed
    /// value to `.unchanged` instead of failing the message
    /// (`x-deserialize-default-on-error` combined with patch semantics).
    ///
    /// - Parameters:
    ///   - type: The wrapped value type to decode.
    ///   - key: The field's coding key.
    /// - Returns: The field's patch state.
    func forgivingDecodePatchField<T: Decodable>(_ type: T.Type, forKey key: Key) -> PatchField<T> {
        forgivingDecodePatch(forKey: key) { try? decode(T.self, forKey: key) }
    }

    /// Decodes an array field with patch semantics, dropping malformed
    /// elements rather than discarding the whole array
    /// (`x-deserialize-skip-invalid-items` combined with patch semantics).
    ///
    /// - Parameters:
    ///   - elementType: The array element type.
    ///   - key: The field's coding key.
    /// - Returns: The field's patch state.
    func forgivingDecodePatchArray<Element: Decodable>(
        of elementType: Element.Type,
        forKey key: Key
    ) -> PatchField<[Element]> {
        forgivingDecodePatch(forKey: key) {
            (try? decode([FailableDecodeBox<Element>].self, forKey: key)).map { $0.compactMap(\.value) }
        }
    }
}

extension KeyedEncodingContainer {
    /// Encodes a field with patch semantics: `.unchanged` omits the key
    /// entirely, `.cleared` writes an explicit `null`, and `.value` writes
    /// the wrapped value — the inverse of `decodePatchField`.
    ///
    /// - Parameters:
    ///   - field: The field's patch state.
    ///   - key: The field's coding key.
    /// - Throws: Rethrows any error from the underlying encoder.
    mutating func encodePatch<T: Encodable>(_ field: PatchField<T>, forKey key: Key) throws {
        switch field {
        case .unchanged:
            break
        case .cleared:
            try encodeNil(forKey: key)
        case .value(let wrapped):
            try encode(wrapped, forKey: key)
        }
    }
}
