---
depends_on:
- 01KXHBDAK0NQ5RA2NWTF1ESXQP
- 01KXHBC7FYJYRM3VNBPR4FM4NJ
position_column: todo
position_ordinal: 8f80
title: 'Bridge prompt turn: Transcript → session/update mapping, StopReason, cancel'
---
## What
Implement the heart of the bridge (spec §7): a `session/prompt` drives `session.streamResponse(to:)`; the long-lived request stays open for the whole turn while the bridge fires notifications off the growing FoundationModels `Transcript`.

**Input direction — PromptRequest → FM prompt:** map the incoming `PromptRequest`'s `[ContentBlock]` into the `streamResponse(to:)` argument: text blocks concatenate into the prompt; `resource`/`resourceLink` (embedded context) render per FM prompt conventions; `image`/`audio` map to FM multimodal input where supported. Blocks of a type the bridge did NOT advertise in its `initialize` `PromptCapabilities` are rejected with a JSON-RPC invalid-params error (-32602), not silently dropped (spec §2: capability-gated content).

**Output direction — Transcript → session/update:**
- `.response` text segments → `agent_message_chunk`
- reasoning → `agent_thought_chunk` — resolve the §10 open question during implementation: if WWDC 2026 FM exposes a first-class thought stream, map it directly; otherwise synthesize from the `.structure` reasoning segment. Document which path was taken.
- `.toolCalls` → `tool_call` (status `pending`/`in_progress`) then `tool_call_update` as it runs → `completed`/`failed`, paired with the following `.toolOutput`; correlate by `toolCallId` through the `pending → in_progress → completed/failed` lifecycle
- a `.structure` segment / Dynamic-Profile plan → `plan`

**Turn end and cancellation:**
- Answer the prompt request with the right `StopReason` (`.endTurn`, `.maxTokens`, `.refusal`, `.cancelled`)
- `cancel` (ACP notification) maps to FM session cancellation; the turn still terminates through the prompt response with `StopReason.cancelled`, possibly after final updates land (spec §5)
- Invoke `provider.onTurnEnded(sessionId, transcript)` with the final Transcript when a turn completes; absence changes nothing

This mapping is the exact inverse of AgentViewKit's (spec §7) — a turn must round-trip FM → ACP → FM losslessly.

Testing note: drive the mapping through a seam that feeds scripted Transcript entries (recorded from a real run once) so protocol-layer assertions are deterministic; a live-`SystemLanguageModel` smoke test can be tagged `.enabled(if:)` for local/CI-on-Apple-Silicon runs.

## Acceptance Criteria
- [ ] A multi-block `PromptRequest` (text + embedded resource) maps into the FM prompt; an unadvertised block type (e.g. audio when `PromptCapabilities.audio` is off) answers -32602 invalid params
- [ ] A scripted turn with text + reasoning + two tool calls emits the exact expected `session/update` sequence (golden fixture), including tool_call/tool_call_update pairing by toolCallId
- [ ] Prompt response arrives only at turn end with the correct `StopReason` for each of: normal end, max tokens, refusal, cancel
- [ ] Cancel mid-turn stops FM generation and yields trailing updates then `StopReason.cancelled`
- [ ] `onTurnEnded` receives the final Transcript exactly once per turn; nil hook is a no-op

## Tests
- [ ] `Tests/FoundationModelsACPTests/Bridge/PromptInputMappingTests.swift` — multi-block ContentBlock → FM prompt mapping; unadvertised-capability rejection
- [ ] `Tests/FoundationModelsACPTests/Bridge/TranscriptMappingTests.swift` — golden-fixture assertion of update sequences from scripted transcripts
- [ ] `Tests/FoundationModelsACPTests/Bridge/StopReasonTests.swift` — all four stop reasons; cancel timing
- [ ] `Tests/FoundationModelsACPTests/Bridge/OnTurnEndedTests.swift` — hook invocation semantics
- [ ] Run `swift test` — exits 0

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.