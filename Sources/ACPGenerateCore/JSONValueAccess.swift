import FoundationModelsACP

/// Typed accessors for navigating a parsed JSON schema document.
extension JSONValue {
    /// The object members when this value is a JSON object, else `nil`.
    var objectValue: [String: JSONValue]? {
        if case .object(let members) = self { members } else { nil }
    }

    /// The elements when this value is a JSON array, else `nil`.
    var arrayValue: [JSONValue]? {
        if case .array(let elements) = self { elements } else { nil }
    }

    /// The string when this value is a JSON string, else `nil`.
    var stringValue: String? {
        if case .string(let string) = self { string } else { nil }
    }

    /// The boolean when this value is a JSON bool, else `nil`.
    var boolValue: Bool? {
        if case .bool(let bool) = self { bool } else { nil }
    }

    /// Looks up an object member by key; `nil` when absent or not an object.
    ///
    /// - Parameter key: The member name.
    /// - Returns: The member value, or `nil`.
    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}
