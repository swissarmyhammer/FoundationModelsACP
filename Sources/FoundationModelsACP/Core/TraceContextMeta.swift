/// The W3C trace context of one span, as an ACP `_meta` object carries it.
///
/// Trace context crosses the process boundary in the `_meta` object of an ACP
/// request or notification. The client injects it, and the agent extracts it.
/// This type is the codec for that step. It does not import a tracing library.
/// ACPClient and ACPAgent adapt it to the `Injector` and `Extractor` of
/// swift-distributed-tracing.
///
/// The codec reads and writes two members at the top level of `_meta`:
/// `_meta.traceparent` and `_meta.tracestate`. The names are the W3C Trace
/// Context header names. The ACP extensibility text reserves the root of
/// `_meta` for this type of data, and MCP puts trace context at the root of its
/// own `_meta` in the same way. Thus a peer that knows only the W3C names finds
/// the values without a vendor prefix.
///
/// The codec carries only ids and flags. It never carries content: no prompt
/// text, no response text, and no tool data.
public struct TraceContextMeta: Sendable, Hashable {
    /// The `_meta` member name for the W3C `traceparent` value.
    public static let traceparentKey = "traceparent"

    /// The `_meta` member name for the W3C `tracestate` value.
    public static let tracestateKey = "tracestate"

    /// The maximum length of a `tracestate` value that the codec keeps, in
    /// characters.
    ///
    /// The W3C Trace Context specification tells a vendor to send at least 512
    /// characters of `tracestate`. The codec drops a longer value completely.
    /// It does not cut the value, because a cut can break a list member.
    public static let maximumTracestateLength = 512

    /// The W3C `traceparent` value: `version-traceid-parentid-flags`.
    ///
    /// The initializer validates this value. See ``init(traceparent:tracestate:)``.
    public let traceparent: String

    /// The W3C `tracestate` value, or `nil` when there is no value.
    ///
    /// The value is opaque to the codec. The codec does not parse it.
    public let tracestate: String?

    /// Makes a trace context from its W3C values.
    ///
    /// The initializer fails when `traceparent` is not valid. A valid value
    /// agrees with the W3C version-00 layout:
    ///
    /// - Four fields, with `-` between them: `version` (2 characters),
    ///   `trace-id` (32 characters), `parent-id` (16 characters) and `flags`
    ///   (2 characters). Thus the length is 55 characters.
    /// - Each field has only lowercase hexadecimal characters.
    /// - `version` is not `ff`. `trace-id` and `parent-id` are not all zeros.
    ///
    /// The W3C forward compatibility rule applies to a version above `00`. The
    /// first 55 characters must agree with the version-00 layout. The value
    /// can then be longer, but only when the next character is `-`. A
    /// version-00 value must be exactly 55 characters.
    ///
    /// The initializer drops a `tracestate` that is longer than
    /// ``maximumTracestateLength``. The trace context stays valid without it.
    ///
    /// - Parameters:
    ///   - traceparent: The W3C `traceparent` value.
    ///   - tracestate: The W3C `tracestate` value, or `nil`.
    public init?(traceparent: String, tracestate: String? = nil) {
        guard TraceparentLayout.isValid(traceparent) else {
            return nil
        }
        self.traceparent = traceparent
        self.tracestate = tracestate.flatMap { value in
            value.count <= Self.maximumTracestateLength ? value : nil
        }
    }

    /// Reads the trace context from an ACP `_meta` value.
    ///
    /// The function reads `_meta.traceparent` and `_meta.tracestate`. It
    /// ignores a `tracestate` member that is not a string.
    ///
    /// - Parameter meta: The `_meta` value of a request or notification.
    /// - Returns: The trace context, or `nil` when `meta` is `nil`, is not an
    ///   object, has no `traceparent` string, or has a `traceparent` that is
    ///   not valid.
    public static func extract(from meta: JSONValue?) -> TraceContextMeta? {
        guard case .object(let members)? = meta,
            let traceparent = string(members[traceparentKey])
        else {
            return nil
        }
        return TraceContextMeta(traceparent: traceparent, tracestate: string(members[tracestateKey]))
    }

    /// Writes this trace context into an ACP `_meta` value.
    ///
    /// The function keeps every other member of `meta`. It sets
    /// `traceparent`. It sets `tracestate` when this context has one, and
    /// removes an earlier `tracestate` when this context has none, because a
    /// `tracestate` from a different trace must not go with this
    /// `traceparent`.
    ///
    /// When `meta` is `nil` or JSON `null`, the function starts from an empty
    /// object. When `meta` is a different value that is not an object (a
    /// string, a number, a Boolean or an array), the function returns `meta`
    /// unchanged. It does not replace the value of the peer, so the trace
    /// context is not sent.
    ///
    /// - Parameter meta: The `_meta` value to add the trace context to.
    /// - Returns: The `_meta` value to send.
    public func inject(into meta: JSONValue?) -> JSONValue {
        guard let meta else {
            return injected(into: [:])
        }
        switch meta {
        case .null:
            return injected(into: [:])
        case .object(let members):
            return injected(into: members)
        case .bool, .number, .string, .array:
            return meta
        }
    }

    /// Adds the trace context members to the members of an object.
    ///
    /// - Parameter members: The members of the `_meta` object.
    /// - Returns: An object with the other members and the trace context.
    private func injected(into members: [String: JSONValue]) -> JSONValue {
        var result = members
        result[Self.traceparentKey] = .string(traceparent)
        result[Self.tracestateKey] = tracestate.map(JSONValue.string)
        return .object(result)
    }

    /// Gives the text of a JSON string.
    ///
    /// - Parameter value: A `_meta` member, or `nil` when it is not there.
    /// - Returns: The text, or `nil` when `value` is not a string.
    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value else {
            return nil
        }
        return text
    }
}

/// The W3C version-00 layout of a `traceparent` value.
///
/// The layout keeps the fields that later checks read. It validates the
/// `flags` field but does not keep it, because no check reads it.
private struct TraceparentLayout {
    /// The number of characters in the `version` field.
    static let versionLength = 2

    /// The number of characters in the `trace-id` field.
    static let traceIdLength = 32

    /// The number of characters in the `parent-id` field.
    static let parentIdLength = 16

    /// The number of characters in the `flags` field.
    static let flagsLength = 2

    /// The field lengths, in the order of the fields.
    static let fieldLengths = [versionLength, traceIdLength, parentIdLength, flagsLength]

    /// The length of a version-00 value: the fields and one separator
    /// between each two fields. The result is 55.
    static let length = fieldLengths.reduce(0, +) + fieldLengths.count - 1

    /// The separator between two fields.
    static let separator = UInt8(ascii: "-")

    /// The version that has an exact length.
    static let versionZero = Array("00".utf8)

    /// The version that the W3C specification forbids.
    static let forbiddenVersion = Array("ff".utf8)

    /// The characters `0` to `9`.
    static let decimalDigits = UInt8(ascii: "0")...UInt8(ascii: "9")

    /// The characters `a` to `f`.
    static let lowercaseHexLetters = UInt8(ascii: "a")...UInt8(ascii: "f")

    /// The `version` field.
    let version: ArraySlice<UInt8>

    /// The `trace-id` field.
    let traceId: ArraySlice<UInt8>

    /// The `parent-id` field.
    let parentId: ArraySlice<UInt8>

    /// Tells if a `traceparent` value is valid.
    ///
    /// - Parameter traceparent: The value to examine.
    /// - Returns: `true` when the first ``length`` characters agree with the
    ///   version-00 layout, and the rest is empty, or starts with `-` for a
    ///   version above `00`.
    static func isValid(_ traceparent: String) -> Bool {
        let bytes = Array(traceparent.utf8)
        guard let layout = TraceparentLayout(bytes.prefix(length)), layout.hasAllowedValues else {
            return false
        }
        guard let next = bytes.dropFirst(length).first else {
            return true
        }
        return !layout.version.elementsEqual(versionZero) && next == separator
    }

    /// Splits the first ``length`` characters of a value into the four fields.
    ///
    /// - Parameter prefix: The first ``length`` bytes of the value, or fewer
    ///   when the value is shorter.
    /// - Returns: `nil` when there are not exactly four fields, when a field
    ///   has the wrong length, or when a field has a character that is not
    ///   lowercase hexadecimal.
    init?(_ prefix: ArraySlice<UInt8>) {
        var fields = prefix.split(separator: Self.separator, omittingEmptySubsequences: false)[...]
        guard let version = fields.popFirst(),
            let traceId = fields.popFirst(),
            let parentId = fields.popFirst(),
            let flags = fields.popFirst(),
            fields.isEmpty
        else {
            return nil
        }
        let all = [version, traceId, parentId, flags]
        guard all.map(\.count) == Self.fieldLengths,
            all.allSatisfy({ field in field.allSatisfy(Self.isLowercaseHex) })
        else {
            return nil
        }
        self.version = version
        self.traceId = traceId
        self.parentId = parentId
    }

    /// `true` when the version is not `ff` and neither id is all zeros.
    var hasAllowedValues: Bool {
        !version.elementsEqual(Self.forbiddenVersion) && !Self.isAllZeros(traceId) && !Self.isAllZeros(parentId)
    }

    /// Tells if a byte is a lowercase hexadecimal character.
    ///
    /// - Parameter byte: The byte to examine.
    /// - Returns: `true` for `0` to `9` and `a` to `f`.
    private static func isLowercaseHex(_ byte: UInt8) -> Bool {
        decimalDigits.contains(byte) || lowercaseHexLetters.contains(byte)
    }

    /// Tells if an id field has only the character `0`.
    ///
    /// - Parameter field: The field to examine.
    /// - Returns: `true` when each character is `0`.
    private static func isAllZeros(_ field: ArraySlice<UInt8>) -> Bool {
        field.allSatisfy { byte in byte == decimalDigits.lowerBound }
    }
}
