---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4hag2sbmdabjena540s3xyq
  text: |-
    Research and implementation notes:
    - `ClientSideConnection.serveNotification` used `try? JSONValue.decodeParams(...)`. `decodeParams` changes every decode failure to `RequestError.invalidParams`, so the cause was lost. I added `JSONValue.decodeParamsKeepingCause` in `RoleDispatch.swift`, and `decodeParams` now calls it. The connection logs the real `DecodingError` (with its coding path, for example `toolCallId`).
    - The session ID lookup from raw params was a private helper in `OutgoingRequestTracker`. I moved it to a shared `SessionId.init?(namedIn:)` in `RoleDispatch.swift` and the tracker now calls it. There is one copy, not two.
    - The `session/update` path is now `serveSessionUpdate`. On a decode failure it writes one warning with the prefix `ClientSideConnection: `, the wire method (from `RoleRouting.wireMethod`), the `sessionId` and the `sessionUpdate` discriminator (or `<absent>`), and the error. Then it returns, and the read loop continues.
    - The connection reads notifications in wire order. Thus the test reads the log after the next good update arrives, with no sleep.
    - The test is in `SessionUpdateStreamTests.swift` and uses the existing `LogCapture` and `MinimalClient`. I added `sessionUpdateEnvelope(params:)` for raw params, and the typed `sessionUpdateEnvelope(_:)` now calls it.
    - RED: 0 warnings (the later update arrived). GREEN: 1 warning that names the session, `tool_call_update` and `toolCallId`.
    - I did not change `insertUserMessage` or the `ResponseHooks` success-only hooks (^k82he4e).
    - New work found: `elicitation/complete` (client) and `session/cancel` (agent) also drop an undecodable payload with no log. I recorded this as ^gvkq93c.
  timestamp: 2026-10-09T21:53:20.683256+00:00
- actor: claude-code
  id: 01m4hag4xfe2c9cn3zj6390gmc
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsACP/Connection/ClientSideConnection.swift, Sources/FoundationModelsACP/Connection/RoleDispatch.swift, Sources/FoundationModelsACP/Connection/OutgoingRequestTracker.swift, Tests/FoundationModelsACPTests/SessionUpdateStreamTests.swift. `swift test`: 463 tests in 47 suites passed, 135 tests in 17 suites passed, 0 failures, 0 warnings.
    - next: /review
  timestamp: 2026-10-09T21:53:22.863870+00:00
- actor: claude-code
  id: 01m4hajsxxxntf1vkhg9y5nf62
  text: |-
    ### test — green
    - evidence: swift test (root) 463 tests in 47 suites + 135 tests in 17 suites passed; IntegrationTests 7 passed; 0 warnings; SessionUpdateStreamTests 5 runs, 25/25 passed each run.
    - next: commit, then review.
  timestamp: 2026-10-09T21:54:49.917584+00:00
position_column: doing
position_ordinal: '8180'
title: Log a known session/update variant whose payload does not decode
---
## Problem

Unknown `session/update` variants are kept as raw data. But if the payload of a known variant is malformed, the decode of the full notification fails. `ClientSideConnection` then drops it and writes no log (`Connection/ClientSideConnection.swift:214-218`). A schema difference with a peer is then not visible.

## Work

1. When a `session/update` notification does not decode, write a warning to the connection logger. Include the session id (if it decodes), the `sessionUpdate` discriminator, and the decoding error.
2. Do not stop the connection.
3. Add a test: a `tool_call_update` with a bad field type gives one warning, and later updates still arrive.

## Acceptance

- The test passes, and all other tests pass.

#acp-lifecycle