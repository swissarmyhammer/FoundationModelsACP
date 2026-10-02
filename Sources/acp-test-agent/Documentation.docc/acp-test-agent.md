# ``acp_test_agent``

@Metadata {
  @DisplayName("acp-test-agent")
}

A minimal Agent Client Protocol agent fixture used by the test suite. It speaks
ACP over stdio and answers the `initialize` handshake and the other session
lifecycle requests with fixed, deterministic responses, so integration tests
can exercise the transport layer without a real language model backend.

The one exception is `session/prompt`. The schema requires the response to name
the user message that the agent inserted. Thus the agent gives each prompt a
new `messageId`, returns it in the response, and echoes the prompt as a
`user_message` update with that same id.
