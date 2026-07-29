# ``acp_test_agent``

@Metadata {
  @DisplayName("acp-test-agent")
}

A minimal Agent Client Protocol agent fixture used by the test suite. It speaks
ACP over stdio and answers the `initialize` handshake and the other session
lifecycle requests with fixed, deterministic responses, so integration tests
can exercise the transport layer without a real language model backend.
