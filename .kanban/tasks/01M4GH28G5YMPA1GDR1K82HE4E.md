---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4gpn0c6cfjvqjbcbqygyqc0
  text: |-
    Research and design:
    - `insertUserMessage` registers the echo through `ResponseHooks`. Before this change, `dispatchRequest` ran all hooks after each written response, also after an error response.
    - `ResponseHooks.settle(_:)` (from ^qr92kn3) changes a `-32800` outcome to the accepted success result before the hooks run. Thus the decision "success or error" uses the settled outcome, and a cancellation after the insertion still sends the echo.
    - Design: each hook entry has a `needsSuccess` flag. `appendSuccessOnly(_:)` registers such an entry. `runAll(responseSucceeded:)` takes the entries in one lock and does not run the success-only entries after an error response. The decision and the take occur in one step, so a late registration cannot pass between them.
    - The echo was the only caller of `ResponseHooks.append(_:)` (the form without `onDiscard`). The echo now uses `appendSuccessOnly(_:)`, so I removed the unused form.
    - Other deferred work (from `afterRespondingToCurrentRequest`) still runs after an error response. The task scope is only the work that `insertUserMessage` adds.
    - Note: the `files` tool `replace_all` flag made one replacement only in this session. I did each edit one at a time.
  timestamp: 2026-10-09T16:06:30.534776+00:00
- actor: claude-code
  id: 01m4gpn2zscmhnpmbxq815scj6
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsACP/Connection/Connection.swift, Sources/FoundationModelsACP/Connection/AgentSideConnection.swift, Tests/FoundationModelsACPTests/UserMessageInsertionTests.swift, Tests/FoundationModelsACPTests/ResponseHooksTests.swift. RED: `aHandlerThatThrowsAfterTheInsertionGivesAnErrorAndNoEcho` failed (the echo frame came after the error response). GREEN: that test and 2 new ResponseHooks unit tests pass. Full `swift test`: 451 tests in 45 suites and 135 tests in 17 suites pass, 0 warnings.
    - next: /review
  timestamp: 2026-10-09T16:06:33.209879+00:00
- actor: claude-code
  id: 01m4gpsze6v6yyma19kf6zdtj4
  text: |-
    ### test — green
    - evidence: swift test (root) 451 tests in 45 suites + 135 tests in 17 suites passed; IntegrationTests 7 passed; forced rebuild 0 warnings; UserMessageInsertionTests, ResponseHooksTests, PromptCancellationTests 5 runs each, all passed.
    - next: commit, then review.
  timestamp: 2026-10-09T16:09:13.414303+00:00
depends_on:
- 01M4GH23E1QC4SW735FQR92KN3
position_column: doing
position_ordinal: '80'
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