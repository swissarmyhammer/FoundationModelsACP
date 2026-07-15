import FoundationModelsACP

/// Typed accessors for navigating a parsed JSON schema document.
extension JSONValue {
    /// The object members when this value is a JSON object, else `nil`.
    var objectValue: [String: JSONValue]? { unwrapped() }

    /// The elements when this value is a JSON array, else `nil`.
    var arrayValue: [JSONValue]? { unwrapped() }

    /// The string when this value is a JSON string, else `nil`.
    var stringValue: String? { unwrapped() }

    /// The boolean when this value is a JSON bool, else `nil`.
    var boolValue: Bool? { unwrapped() }

    /// Looks up an object member by key; `nil` when absent or not an object.
    ///
    /// - Parameter key: The member name.
    /// - Returns: The member value, or `nil`.
    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// Extracts the associated value when it has the caller's expected type —
    /// the single pattern-match behind every typed accessor above.
    ///
    /// - Returns: The associated value as `T`, or `nil` when this case's
    ///   payload is not a `T` (including `.null`, which has none).
    private func unwrapped<T>() -> T? {
        switch self {
        case .null: nil
        case .bool(let value): value as? T
        case .number(let value): value as? T
        case .string(let value): value as? T
        case .array(let value): value as? T
        case .object(let value): value as? T
        }
    }
}
