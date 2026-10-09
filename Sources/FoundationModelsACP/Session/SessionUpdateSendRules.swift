import Foundation

// The schema rules that a session update must obey before it is sent, where
// the Swift type of the value is wider than the schema.
//
// A `StopReason.unknown` holds any string, the `uint64` counts of
// `UsageUpdate` are a signed `Int`, and `Cost.currency` is any string. A
// receiver must accept such values, so decoding keeps them and these rules
// never apply to decoding. A sender must not make them, so
// `AgentSideConnection.sessionUpdate(_:)` applies these rules before it writes
// an update.

extension SessionUpdate {
    /// Makes sure that the update obeys the schema rules for a sent update.
    ///
    /// - Throws: `EncodingError.invalidValue` when a value breaks a rule. The
    ///   description of the error names the member and the rule.
    func validateForSending() throws {
        if case .stateUpdate(.idle(let idle)) = self, let reason = idle.stopReason {
            try reason.validateForSending()
        }
        if case .usageUpdate(let usage) = self {
            try usage.validateForSending()
        }
    }
}

extension StopReason {
    /// The prefix of an implementation-specific stop reason.
    private static let customValuePrefix = "_"

    /// Makes sure that the stop reason is an ACP value or a custom value.
    ///
    /// A custom value starts with `_`. Other values that ACP does not define
    /// are reserved for future ACP versions. An `unknown` case that holds an
    /// ACP value is correct, because its wire value is that ACP value.
    ///
    /// - Throws: `EncodingError.invalidValue` for a reserved value.
    func validateForSending() throws {
        let value = wireValue
        let isACPValue = StopReason(wireValue: value) != .unknown(value)
        guard isACPValue || value.hasPrefix(Self.customValuePrefix) else {
            throw EncodingError.sendRuleBroken(
                by: value,
                "the stopReason \"\(value)\" is reserved for a future ACP version; "
                    + "a custom stop reason must start with \"\(Self.customValuePrefix)\""
            )
        }
    }
}

extension UsageUpdate {
    /// Makes sure that each token count is a `uint64`, and that the cost has
    /// an ISO 4217 currency code.
    ///
    /// - Throws: `EncodingError.invalidValue` for a negative count or an
    ///   incorrect currency code.
    func validateForSending() throws {
        try Self.validateTokenCount(size, named: "size")
        try Self.validateTokenCount(used, named: "used")
        try cost?.validateForSending()
    }

    /// Makes sure that a token count is zero or more.
    ///
    /// - Parameters:
    ///   - count: The token count.
    ///   - member: The wire name of the count.
    /// - Throws: `EncodingError.invalidValue` for a negative count.
    private static func validateTokenCount(_ count: Int, named member: String) throws {
        guard count >= 0 else {
            throw EncodingError.sendRuleBroken(
                by: count,
                "the usage_update \(member) is \(count); the schema makes it a uint64, which is 0 or more"
            )
        }
    }
}

extension Cost {
    /// The number of letters in an ISO 4217 currency code.
    private static let currencyCodeLength = 3

    /// The letters that an ISO 4217 currency code can hold.
    private static let currencyCodeLetters = UInt8(ascii: "A")...UInt8(ascii: "Z")

    /// Makes sure that the currency agrees with the schema pattern
    /// `^[A-Z]{3}$`.
    ///
    /// - Throws: `EncodingError.invalidValue` for an incorrect currency code.
    func validateForSending() throws {
        let code = currency.utf8
        guard code.count == Self.currencyCodeLength, code.allSatisfy(Self.currencyCodeLetters.contains) else {
            throw EncodingError.sendRuleBroken(
                by: currency,
                "the cost currency \"\(currency)\" is not an ISO 4217 code of "
                    + "\(Self.currencyCodeLength) upper-case letters A to Z"
            )
        }
    }
}

extension EncodingError {
    /// The error for a value that breaks a schema rule for a sent update.
    ///
    /// - Parameters:
    ///   - value: The value that breaks the rule.
    ///   - description: The member and the rule that the value breaks.
    /// - Returns: An `invalidValue` error with no coding path.
    fileprivate static func sendRuleBroken(by value: Any, _ description: String) -> EncodingError {
        .invalidValue(value, Context(codingPath: [], debugDescription: description))
    }
}
