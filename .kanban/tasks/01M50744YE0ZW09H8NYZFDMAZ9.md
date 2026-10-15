---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m507cdevqdgycccwh1e18tmy
  text: |-
    ### test — green
    - evidence: one full run of `swift test`, exit 0. FoundationModelsACPTests: 494 tests in 53 suites passed. ACPGenerateTests: 135 tests in 17 suites passed. NewSessionResponseHookTests: 5 of 5 passed. The build has no warnings.
    - next: commit, push to main, report the head commit and the CI result to the requester.
  timestamp: 2026-10-15T16:47:31.291623+00:00
position_column: doing
position_ordinal: '80'
title: Add a reader hook that runs when a newSession response is decoded
---
Requested by FoundationModelsACPClient (its card ^hfby9sz).

Problem: ACPClient's ConnectionModel registers a new session model only after `ClientSideConnection.newSession(_:)` returns. The reader decodes frames in order. It resolves the newSession response. Then it can dispatch the next frame, an agent request for that new session (elicitation/create or session/request_permission), before the continuation of newSession runs on the MainActor. ACPClient then finds no session and answers cancel.

Need: a synchronous hook that runs on the reader, in frame order, when the reader decodes the response of a newSession call. The hook gets the new session id. It must run before the reader dispatches the next frame. The hook belongs to one call, so that ACPClient can tell its own call from a different concurrent newSession call (for example `newSession(_:onResponse:)`).

Rules:
- Additive API only. Callers that do not use the hook see no change in behavior.
- Add a fixed-order test. It must prove that the hook runs before the reader dispatches the next frame. Do not use a clock, sleep, poll, retry or time limit.
- Send a design to the requester and get acceptance before code.
- Push when all tests pass. Report the head commit and the CI result.

#defect