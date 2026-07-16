---
assignees:
- claude-code
comments:
- actor: wballard
  id: 01kxnbts69xacp9t0xhgwyn63m
  text: 'Implemented: in oneLinerMatchesExplicitProvider, captured the concrete FoundationModelsAgent from the makeWiredBridge factory via a Mutex<FoundationModelsAgent?> (ReadmeExampleTests pattern), then enqueueScriptedTurn(for: first.sessionId) before the prompt call. Added `import FoundationModels` to SessionProviderTests.swift to name Transcript in the scripted-turn closure. Production one-liner API FoundationModelsAgent(connection:session:) still what is exercised. Fixed the stale makeModelSession doc in BridgeTestSupport.swift (was falsely claiming the bridge never drives a turn). Audited target: all other wire-prompt tests use stub agents (SpyAgent, ReversePromptAgent, raw wire) or already script turns (ReadmeExampleTests, EndToEndTests); PromptSerializationTests uses an unknown session (invalidParams, no model). SessionProviderTests now: all 3 tests pass, one-liner 0.013s (was ~2.1s), no outlier.'
  timestamp: 2026-07-16T11:43:44.841259+00:00
position_column: doing
position_ordinal: '80'
title: Remove live-model inference from oneLinerMatchesExplicitProvider (deterministic unit suite)
---
## What

`Tests/FoundationModelsACPTests/Bridge/SessionProviderTests.swift` — the test `oneLinerMatchesExplicitProvider` ends with a real prompt turn (`oneLiner.client.prompt(prompt)`) against a session from `makeModelSession()`, with no scripted turn enqueued. Since the real `streamTurn` landed, this drives a live `SystemLanguageModel` inference inside the plain unit-test target (~2.1s vs ~0.02s for every other test). It is nondeterministic and fails on machines without Apple Intelligence, contradicting the project's testing policy that live-model tests live behind availability gates in the `FoundationModelsACPEvals` target.

Fix by scripting the turn instead of driving the model:

- In `oneLinerMatchesExplicitProvider`, capture the concrete `FoundationModelsAgent` from the factory closure (the `capturedAgent.withLock { $0 }` pattern used in `Tests/FoundationModelsACPTests/ReadmeExampleTests.swift`, or switch the one-liner side to `makeWiredBridgeAgent`-style support in `Tests/FoundationModelsACPTests/Bridge/BridgeTestSupport.swift`), and call `enqueueScriptedTurn(for:)` (defined in `Sources/FoundationModelsACP/Bridge/FoundationModelsAgent.swift`) before the `prompt` call so the stop-reason assertion (`== .endTurn`) runs against a scripted transcript.
- Fix the stale doc comment on `makeModelSession` in `Tests/FoundationModelsACPTests/Bridge/BridgeTestSupport.swift` claiming "the bridge skeleton under test never drives a turn against the model" — false since the prompt-turn task landed.

Note `makeWiredBridge` returns only `(client, agentConnection)`; the one-liner init (`FoundationModelsAgent(connection:session:)`) must still be what's exercised — do not change the production API.

## Acceptance Criteria

- [ ] `oneLinerMatchesExplicitProvider` no longer performs live `SystemLanguageModel` inference: the prompt turn resolves from an enqueued scripted turn.
- [ ] `swift test --filter SessionProviderTests` passes with every test completing in well under 0.5s (no ~2s outlier).
- [ ] No test in the `FoundationModelsACPTests` target drives the live model (grep/audit: every `prompt(` over the wire in that target is preceded by `enqueueScriptedTurn`).
- [ ] The `makeModelSession` doc comment in `BridgeTestSupport.swift` accurately describes when the model session is (and is not) driven.

## Tests

- [ ] Update `oneLinerMatchesExplicitProvider` in `Tests/FoundationModelsACPTests/Bridge/SessionProviderTests.swift` to enqueue a scripted turn and keep asserting `stopReason == .endTurn`.
- [ ] `swift test --filter SessionProviderTests` → all pass, wall time confirms no inference.
- [ ] `swift test --skip FoundationModelsACPEvals` → full deterministic suite green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.