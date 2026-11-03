---
assignees:
- claude-code
position_column: done
position_ordinal: c380
title: 'acp-test-agent: scripted nested sub-agent scenario (the reference script)'
---
Add a scripted scenario to acp-test-agent. The client, AgentViewKit and the integration tests can run it. It is the single reference script of correct agent behavior for nested sub-agent sessions.

Scenario: root, child, grandchild.
- subagent_update announcements, with _meta.sah.agentRun (toolCallId in the update, sessionId in the tool call).
- Child events under the child id. A child elicitation.
- Resume replay in the correct order: history before the response, current snapshots AFTER the response, and a state_update with the background list.
- A child that failed to restore: state unknown and SAH.RestoreFailure. Its descendants carry the failure too (reason: an ancestor was not restored).
- The final tool_call_update comes after the last child update. The child is then removed.

Selection: a launch argument of acp-test-agent. Tests run the real executable over stdio, read the all-sessions stream (subscribeToAllSessions) and assert the order. Use /tdd.