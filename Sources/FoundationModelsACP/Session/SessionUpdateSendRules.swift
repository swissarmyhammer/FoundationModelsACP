import Foundation

// The schema rules that a session update must obey before it is sent, where
// the Swift type of the value is wider than the schema.
//
// A `StopReason.unknown` holds any string, and the `uint64` counts of
// `UsageUpdate` are a signed `Int`. A receiver must accept such values, so
// decoding keeps them and these rules never apply to decoding. A sender must not make them, so
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
        if case .subagentUpdate(let subagent) = self {
            try subagent.validateForSending()
        }
    }
}

extension SubagentUpdate {
    /// Makes sure that the child session ID is not empty. A client keys the
    /// child by this ID, and the first update for an ID announces the child.
    ///
    /// - Throws: `EncodingError.invalidValue` for an empty ID.
    func validateForSending() throws {
        guard !sessionId.rawValue.isEmpty else {
            throw EncodingError.sendRuleBroken(
                by: sessionId.rawValue,
                "the subagent_update sessionId is empty; a child session needs a session ID"
            )
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
    /// Makes sure that each token count is a `uint64`.
    ///
    /// The currency of the cost is not checked: since
    /// `schema-v2.0.0-alpha.11` it is an ISO 4217 code for money, or another
    /// unit such as `credits`.
    ///
    /// - Throws: `EncodingError.invalidValue` for a negative count.
    func validateForSending() throws {
        try Self.validateTokenCount(size, named: "size")
        try Self.validateTokenCount(used, named: "used")
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
