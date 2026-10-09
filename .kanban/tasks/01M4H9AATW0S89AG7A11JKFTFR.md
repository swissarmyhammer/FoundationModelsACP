---
assignees:
- claude-code
position_column: todo
position_ordinal: '8880'
title: Decide the answer to $/cancel_request for a pending session/request_permission
---
## Problem

Task ^qfa15v4 notes this in its Problem section, but its Work list does not ask for a change:

When the agent cancels its wait for a permission, the agent sends `$/cancel_request`. The connection cancels the dispatch task, and the `PendingPermissionRequests` handler task is cancelled too. When the `Client` handler then throws `CancellationError`, the reply is `-32800`, not the `cancelled` outcome.

## Decision needed

- Option A: keep `-32800`. This is the general JSON-RPC rule for `$/cancel_request`.
- Option B: answer the `cancelled` outcome for `session/request_permission` only.

A person must select the option. Then add tests for the selected behavior.

#acp-lifecycle