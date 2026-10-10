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
- actor: claude-code
  id: 01m4gr0n4p924n3pmb294zcrqz
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (commit 6181fe3). 1 finding (1 confirmed, 1 refuted). Sources/FoundationModelsACP/Connection/AgentSideConnection.swift:452 completeness/invariant-propagation.
    - next: Make the history record follow the same success-only rule as the user_message echo. Update the doc of insertUserMessage(_:messageId:into:). Add a test for .recordInHistory with a throw after insertion. Then do the review again.
  timestamp: 2026-10-09T16:30:20.822408+00:00
- actor: claude-code
  id: 01m4gr1276jvspd9tr03eqf60d
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — Connection.swift, AgentSideConnection.swift, UserMessageInsertionTests.swift, ResponseHooksTests.swift
    - test: green — swift test 451 + 135 passed; IntegrationTests 7 passed; 0 warnings
    - commit: 6181fe3
    - review: findings — Sources/FoundationModelsACP/Connection/AgentSideConnection.swift:452 (completeness/invariant-propagation)
  timestamp: 2026-10-09T16:30:34.214976+00:00
- actor: claude-code
  id: 01m4h7p81hx7yz57r4xnfg5rf1
  text: |-
    Blocker (finding at AgentSideConnection.swift, completeness/invariant-propagation):
    - `insertUserMessage(_:messageId:into:)` takes `into history: inout SessionMergeEngine`. An inout value is not reachable after the method returns. Thus the success-only hook cannot apply the echo to the history, and the method cannot remove the message after an error response.
    - To gate the history record on the response outcome, the public signature must change. This is a public API decision, so a person must choose:
      - A) `into history: @escaping @Sendable (SessionUpdate) -> Void`. The connection calls the closure in the success-only hook, before the echo.
      - B) A new public `final class` (for example `SessionHistory: Sendable`) that holds `Mutex<SessionMergeEngine>`, and `into history: SessionHistory`.
      - C) Another form.
    - With A or B, the history gets the message after the response is written, not before the method returns. The doc example `history.withLock { connection.insertUserMessage(params, into: &$0) }` changes.
    - No source edits were made. The task is in `doing`.
  timestamp: 2026-10-09T21:04:16.945883+00:00
- actor: claude-code
  id: 01m4h7pa9x61fcxvhb9nm2p6ns
  text: |-
    ### implement — stuck
    - evidence: no files changed. `insertUserMessage(_:messageId:into:)` takes `inout SessionMergeEngine`; the success-only hook cannot reach it after return. The fix needs a public signature change (option A closure, option B new history class, or C other). A person must choose.
    - next: the user picks A, B, or C; then run /implement again.
  timestamp: 2026-10-09T21:04:19.261453+00:00
- actor: claude-code
  id: 01m4h7pxf2z5q8r1n9k1e7t7a0
  text: |-
    ### finish iteration 2 — stuck
    - implement: stuck — no files changed. `insertUserMessage(_:messageId:into:)` takes `inout SessionMergeEngine`. The success-only work cannot get to that value after the method returns. To fix the finding at AgentSideConnection.swift:452, the public signature must change. A person must choose: (A) an `@escaping @Sendable (SessionUpdate) -> Void` parameter, (B) a new `SessionHistory: Sendable` class that holds `Mutex<SessionMergeEngine>`, or (C) another form.
    - next: wait for the user decision, then run /implement again.
  timestamp: 2026-10-09T21:04:38.882727+00:00
- actor: claude-code
  id: 01m4jazh6rcy7bpywsn9wwg2fg
  text: |-
    ### decision — option A
    The user selected option A: change the parameter to `into history: @escaping @Sendable (SessionUpdate) -> Void`. The connection calls the closure in the success-only work, after the response and before the echo. Update the doc comments and the doc example. Add the `.recordInHistory` test that throws after insertion and expects an empty history.
  timestamp: 2026-10-10T07:21:01.400144+00:00
- actor: claude-code
  id: 01m4jb2swddzbz00hdb7md2fjp
  text: |-
    Research for option A:
    - `ResponseHooks.runAll(responseSucceeded:)` runs the success-only entries in registration order after the response is written. When the connection writes no response, `discardAll()` releases them. Thus with option A, the history gets the message only after a success response, and never when no response is written.
    - Plan: `insert(_:messageId:recording:)` takes an `@escaping @Sendable (SessionUpdate) -> Void`. `acceptPrompt` calls it in the success-only work, before `sessionUpdate(echo)`. The overload without history passes a closure that does nothing.
    - Outside a request handler, the history also does not get the message (before, it did).
    - The test `theEchoEntersTheHistoryWithTheMessageIdThatTheResponseNames` must wait for the echo before it reads the history, because the history now gets the message after the response.
    - The ordering test uses a transport wrapper that records, for each written frame, its kind and the number of history entries. Expected: response with 0 entries, then the echo with 1 entry.
  timestamp: 2026-10-10T07:22:48.589947+00:00
- actor: claude-code
  id: 01m4jb97373zncmqs2dvs4dtbw
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsACP/Connection/AgentSideConnection.swift, Tests/FoundationModelsACPTests/UserMessageInsertionTests.swift, Tests/FoundationModelsACPTests/WireOrderTestSupport.swift. `insertUserMessage(_:messageId:into:)` now takes `into history: @escaping @Sendable (SessionUpdate) -> Void`. The success-only work calls it after the response and before the echo. RED (old API): `aHandlerThatThrowsAfterTheInsertionLeavesTheHistoryEmpty` failed (entryCount 1), `theHistoryGetsTheMessageAfterTheResponseAndBeforeTheEcho` failed (response frame saw 1 entry). GREEN: both pass. Full `swift test`: 486 tests in 51 suites and 135 tests in 17 suites pass, 0 warnings. Finding flipped to [x].
    - notes: The doc example uses `history.withLock { _ = $0.apply(update) }`. The form without `_ =` gives the warning "result of call to 'withLock' is unused", because `apply` returns `Change`. `LoggingTransport.classify(_:)` is now internal so that the new `HistoryProbeTransport` can use it. The existing test `theEchoEntersTheHistoryWithTheMessageIdThatTheResponseNames` now waits for the echo before it reads the history. Outside a request handler, the history does not get the message now. IntegrationTests were not run (no caller of `insertUserMessage` there).
    - next: /review
  timestamp: 2026-10-10T07:26:18.727131+00:00
- actor: claude-code
  id: 01m4jbcj8wr7cs3ztvgdtaej73
  text: |-
    ### test — green
    - evidence: swift test (root) 486 tests in 51 suites + 135 tests in 17 suites passed; IntegrationTests 7 passed; forced recompile 0 warnings; UserMessageInsertionTests + ResponseHooksTests + PromptCancellationTests 5 runs, 28/28 passed each run.
    - next: commit, then review.
  timestamp: 2026-10-10T07:28:08.476094+00:00
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

## Review Findings (2026-10-09 11:09)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Sources/FoundationModelsACP/Connection/AgentSideConnection.swift:452` `completeness/invariant-propagation` — The success-only gate covers only the user_message echo. The history record at line 423 still runs unconditionally, before the handler's error is known. When a handler calls insertUserMessage(_:messageId:into:) and then throws, the retained history keeps the user message, but the client gets an error response and no echo. The client and the history now disagree. Before this change, the echo went out on error, so both sides agreed. Move the history record into the success-only work, or otherwise gate it on the response outcome, so the history and the echo follow the same rule. Update the doc of `insertUserMessage(_:messageId:into:)` to say what happens to the history on an error response. Add a test for `.recordInHistory` with a throw after insertion that asserts the history is empty.
