import Foundation

/// A focused validator for the JSON Schema keyword set the vendored
/// `Schema/acp-v2.json` document actually uses.
///
/// This is not a general-purpose Draft 2020-12 implementation. It supports
/// exactly the keywords a sweep of the vendored document turns up: `$ref` /
/// `$defs`, `type` (string or array form), `properties` / `required` /
/// `additionalProperties`, `items` / `minItems` / `maxItems`, `enum` /
/// `const`, `pattern` / `minLength` / `maxLength`, `minimum` / `maximum`,
/// `allOf` / `anyOf` / `oneOf` / `not`, and the specific `format` values the
/// document declares (`int32`, `int64`, `uint16`, `uint32`, `uint64`,
/// `double`, `date-time`, `uri`, `regex`). Before relying on a keyword this
/// list omits, grep `Schema/acp-v2.json` for it and add support here —
/// silently ignoring an unrecognized keyword would let a real violation pass.
///
/// Instances are Foundation's `JSONSerialization` object graph (`NSNumber`,
/// `String`, `NSNull`, `[Any]`, `[String: Any]`), not this package's own
/// `JSONValue` — this suite validates the raw bytes that actually cross the
/// wire, independent of any of this library's own decoding.
struct JSONSchemaValidator {
    /// Thrown when the schema document itself is malformed.
    struct SetupError: Error, CustomStringConvertible {
        let description: String
    }

    private let root: [String: Any]
    private let defs: [String: Any]

    /// - Parameter schemaDocument: The parsed top-level `Schema/acp-v2.json`
    ///   object, holding `$defs` alongside the document's own root schema.
    /// - Throws: `SetupError` when the document carries no `$defs` object.
    init(schemaDocument: [String: Any]) throws {
        guard let defs = schemaDocument["$defs"] as? [String: Any] else {
            throw SetupError(description: "schema document has no top-level $defs object")
        }
        self.root = schemaDocument
        self.defs = defs
    }

    /// Validates `instance` against the document's root schema, or against
    /// `#/$defs/<definition>` when `definition` is given.
    ///
    /// - Parameters:
    ///   - instance: A `JSONSerialization` object graph to check.
    ///   - definition: A `$defs` key to validate against instead of the
    ///     document root.
    /// - Returns: Every violation found, each naming the JSON pointer path it
    ///   occurred at; empty means `instance` is valid.
    func errors(validating instance: Any, against definition: String? = nil) -> [String] {
        let schema: [String: Any]
        if let definition {
            schema = ["$ref": "#/$defs/\(definition)"]
        } else {
            schema = root
        }
        return validate(instance, schema: schema, path: "$")
    }

    // MARK: - Core recursion

    private func validate(_ instance: Any, schema: [String: Any], path: String) -> [String] {
        var errors: [String] = []

        if let ref = schema["$ref"] as? String {
            errors += validate(instance, schema: resolve(ref), path: path)
        }

        if let typeErrors = typeErrors(instance, schema: schema, path: path) {
            errors += typeErrors
        }

        if let enumValues = schema["enum"] as? [Any] {
            if !enumValues.contains(where: { jsonEqual($0, instance) }) {
                errors.append("\(path): \(describe(instance)) is not one of the enumerated values")
            }
        }
        if let constValue = schema["const"] {
            if !jsonEqual(constValue, instance) {
                errors.append("\(path): \(describe(instance)) does not equal the required const value")
            }
        }

        if let allOf = schema["allOf"] as? [[String: Any]] {
            for sub in allOf {
                errors += validate(instance, schema: sub, path: path)
            }
        }
        if let anyOf = schema["anyOf"] as? [[String: Any]] {
            let branchResults = anyOf.map { validate(instance, schema: $0, path: path) }
            if !branchResults.contains(where: \.isEmpty) {
                errors.append("\(path): matched none of \(anyOf.count) anyOf branches")
            }
        }
        if let oneOf = schema["oneOf"] as? [[String: Any]] {
            let matchCount = oneOf.filter { validate(instance, schema: $0, path: path).isEmpty }.count
            if matchCount != 1 {
                errors.append("\(path): matched \(matchCount) of \(oneOf.count) oneOf branches, expected exactly 1")
            }
        }
        if let notSchema = schema["not"] as? [String: Any] {
            if validate(instance, schema: notSchema, path: path).isEmpty {
                errors.append("\(path): matched a forbidden \"not\" schema")
            }
        }

        if let object = instance as? [String: Any] {
            errors += validateObject(object, schema: schema, path: path)
        }
        if let array = instance as? [Any] {
            errors += validateArray(array, schema: schema, path: path)
        }
        if let string = instance as? String {
            errors += validateString(string, schema: schema, path: path)
        }
        if let number = instance as? NSNumber, !isBoolean(number) {
            errors += validateNumber(number, schema: schema, path: path)
        }

        return errors
    }

    private func resolve(_ ref: String) -> [String: Any] {
        let prefix = "#/$defs/"
        guard ref.hasPrefix(prefix) else {
            preconditionFailure("unsupported $ref \(ref); only local #/$defs/ refs are vendored")
        }
        let name = String(ref.dropFirst(prefix.count))
        guard let target = defs[name] as? [String: Any] else {
            preconditionFailure("$ref target \"\(name)\" is not a $defs entry")
        }
        return target
    }

    // MARK: - `type`

    private func typeErrors(_ instance: Any, schema: [String: Any], path: String) -> [String]? {
        guard let typeField = schema["type"] else { return nil }
        let types: [String]
        if let single = typeField as? String {
            types = [single]
        } else if let multiple = typeField as? [String] {
            types = multiple
        } else {
            return nil
        }
        if types.contains(where: { matchesType(instance, $0) }) { return nil }
        return ["\(path): \(describe(instance)) does not match type \(types.joined(separator: " | "))"]
    }

    private func matchesType(_ instance: Any, _ type: String) -> Bool {
        switch type {
        case "null":
            return instance is NSNull
        case "boolean":
            guard let number = instance as? NSNumber else { return false }
            return isBoolean(number)
        case "integer":
            guard let number = instance as? NSNumber, !isBoolean(number) else { return false }
            return number.doubleValue.rounded(.towardZero) == number.doubleValue
        case "number":
            guard let number = instance as? NSNumber else { return false }
            return !isBoolean(number)
        case "string":
            return instance is String
        case "array":
            return instance is [Any]
        case "object":
            return instance is [String: Any]
        default:
            return false
        }
    }

    /// `JSONSerialization` bridges JSON booleans through `NSNumber`
    /// (`CFBoolean`), the same runtime type it uses for numbers — this is the
    /// standard way to tell the two apart.
    private func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    // MARK: - Object / array / string / number keywords

    private func validateObject(_ object: [String: Any], schema: [String: Any], path: String) -> [String] {
        var errors: [String] = []
        let properties = schema["properties"] as? [String: Any] ?? [:]

        for (key, subschemaAny) in properties {
            guard let value = object[key], let subschema = subschemaAny as? [String: Any] else { continue }
            errors += validate(value, schema: subschema, path: "\(path).\(key)")
        }

        if let required = schema["required"] as? [String] {
            for key in required where object[key] == nil {
                errors.append("\(path): missing required property \"\(key)\"")
            }
        }

        let extraKeys = object.keys.filter { properties[$0] == nil }
        switch schema["additionalProperties"] {
        case let allowed as Bool:
            if !allowed, !extraKeys.isEmpty {
                errors.append("\(path): unexpected propert\(extraKeys.count == 1 ? "y" : "ies") \(extraKeys.sorted())")
            }
        case let subschema as [String: Any]:
            for key in extraKeys {
                errors += validate(object[key]!, schema: subschema, path: "\(path).\(key)")
            }
        default:
            break
        }

        return errors
    }

    private func validateArray(_ array: [Any], schema: [String: Any], path: String) -> [String] {
        var errors: [String] = []
        if let itemsSchema = schema["items"] as? [String: Any] {
            for (index, element) in array.enumerated() {
                errors += validate(element, schema: itemsSchema, path: "\(path)[\(index)]")
            }
        }
        if let minItems = schema["minItems"] as? Int, array.count < minItems {
            errors.append("\(path): has \(array.count) items, fewer than the required minimum \(minItems)")
        }
        if let maxItems = schema["maxItems"] as? Int, array.count > maxItems {
            errors.append("\(path): has \(array.count) items, more than the allowed maximum \(maxItems)")
        }
        return errors
    }

    private func validateString(_ string: String, schema: [String: Any], path: String) -> [String] {
        var errors: [String] = []
        if let pattern = schema["pattern"] as? String {
            let range = NSRange(string.startIndex..<string.endIndex, in: string)
            let matched = (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: string, range: range)
            if matched == nil {
                errors.append("\(path): \"\(string)\" does not match pattern /\(pattern)/")
            }
        }
        if let minLength = schema["minLength"] as? Int, string.count < minLength {
            errors.append("\(path): \"\(string)\" is shorter than the required minimum length \(minLength)")
        }
        if let maxLength = schema["maxLength"] as? Int, string.count > maxLength {
            errors.append("\(path): \"\(string)\" is longer than the allowed maximum length \(maxLength)")
        }
        if let format = schema["format"] as? String {
            if let violation = stringFormatViolation(string, format: format) {
                errors.append("\(path): \"\(string)\" \(violation)")
            }
        }
        return errors
    }

    private func validateNumber(_ number: NSNumber, schema: [String: Any], path: String) -> [String] {
        var errors: [String] = []
        let value = number.doubleValue
        if let minimum = schema["minimum"] as? NSNumber, !isBoolean(minimum), value < minimum.doubleValue {
            errors.append("\(path): \(value) is less than the required minimum \(minimum)")
        }
        if let maximum = schema["maximum"] as? NSNumber, !isBoolean(maximum), value > maximum.doubleValue {
            errors.append("\(path): \(value) is greater than the allowed maximum \(maximum)")
        }
        if let format = schema["format"] as? String {
            if let violation = numericFormatViolation(value, format: format) {
                errors.append("\(path): \(value) \(violation)")
            }
        }
        return errors
    }

    // MARK: - `format`

    private func stringFormatViolation(_ string: String, format: String) -> String? {
        switch format {
        case "uri":
            guard let url = URL(string: string), url.scheme != nil else {
                return "is not a valid absolute URI"
            }
            return nil
        case "date-time":
            return Self.dateTimePattern.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) == nil
                ? "is not a valid RFC 3339 date-time" : nil
        case "regex":
            return (try? NSRegularExpression(pattern: string)) == nil ? "does not compile as a regular expression" : nil
        default:
            // Every other declared format (see the type doc comment) is
            // numeric-only; a string never carries one.
            return nil
        }
    }

    private static let dateTimePattern = try! NSRegularExpression(
        pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$"#
    )

    private func numericFormatViolation(_ value: Double, format: String) -> String? {
        func outOfRange(_ range: ClosedRange<Double>) -> String? {
            guard value.rounded(.towardZero) == value else { return "is not an integer" }
            return range.contains(value) ? nil : "is outside the \(format) range \(range)"
        }
        switch format {
        case "int32": return outOfRange(-2_147_483_648...2_147_483_647)
        case "int64": return outOfRange(Double(Int64.min)...Double(Int64.max))
        case "uint16": return outOfRange(0...65535)
        case "uint32": return outOfRange(0...4_294_967_295)
        case "uint64": return outOfRange(0...Double(UInt64.max))
        case "double":
            return nil
        default:
            return nil
        }
    }

    // MARK: - Value equality / description

    private func jsonEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        switch (lhs, rhs) {
        case (is NSNull, is NSNull):
            return true
        case let (l as String, r as String):
            return l == r
        case let (l as NSNumber, r as NSNumber):
            return isBoolean(l) == isBoolean(r) && l.doubleValue == r.doubleValue
        case let (l as [Any], r as [Any]):
            return l.count == r.count && zip(l, r).allSatisfy { jsonEqual($0, $1) }
        case let (l as [String: Any], r as [String: Any]):
            return l.count == r.count && l.allSatisfy { key, value in r[key].map { jsonEqual(value, $0) } ?? false }
        default:
            return false
        }
    }

    private func describe(_ instance: Any) -> String {
        switch instance {
        case is NSNull: return "null"
        case let string as String: return "string \"\(string)\""
        case let number as NSNumber: return isBoolean(number) ? "boolean \(number)" : "number \(number)"
        case is [Any]: return "array"
        case is [String: Any]: return "object"
        default: return String(describing: instance)
        }
    }
}
