import Testing

/// Validates real, previously-captured ACP wire traffic against the vendored
/// `Schema/acp-v2.json` document.
///
/// `../../Tests/ACPGenerateTests/VendoredSchemaTests.swift` (in the unit
/// suite) proves the *generator's Swift output* matches the schema's shape
/// declaratively — every emitted case, every property, every routing entry.
/// It never checks that real JSON on the wire actually validates against the
/// schema's own Draft 2020-12 rules (`required`, `additionalProperties`,
/// numeric ranges, string formats, …). This suite closes that gap.
@Suite struct SchemaConformanceTests {
    private static func validator() throws -> JSONSchemaValidator {
        let document = try TestSupport.jsonObject(atTreeRelativePath: "Schema/acp-v2.json")
        guard let object = document as? [String: Any] else {
            Issue.record("Schema/acp-v2.json did not decode to a JSON object")
            throw TimedOutError()  // unreachable; satisfies the return type
        }
        return try JSONSchemaValidator(schemaDocument: object)
    }

    /// Every line of `full-session-agent.ndjson` — a real recorded
    /// `initialize` → `session/new` → `session/prompt` → streamed turn →
    /// `session/request_permission` → closing `idle` transcript, captured
    /// from a live `InMemoryTransport` pair by `GoldenSessionEndToEndTests` —
    /// must validate against the schema.
    @Test func recordedFullSessionTranscriptValidatesAgainstTheSchema() throws {
        let validator = try Self.validator()
        let messages = try TestSupport.ndjsonObjects(
            atTreeRelativePath: "Tests/FoundationModelsACPTests/Fixtures/full-session-agent.ndjson"
        )
        #expect(!messages.isEmpty)
        for (index, message) in messages.enumerated() {
            let errors = validator.errors(validating: message)
            #expect(errors.isEmpty, "line \(index) failed schema validation:\n\(errors.joined(separator: "\n"))")
        }
    }

    // MARK: - Validator self-test
    //
    // A validator that never finds a violation would let every test above
    // pass for the wrong reason. These pin known-bad instances so a
    // regression in `JSONSchemaValidator` itself — not just in the library it
    // checks — fails loudly.

    @Test func validatorRejectsAResponseWithNeitherResultNorError() throws {
        let validator = try Self.validator()
        // A JSON-RPC response must carry `result` or `error`; this has
        // neither. Note what this test does *not* rely on: `result`'s own
        // shape is not a reliable place to force a rejection, because the
        // schema's `ExtMethodResponse` branch — ACP's `_ext` forward-
        // compatibility escape hatch (see `../../plan.md`'s "extension escape
        // hatch" and `VendoredSchemaTests.onlyTheDeliberatelyFreeFormDefinitionsStayUntyped`
        // in the unit suite) — declares no shape at all, so it matches any
        // `result` value whatsoever, including a bare number. That is a real,
        // deliberate property of the vendored schema, not a gap in this
        // validator: it means no `result` payload, however malformed, can by
        // itself make an `AgentResponse` schema-invalid. Omitting `result`
        // and `error` together is the one way to fail regardless.
        let broken: [String: Any] = ["jsonrpc": "2.0", "id": 1]
        #expect(!validator.errors(validating: broken).isEmpty)
    }

    @Test func validatorRejectsTheWrongJSONRPCVersion() throws {
        let validator = try Self.validator()
        let broken: [String: Any] = [
            "jsonrpc": "1.0",
            "id": 1,
            "method": "initialize",
            "params": ["protocolVersion": 2] as [String: Any],
        ]
        #expect(!validator.errors(validating: broken).isEmpty)
    }

    @Test func validatorRejectsAMessageMatchingNoKnownShape() throws {
        let validator = try Self.validator()
        let broken: [String: Any] = ["jsonrpc": "2.0", "id": 1, "totallyUnknownField": true]
        #expect(!validator.errors(validating: broken).isEmpty)
    }

    @Test func validatorAcceptsAMinimalValidNotification() throws {
        let validator = try Self.validator()
        let notification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "session/cancel",
            "params": ["sessionId": "test-session"] as [String: Any],
        ]
        #expect(validator.errors(validating: notification).isEmpty)
    }
}
