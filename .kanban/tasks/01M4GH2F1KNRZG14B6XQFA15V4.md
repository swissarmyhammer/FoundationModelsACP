---
assignees:
- claude-code
position_column: todo
position_ordinal: '8380'
title: Add a client cancel helper that answers pending permission requests with cancelled
---
## Problem

The spec says that when the client sends `session/cancel`:

- The client MUST answer each pending `session/request_permission` with the `cancelled` outcome.
- The client SHOULD mark unfinished tool calls of the active work as `cancelled` immediately.

Now, `ClientSideConnection.sessionCancel` only sends the notification (`Connection/ClientSideConnection.swift:324-326`). Nothing records the pending inbound `session/request_permission` calls for each session. Nothing marks tool calls as cancelled. The MUST rule is only in generated doc text (`Generated/Unions2.generated.swift:130-132`).

Also: when the agent cancels its wait for a permission, the agent sends `$/cancel_request`. If the client handler then throws `CancellationError`, the reply is `-32800`, not the `cancelled` outcome.

## Work

1. In `ClientSideConnection`, record each pending inbound `session/request_permission` by its `sessionId`.
2. When `sessionCancel` runs, answer each pending permission request of that session with the `cancelled` outcome. Do not wait for the `Client` handler. Ignore the late handler result.
3. Add a `SessionMergeEngine` operation that sets each tool call of the session that is not in a terminal status to `cancelled`. Document how a client calls it after `sessionCancel`.
4. Updates that arrive after the cancel must still apply (this works now; keep a test for it).
5. Add tests for steps 2 and 3, and for a permission request that arrives after the cancel.

## Acceptance

- The tests pass, and all other tests pass.

#acp-lifecycle