---
assignees:
- claude-code
position_column: todo
position_ordinal: '8680'
title: Use PendingPromptCorrelator in ClientSideConnection
---
## Problem

The spec says that clients must accept the `user_message` echo before or after the `session/prompt` response. `PendingPromptCorrelator` (`Session/PendingPromptCorrelator.swift:81-111`) does this, but `ClientSideConnection` does not use it. Each client must connect it.

## Work

1. In `ClientSideConnection`, correlate each `prompt` call with its echo through `PendingPromptCorrelator`.
2. Give the client one clear result: the `messageId` and the echoed message, in either arrival order.
3. Keep the current `prompt` API usable, or document the change.
4. Add tests for the two orders: the echo before the response, and the echo after the response.

## Acceptance

- The tests pass, and all other tests pass.

#acp-lifecycle