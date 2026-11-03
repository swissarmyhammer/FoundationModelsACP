---
assignees:
- claude-code
position_column: done
position_ordinal: c580
title: 'SubagentWireTraceValidator: conformance validator for sub-agent wire traces'
---
A public type in the wire package that other packages use as the test oracle. It takes a recorded ordered trace of one connection (session updates with the session id, agent requests with their session id, the resume request and its response). It returns a list of violations, each with the rule and the position in the trace.

Rules: (1) resume order: replay, pre-response updates of listed background items, ONE current state_update, session_info_update, the response. (2) No historical state_update replayed as current. (3) A child is announced by subagent_update before any update or request that carries its id, and the parent before the child. (4) Current child snapshots only after the response; a snapshot before the response authorizes nothing. (5) All child history before the response. (6) Replay never reissues permission or elicitation requests. (7) _meta.sah is never sent partially. (8) The final tool_call_update of an agents call comes after the last update and the final state of its child. (9) background is present on every state_update of a session that reported it once; a listed item is announced before the snapshot that lists it and finalized before the snapshot that drops it. (10) A failed child is announced with no state, SAH.RestoreFailure and no capabilities, and so are its descendants.

Tests: the nested scenario of acp-test-agent passes; one mutated trace per rule fails with the right rule. Add it to the acp-test-agent docs. /tdd, review, commit, push, message the coordinator with the public API.