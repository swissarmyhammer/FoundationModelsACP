---
comments:
- actor: claude-code
  id: 01kyk67jqxtwrpda53p1288w2r
  text: |-
    Implementation landed. Summary:

    - New file Tests/FoundationModelsACPTests/PromptLifecycleTests.swift: a real test-double Agent (PromptLifecycleAgent) implementing the v2 prompt lifecycle end to end over InMemoryTransport — prompt() acknowledges with PromptResponse() (encodes to {}), then a deferred turn reports running, echoes the user's content as user_message_chunk updates sharing one agent-generated messageId, optionally pauses on requires_action and resumes to running once session/request_permission is answered, then reports idle with a stopReason. session/cancel cancels in-flight work and reports idle+cancelled. 8 tests cover every acceptance-criteria bullet and the full test list from the card, including a dedicated StopReason round-trip test (known values derived from the vendored schema, not hardcoded, plus the unknown-value sibling path nested inside IdleStateUpdate).

    - Real concurrency bug found and fixed (not hypothetical): a naive prompt() that spawns a Task to send the "running" state_update before returning PromptResponse() has a genuine race — under load (e.g. full test suite running in parallel) the update's wire frame sometimes gets written before the response frame, ~30-40% of full-suite runs in local stress testing. Caught by repeating swift test (not just the filtered new suite) many times, per the card's own warning about concurrency-heavy M3/M5 precedent.

    - Fix: added a small, deliberately-scoped mechanism to Sources/FoundationModelsACP/Connection/Connection.swift (ResponseHooks class + @TaskLocal static var currentResponseHooks) and Sources/FoundationModelsACP/Connection/AgentSideConnection.swift (public afterRespondingToCurrentRequest(_:)). Connection.dispatchRequest's per-request Task now runs any hooks the handler registered, but only AFTER completeInbound has written the response — making the ordering guarantee provable rather than probabilistic. PromptLifecycleAgent.prompt() uses this instead of spawning the turn's Task directly. This is a small, additive change to shared Connection/AgentSideConnection code (no signature changes to Agent/Client protocols, no change to ClientSideConnection behavior — hooks.runAll() is a no-op empty-array call for every other method).

    - Verified via 500-iteration wire-level ordering test (LoggingTransport wrapper classifying frames by content, not by racing client-side continuations against the update stream — an earlier version of this test using a client-observed race was itself flaky for reasons unrelated to the agent's actual wire order, documented in the test file's LoggingTransport doc comment) plus 25+ full `swift test` runs post-fix with zero failures (vs. reproducible failures pre-fix).

    Final state: swift build --build-tests clean (0 warnings, 0 errors). swift test: 185 tests / 15 suites (FoundationModelsACPTests) + 75 tests / 10 suites (ACPGenerateTests) = 260 tests / 25 suites, all passing, repeated ~30 times total across both filtered and full runs with no flakes observed after the fix. Baseline before this task was 252 tests / 24 suites, so +8 tests / +1 suite, matching the new PromptLifecycleTests suite.

    Adversarial double-check (via really-done) is running in background at time of this comment; will report its verdict once it lands.

    Task left in `doing` per /implement convention — ready for /review.
  timestamp: 2026-07-28T01:43:05.725755+00:00
- actor: claude-code
  id: 01kyk6z465y8kz0z2n2g60vrjt
  text: |-
    Adversarial double-check (via really-done) verdict: REVISE, with 2 findings. Both addressed:

    1. Real gap: Connection.dispatchRequest ran hooks.runAll() unconditionally even when completeInbound skipped writing the response (connection closed mid-handler), contradicting the documented "hooks follow a response that exists" contract. Fixed: completeInbound now returns a Bool (discardable for its other, pre-existing call site) indicating whether it actually wrote, and dispatchRequest only calls hooks.runAll() when it did.

    2. Real gap: LoggingTransport.classify(_:) in the test file classified any frame with a non-nil id as "response", which would misclassify an outbound agent request (e.g. session/request_permission, which also carries id+method) as a response. Currently inert (the ordering test's script never calls requestPermission) but a latent correctness trap for future reuse. Fixed: classify now requires method == nil for the "response" case, matching the same distinction Connection.owesResponse already uses in production code.

    A follow-up automated review pass (mcp__sah__review) then flagged a third item claiming the classifier's method-name check ("session/update") doesn't match what AgentSideConnection.sessionUpdate sends ("sessionUpdate") -- verified this is a false positive: MethodTable.generated.swift confirms the "sessionUpdate" handler's wireMethod is literally "session/update" (RoleDispatch resolves Swift handler names to wire method names via the routing table before writing), and this is empirically confirmed by the ordering test passing reliably across 500 iterations x 10+ full-suite reruns. No change made for that one; the fourth (a magic-number 3600 in Task.sleep) was legitimate and fixed with a named constant (indefiniteForegroundWorkDuration), mirroring the existing precedent in SessionLifecycleTests.swift's SessionManagingAgent.prompt.

    Final re-verification after all fixes: swift build --build-tests clean (0 warnings/errors from a full rm -rf .build). swift test run 10 additional times post-fix, all green (185 tests/15 suites + 75 tests/10 suites = 260 tests/25 suites each time). mcp__sah__diagnostics clean.

    Task remains in `doing`, ready for /review.
  timestamp: 2026-07-28T01:55:57.253390+00:00
depends_on:
- 01KYD58WV07Q982G94JHT1SH5G
position_column: doing
position_ordinal: '80'
title: 'M6 Prompt lifecycle: acknowledge, then report state'
---
## Starting point

**This is a rewrite** — see `plan.md` -> *Starting point*. Of all the milestones, this one has the **least** to salvage: the v1 prompt lifecycle is not a v2 prompt lifecycle with different types, it is a different design. The deleted v1 code held `session/prompt` open for an entire turn and resolved it with a `stopReason`; v2 acknowledges immediately and reports everything through `state_update`. Do not consult the v1 turn code for structure — it will actively mislead you. Its cancellation plumbing is the only part with any carryover.

## What

`plan.md` -> **M6**. The change with the largest blast radius for our agent.

**v1:** `session/prompt` stayed pending for the whole turn and resolved with `stopReason`.
**v2:** it returns **`{}` immediately** to acknowledge acceptance. *"The `session/prompt` response no longer ends the turn. It acknowledges acceptance. Foreground progress and completion arrive as `state_update` notifications, and the stop reason moved there too."*

`state_update` carries three states:

- **`running`** -- foreground work in progress.
- **`idle`** -- ready for the next prompt; carries **`stopReason`** when transitioning from working.
- **`requires_action`** -- foreground work **blocked waiting on the user**. This is a protocol-level state for exactly the permission / elicitation pause, which previously had no representation at all.

Also required: after accepting a prompt the agent must emit a `user_message` or streamed `user_message_chunk` updates carrying an **agent-generated `messageId`** -- the agent owns history, so it owns message identity.

**Cancellation:** `session/cancel` stays a notification, but confirmation now arrives as an `idle` `state_update` with `stopReason: "cancelled"` rather than in the prompt response.

## Acceptance Criteria

- [ ] `session/prompt` returns `{}` immediately, before any work completes.
- [ ] `state_update` emits `running`, `idle` (with `stopReason`), and `requires_action`.
- [ ] Accepting a prompt emits a `user_message` / chunks with an agent-generated `messageId`.
- [ ] `session/cancel` results in an idle state with `stopReason: "cancelled"`.
- [ ] `stopReason` values round-trip, unknown ones preserved.

## Tests

- [ ] The prompt response arrives before the first `state_update` -- assert ordering, since this is the entire semantic change.
- [ ] A full turn produces running -> idle with a `stopReason`.
- [ ] A blocked turn reports `requires_action`, then resumes to `running` once answered.
- [ ] Cancel mid-turn yields idle + `cancelled`.
- [ ] The acknowledged prompt's `messageId` is present and stable across its chunks.
