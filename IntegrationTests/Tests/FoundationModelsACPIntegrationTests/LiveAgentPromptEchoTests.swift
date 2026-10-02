import Testing

/// Drives the real `acp-test-agent` helper through one prompt and checks the
/// message identity rule of `schema-v2.0.0-alpha.5`: the `session/prompt`
/// response names the user message that the agent inserted, and the agent
/// echoes that message as a `user_message` update with the same `messageId`.
@Suite struct LiveAgentPromptEchoTests {
    @Test func thePromptEchoCarriesTheMessageIdThatThePromptResponseNames() async throws {
        let agent = try LiveAgentProcess()
        defer { Task { await agent.shutdown() } }

        _ = try await agent.request(
            id: 1,
            method: "initialize",
            params: ["protocolVersion": 2, "info": ["name": "acp-integration-test", "version": "0.0.0"] as [String: Any]]
        )
        let (_, newSession) = try await agent.request(id: 2, method: "session/new", params: ["cwd": "/tmp"])
        let sessionId = try #require((newSession["result"] as? [String: Any])?["sessionId"] as? String)

        let (_, promptResponse) = try await agent.request(
            id: 3,
            method: "session/prompt",
            params: ["sessionId": sessionId, "prompt": [["type": "text", "text": "hello"] as [String: Any]]]
        )
        let respondedId = try #require((promptResponse["result"] as? [String: Any])?["messageId"] as? String)

        let echo = try await agent.notification(method: "session/update")
        let params = try #require(echo["params"] as? [String: Any])
        let update = try #require(params["update"] as? [String: Any])
        #expect(params["sessionId"] as? String == sessionId)
        #expect(update["sessionUpdate"] as? String == "user_message")
        #expect(update["messageId"] as? String == respondedId)
        let content = try #require(update["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "hello")
    }
}
