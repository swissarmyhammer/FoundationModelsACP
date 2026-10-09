---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4hc00s5zg8bn8p5h6040ffm
  text: |-
    Research done.
    - The read loop of `Connection` awaits each inbound notification inline. Thus `serveSessionUpdate` sees updates in wire order, and a hook there sees the echo at its wire position.
    - `PendingPromptCorrelator` keeps only message IDs, not the echo update. The connection must keep the first echo update of each early echo itself, while a prompt of the session waits for its response.
    - The `onClose` closure of `RoleConnectionCore` is synchronous. Thus the new state uses a `Mutex` in a final class, as `PendingPermissionRequests` and `OutgoingRequestTracker` do (not an actor).
    - Plan: keep `prompt(_:)` unchanged. Add a new public method `promptWithEcho(_:)` that returns `EchoedPromptResponse` (the response, the first echo update, the message ID, and the transcript entry ID). One correlator for each session in a new internal type `PendingPromptEchoes`. A failed request, a cancelled task, and a connection close each remove the pending prompt; a close makes a waiting call throw `ConnectionError.closed`.
    - Test support: move `responseEnvelope` and `sessionUpdateEnvelope` from `SessionUpdateStreamTests.swift` (private) to `WireTestSupport.swift`, and use `HandshakeClient`.
  timestamp: 2026-10-09T22:19:31.494001+00:00
- actor: claude-code
  id: 01m4hcc4qjm9kdvj9jg6nrvtmr
  text: |-
    Implementation landed (TDD: RED was a compile failure for the missing API, then GREEN).
    - New public API `ClientSideConnection.promptWithEcho(_:) -> EchoedPromptResponse`. `prompt(_:)` is not changed, so the current API stays source-compatible. `EchoedPromptResponse` has `response`, `echo` (the first `user_message` or `user_message_chunk` update), `messageId`, and `entryID`.
    - New internal type `PendingPromptEchoes` (Connection/). It keeps one `PendingPromptCorrelator<Int>` for each session, in a `Mutex`. The correlator keeps only message IDs, so this type also keeps the first update of each early echo, under the same condition as the correlator. A link at resolve time always has a kept update; the code states this invariant with `preconditionFailure`.
    - `serveSessionUpdate` gives each decoded update to the router first and then to `PendingPromptEchoes`. Thus the session streams have the echo before `promptWithEcho` returns it.
    - A failed request removes the prompt. A cancelled task throws `CancellationError`. A connection close throws `ConnectionError.closed` (through `onClose`). The wait for the echo has no time limit; `requestTimeout` applies to the request only.
    - `PendingPromptCorrelator`: added internal `isAwaitingResponse`, and made `SessionUpdate.userMessageId` internal (it was fileprivate). No public change.
    - Test support: moved `sessionUpdateEnvelope`, `responseEnvelope`, and `errorEnvelope` from `SessionUpdateStreamTests.swift` (private) to `WireTestSupport.swift`, which now uses `@testable import`. `ReplayTransportTests`, `OutgoingRequestEventTests`, and `PromptCancellationTests` still have their own inline copies; I did not change them.
    - Not changed: `insertUserMessage` and the `ResponseHooks` success-only hooks (task ^k82he4e).
  timestamp: 2026-10-09T22:26:08.754872+00:00
- actor: claude-code
  id: 01m4hcc632v70gacfr3tt0vtwj
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsACP/Connection/ClientSideConnection.swift, Sources/FoundationModelsACP/Connection/PendingPromptEchoes.swift (new), Sources/FoundationModelsACP/Connection/EchoedPromptResponse.swift (new), Sources/FoundationModelsACP/Session/PendingPromptCorrelator.swift, Tests/FoundationModelsACPTests/ClientPromptEchoTests.swift (new, 8 tests), Tests/FoundationModelsACPTests/WireTestSupport.swift, Tests/FoundationModelsACPTests/SessionUpdateStreamTests.swift. `swift build --build-tests`: 0 errors, 0 warnings. `swift test`: 482 tests in 50 suites and 135 tests in 17 suites passed, 0 failures.
    - next: /review
  timestamp: 2026-10-09T22:26:10.146550+00:00
- actor: claude-code
  id: 01m4hch335avsyakg0nnes4cb6
  text: |-
    ### test — green
    - evidence: swift test (root) 482 tests in 50 suites + 135 tests in 17 suites passed; IntegrationTests 7 passed; build with -warnings-as-errors clean; ClientPromptEchoTests + SessionUpdateStreamTests 5 runs, 33/33 passed each run.
    - next: commit, then review.
  timestamp: 2026-10-09T22:28:50.917626+00:00
position_column: doing
position_ordinal: '8180'
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