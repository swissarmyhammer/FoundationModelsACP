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

## The nested sub-agent scenario

Start the agent with `--scenario nested-subagents` to make it play a fixed
script when the client resumes a session. The script is the reference for the
correct behavior of an agent that has sub-agent sessions. The client, the
AgentViewKit views, and the integration tests run it.

The script has a root session, two children, and one grandchild for each child.
One child restored. The other child failed to restore.

The order on the wire follows the "Ordering" rule of ACP v2 "Session Setup":

1. The history (the replay). Each update is history, and it confirms nothing
   about the state now.
2. A `subagent_update` for each child that the root lists in `background`. It
   comes before the snapshot that lists the child. The client treats it as
   unconfirmed, because a child snapshot before the response is historical.
3. The current `state_update` of the root, with the background list of the two
   children.
4. A `session_info_update`.
5. The `session/resume` response.
6. The current snapshots, after the response. A `subagent_update` replaces the
   state of its child. When it has no `state`, the state is unknown. The child
   that failed to restore, and its grandchild, have no state. Each carries the
   `restoreFailure` object in `_meta.sah`.
7. An elicitation for the child that restored. The agent waits for the answer.
8. The finish. The grandchild and then the child report `idle`. The last update
   is the final `tool_call_update` of the tool call that started the child. A
   client removes the child at that update.

Every announcement of a child is a `subagent_update` in the stream of its
parent, with `_meta.sah.agentRun.toolCallId`. The tool call that started the
child carries `_meta.sah.agentRun.sessionId`.

## Check a trace with the validator

The `SubagentWireTraceValidator` type of the `FoundationModelsACP` library is
the test oracle for sub-agent traces. Record the messages of a connection in
wire order as `WireTraceEvent` values: the `session/resume` request, the
updates (a `SequencedSessionEvent` of `subscribeToAllSessions()` converts with
`WireTraceEvent(_:)`), the requests of the agent, and the response. Then call
`validate(_:)`. The result is a list of violations. Each one has the rule (1 to
10) and the position in the trace. The trace of this scenario has no
violations, and the tests break it once for each rule.

## The conformant scenario

`--scenario conformant` makes the agent follow the rules that `acp-conformance`
checks. A turn sends `running`, a message, and a final `idle`. A prompt that
contains "until cancelled" holds the turn, and `session/cancel` ends it with
`idle` and the stop reason `cancelled`. A resume sends the history when the
request has `replayFrom`, then one current `state_update`, then a
`session_info_update`, and then the response. The flag can repeat, so
`--scenario conformant --scenario nested-subagents` passes all checks of the
runner, with a script for the nested resume.
