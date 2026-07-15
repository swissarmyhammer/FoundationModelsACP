/// Runtime support for the ACP schema's forgiving-decoding extension keywords
/// (spec §2): `x-deserialize-default-on-error` (a malformed field degrades to
/// a default instead of failing the whole message — the Rust SDK's
/// `DefaultOnError`) and `x-deserialize-skip-invalid-items` (malformed array
/// elements are dropped — the Rust SDK's `VecSkipError`). Generated
/// `init(from:)` implementations call these helpers for annotated fields, so
/// an unknown or malformed capability field degrades to "unsupported" instead
/// of failing the `initialize` handshake.
///
/// Wire-invariant fields (`AbsolutePath`, `LineNumber`) never go through
/// these helpers — invariant violations must stay decode-time errors.

/// Wrapper whose decode never fails — a malformed wrapped value becomes `nil`.
///
/// Used to decode arrays element-by-element so invalid items can be skipped
/// without failing the surrounding array.
struct FailableDecodeBox<Wrapped: Decodable>: Decodable {
    /// The decoded value, or `nil` when the element was malformed.
    let value: Wrapped?

    /// Decodes the wrapped value, swallowing any decoding error.
    ///
    /// - Parameter decoder: The decoder positioned at the element.
    init(from decoder: any Decoder) {
        value = try? Wrapped(from: decoder)
    }
}

extension KeyedDecodingContainer {
    /// Decodes an optional field, degrading to `nil` on any decoding error
    /// (`x-deserialize-default-on-error` on an optional field).
    ///
    /// - Parameters:
    ///   - type: The value type to decode.
    ///   - key: The field's coding key.
    /// - Returns: The decoded value, or `nil` when absent, null, or malformed.
    func forgivingDecodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    /// Decodes a field, degrading to a default on absence, null, or any
    /// decoding error (`x-deserialize-default-on-error` with a schema
    /// `default`).
    ///
    /// - Parameters:
    ///   - type: The value type to decode.
    ///   - key: The field's coding key.
    ///   - fallback: The schema default used when decoding fails.
    /// - Returns: The decoded value, or `fallback`.
    func forgivingDecode<T: Decodable>(
        _ type: T.Type,
        forKey key: Key,
        default fallback: @autoclosure () -> T
    ) -> T {
        forgivingDecodeIfPresent(type, forKey: key) ?? fallback()
    }

    /// Decodes an array field, dropping malformed elements and degrading to
    /// empty on absence, null, or a malformed value
    /// (`x-deserialize-skip-invalid-items` on a defaulted or required array).
    ///
    /// - Parameters:
    ///   - elementType: The array element type.
    ///   - key: The field's coding key.
    /// - Returns: The valid elements, or `[]`.
    func forgivingDecodeArray<Element: Decodable>(
        of elementType: Element.Type,
        forKey key: Key
    ) -> [Element] {
        forgivingDecodeArrayIfPresent(of: elementType, forKey: key) ?? []
    }

    /// Decodes an optional array field, dropping malformed elements and
    /// degrading to `nil` on absence, null, or a malformed value
    /// (`x-deserialize-skip-invalid-items` on an optional field).
    ///
    /// - Parameters:
    ///   - elementType: The array element type.
    ///   - key: The field's coding key.
    /// - Returns: The valid elements, or `nil`.
    func forgivingDecodeArrayIfPresent<Element: Decodable>(
        of elementType: Element.Type,
        forKey key: Key
    ) -> [Element]? {
        guard let boxes = forgivingDecodeIfPresent([FailableDecodeBox<Element>].self, forKey: key) else {
            return nil
        }
        return boxes.compactMap(\.value)
    }
}
