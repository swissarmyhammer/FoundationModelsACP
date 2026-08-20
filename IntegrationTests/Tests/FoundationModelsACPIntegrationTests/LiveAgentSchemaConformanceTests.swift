import Testing

/// Drives the real `acp-test-agent` helper as a child process and validates
/// every raw JSON-RPC line that actually crosses the pipe — both directions —
/// against the vendored `Schema/acp-v2.json` document.
///
/// This complements `SchemaConformanceTests`'s replay of the recorded
/// `full-session-agent.ndjson` transcript: that fixture never drives
/// `session/list`, `session/resume`, `session/close`, or an unimplemented
/// method's error response, all of which `TestAgent`
/// (`../../Sources/acp-test-agent/main.swift`) answers for real here.
@Suite struct LiveAgentSchemaConformanceTests {
    private static func validator() throws -> JSONSchemaValidator {
        let document = try TestSupport.jsonObject(atTreeRelativePath: "Schema/acp-v2.json")
        guard let object = document as? [String: Any] else {
            Issue.record("Schema/acp-v2.json did not decode to a JSON object")
            throw TimedOutError()  // unreachable; satisfies the return type
        }
        return try JSONSchemaValidator(schemaDocument: object)
    }

    @Test func realAgentTrafficAcrossTheStableMethodsValidatesAgainstTheSchema() async throws {
        let validator = try Self.validator()
        let agent = try LiveAgentProcess()
        defer { Task { await agent.shutdown() } }

        var everyMessage: [(label: String, message: [String: Any])] = []

        func call(_ label: String, id: Int, method: String, params: [String: Any]) async throws -> [String: Any] {
            let (sent, received) = try await agent.request(id: id, method: method, params: params)
            everyMessage.append((label: "\(label) request", message: sent))
            everyMessage.append((label: "\(label) response", message: received))
            return received
        }

        _ = try await call(
            "initialize",
            id: 1,
            method: "initialize",
            params: ["protocolVersion": 2, "info": ["name": "acp-integration-test", "version": "0.0.0"] as [String: Any]]
        )
        let newSession = try await call("session/new", id: 2, method: "session/new", params: ["cwd": "/tmp"])
        let sessionId = (newSession["result"] as? [String: Any])?["sessionId"] as? String ?? "test-session"

        _ = try await call("session/list", id: 3, method: "session/list", params: [:])
        _ = try await call(
            "session/resume",
            id: 4,
            method: "session/resume",
            params: ["sessionId": sessionId, "cwd": "/tmp"]
        )
        _ = try await call(
            "session/prompt",
            id: 5,
            method: "session/prompt",
            params: [
                "sessionId": sessionId,
                "prompt": [["type": "text", "text": "hello"] as [String: Any]],
            ]
        )
        // `session/delete` has no override in `TestAgent`, so `Agent`'s
        // default throws `RequestError.methodNotFound` — a real JSON-RPC
        // error response, exercising the error branch of the schema's
        // response shape, not just the success branch every other call here
        // covers.
        let deleteResult = try await call(
            "session/delete",
            id: 6,
            method: "session/delete",
            params: ["sessionId": sessionId]
        )
        #expect(deleteResult["error"] != nil, "session/delete is unimplemented and must answer with a JSON-RPC error")

        _ = try await call("session/close", id: 7, method: "session/close", params: ["sessionId": sessionId])

        let cancelNotification = try agent.notify(method: "session/cancel", params: ["sessionId": sessionId])
        everyMessage.append((label: "session/cancel notification", message: cancelNotification))

        #expect(everyMessage.count == 15)
        for (label, message) in everyMessage {
            let errors = validator.errors(validating: message)
            #expect(errors.isEmpty, "\(label) failed schema validation:\n\(errors.joined(separator: "\n"))")
        }
    }
}
