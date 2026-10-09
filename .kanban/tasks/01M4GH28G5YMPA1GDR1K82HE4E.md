---
assignees:
- claude-code
depends_on:
- 01M4GH23E1QC4SW735FQR92KN3
position_column: todo
position_ordinal: '8280'
title: Do not send the user_message echo when the prompt handler throws
---
## Problem

`AgentSideConnection.insertUserMessage` (`Connection/AgentSideConnection.swift:354-415`) schedules the `user_message` echo as deferred work (`:424-440`). If the prompt handler throws after this call, the client gets an error response and then the echo for a message that the agent did not accept. The doc comment at `:333-336` tells about this risk, but the behavior is incorrect.

## Work

1. When the handler result is an error, discard the scheduled echo (and other deferred work that `insertUserMessage` added).
2. Keep the order for success: the response first, then the echo.
3. Make this task agree with the -32800 task: after insertion, a cancellation gives success, not an error. Thus only a thrown error that is not a cancellation discards the echo.
4. Update the doc comment at `AgentSideConnection.swift:333-336`.
5. Add a test in `UserMessageInsertionTests`: a handler that calls `insertUserMessage` and then throws gives an error response and no `session/update` echo.

## Acceptance

- The new test passes, and all other tests pass.

#acp-lifecycle