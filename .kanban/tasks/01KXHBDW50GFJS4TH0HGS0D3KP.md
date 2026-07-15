---
comments:
- actor: wballard
  id: 01kxkjvdk95g85y7ggydx3pt4f
  text: |-
    Picked up. Probed FM's REAL Transcript API via swift-symbolgraph-extract against the Xcode-beta SDK (arm64-apple-macosx27) — NOT invented. Key discoveries vs the card's illustrative names:

    RESOLVED §10 REASONING QUESTION: `Transcript.Entry` has a FIRST-CLASS `.reasoning(Transcript.Reasoning)` case (alongside .instructions/.prompt/.toolCalls/.toolOutput/.response). So the bridge maps reasoning DIRECTLY from `.reasoning` entries — no synthesis from a `.structure` segment needed. `Transcript.Reasoning` = { id, segments:[Segment], signature:Data?, metadata }.

    Verified-real shapes (all constructible — public inits):
    - `Transcript.Entry`: enum { instructions, prompt, toolCalls, toolOutput, response, reasoning } — needs @unknown default (resilient).
    - `Transcript.Segment`: enum { text(TextSegment), structure(StructuredSegment), attachment(AttachmentSegment), custom(any CustomSegment) }.
    - `TextSegment{ id, content:String }`; `StructuredSegment{ id, source:String, schemaName:String, content:GeneratedContent }`.
    - `Response{ id, assetIDs, segments:[Segment] }`; `Reasoning{ segments:[Segment] }`.
    - `ToolCall{ id:String, toolName:String, arguments:GeneratedContent }`; `ToolCalls` = Collection<ToolCall> (one entry can carry several calls); `ToolOutput{ id:String, toolName:String, segments:[Segment] }`. Correlation is by id (ToolOutput.id == the ToolCall.id it answers).
    - `GeneratedContent`: `init(json:String)` + `.jsonString` — the bridge round-trips tool args/structured content as JSON via JSONValue.

    STREAMING + CANCEL (critical):
    - `session.streamResponse(to: String) -> ResponseStream<String>`. Each streamed `Snapshot` carries `.transcriptEntries: ArraySlice<Transcript.Entry>` — THE turn's growing entries. That is the mapping source (not session.transcript, which would include prior turns and cause the per-turn mapper to re-emit).
    - There is NO `session.cancel()`. Cancellation is via Swift structured concurrency: cancel the Task iterating the ResponseStream → iteration throws CancellationError → FM stops. So the bridge stores the active generation Task per session and cancel() cancels it.
    - StopReason signals: normal end → .endTurn; `LanguageModelSession.GenerationError.exceededContextWindowSize` → .maxTokens; `.refusal`/`.guardrailViolation` → .refusal; Task cancellation → .cancelled.

    DESIGN (next): new `Bridge/TranscriptMapper.swift` = pure, stateful (consumedCount + tool correlation) seam `consume([Transcript.Entry]) -> [SessionUpdate]` — the SCRIPTED-entry seam the card mandates (golden tests feed it directly; no live model, no SIGTRAP). Agent gets internal `runTurn(for:generate:)` taking a `TurnGenerator` seam (`(deliver) async throws -> Transcript`) — production impl drives streamResponse + snapshot.transcriptEntries; tests supply scripted deliver batches + a terminal outcome, and observe emitted updates through a real wired ClientSideConnection.updates(for:). This is NOT a fake LanguageModelSession / engine protocol (§7.1-forbidden) — it is the internal turn-driver seam the card asks for. Prompt caps advertised: text+resourceLink baseline, embeddedContext=true; image/audio=false → unadvertised image/audio blocks answer -32602 before any streaming.
  timestamp: 2026-07-15T19:07:56.905106+00:00
- actor: wballard
  id: 01kxkkn6zm50zmrysmn5z8qttp
  text: |-
    Implementation landed (green). Files:
    - NEW Sources/.../Bridge/TranscriptMapper.swift — pure, stateful `consume([Transcript.Entry]) -> [SessionUpdate]` seam (consumedCount dedup for growing transcripts). Mapping: .response .text→agent_message_chunk; .reasoning .text→agent_thought_chunk (FIRST-CLASS .reasoning entry, no synthesis); .toolCalls→tool_call(status .pending, rawInput=args JSON via GeneratedContent.jsonString→JSONValue); .toolOutput→tool_call_update(status .completed, content from output segments) correlated by shared id; a `.structure` segment in a response whose schemaName/source contains "plan" and decodes as an ACP Plan→plan; .instructions/.prompt→[] (input, not output); attachment/custom segments→skipped.
    - NEW Sources/.../Bridge/PromptInputMapper.swift — `render([ContentBlock], PromptCapabilities) -> String`. Data-driven capability gate: text+resource_link baseline; resource↔embeddedContext; image↔image; audio↔audio; unknown→reject. Any unadvertised block → RequestError code -32602 (with a `reason` in data) BEFORE any streaming. Renders text verbatim, resourceLink as "[resource: name](uri)", embedded text resource inline.
    - Sources/.../Bridge/FoundationModelsAgent.swift — real `prompt`: renders/validates input (may throw -32602), then serializeTurn → `runTurn(for:generate:)`. `runTurn` runs the generator as a registered `Task<Transcript, any Error>` (stored per-session as activeGeneration, created+stored with no await between → cancel can't miss it), feeds delivered entries through TranscriptMapper → connection.sessionUpdate, derives StopReason, then invokes provider.onTurnEnded(sessionId, finalTranscript). `cancel(_:)` cancels activeGeneration (FM has NO session.cancel — cancellation flows through Task cancellation into the ResponseStream iteration). Production generator `streamTurn` iterates session.streamResponse(to:), delivering snapshot.transcriptEntries.dropLast() as entries settle then the whole turn at stream end, and returns session.transcript for onTurnEnded. initialize now advertises promptCapabilities (embeddedContext=true, image/audio=false).

    STOPREASON — CORRECTNESS FIX vs the card's illustrative names: `LanguageModelSession.GenerationError` is DEPRECATED in macOS 27; the real thrown type is `LanguageModelError`. `stopReason(error:cancelled:)` matches `LanguageModelError`: .contextSizeExceeded→.maxTokens; .refusal/.guardrailViolation→.refusal; CancellationError or cancelled flag→.cancelled; nil→.endTurn; anything else propagates. cancelled wins over any error (so a cancel that surfaced as CancellationError still answers .cancelled).

    TESTING SEAM (no fake LanguageModelSession, no engine protocol — §7.1 honored): the internal `TurnGenerator` seam (`(deliver) async throws -> Transcript`) lets tests script transcript-entry batches + terminal outcome and observe emitted updates through a REAL wired ClientSideConnection.updates(for:). No concurrent real turns → no SIGTRAP. Cancellation resilience of trailing updates verified: InMemoryTransport.write uses a non-suspending yield that ignores task cancellation, so updates delivered after cancel still land.

    Tests (all deterministic): TranscriptMappingTests (golden text+reasoning+2-tool-call sequence; id correlation; input entries→nothing; plan segment→plan; growing-transcript dedup), PromptInputMappingTests (multi-block render; -32602 for audio/image/unknown/embedded-off), StopReasonTests (pure fn for all 4 + CancellationError + unexpected-propagates; e2e endTurn with delivery, refusal, maxTokens, and cancel-mid-turn→trailing-update-then-cancelled), OnTurnEndedTests (final transcript received once; nil hook no-op).

    VERIFICATION: swift build --build-tests 0 warnings/0 errors. swift test = 137 FoundationModelsACPTests (was 114; +23) + 108 ACPGenerateTests = 245 pass, 0 failures. FM API probed via swift-symbolgraph-extract; no divergence. Note for downstream (^gg0pz84 ACP→Transcript, ^0gxpjd4 tool-bridge, ^e2x6ra0 e2e): the mapping is the inverse to implement there; reasoning is a first-class Transcript.Reasoning entry; tool correlation is by shared id; StopReason source is LanguageModelError (not the deprecated GenerationError).
  timestamp: 2026-07-15T19:22:02.100296+00:00
depends_on:
- 01KXHBDAK0NQ5RA2NWTF1ESXQP
- 01KXHBC7FYJYRM3VNBPR4FM4NJ
position_column: review
position_ordinal: '80'
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

## Review Findings (2026-07-15 14:22)

- [ ] `Sources/FoundationModelsACP/Bridge/PromptInputMapper.swift:19` — Swift argument-label rule: label the first parameter of the transforming `render` function; `render(_ blocks:` → `render(blocks:`. Fix at root across the file's transform/builder helpers.
- [ ] `Sources/FoundationModelsACP/Bridge/PromptInputMapper.swift:36` — Label the first parameter of `requireSupported` (a validation, not a value-preserving conversion): `requireSupported(_ block:` → `requireSupported(block:`.
- [ ] `Sources/FoundationModelsACP/Bridge/PromptInputMapper.swift:88` — Label the first parameter of the error builder `unsupported`: `unsupported(_ type:` → `unsupported(type:`.
- [ ] `Sources/FoundationModelsACP/Bridge/TranscriptMapper.swift:112` — Label the first parameter of the transform `toolCallStarted`: `toolCallStarted(_ call:` → `toolCallStarted(call:`.
- [ ] `Sources/FoundationModelsACP/Bridge/TranscriptMapper.swift:123` — Label the first parameter of the transform `toolCallCompleted`: `toolCallCompleted(_ output:` → `toolCallCompleted(output:`.

(8 further findings on `Tests/FoundationModelsACPTests/Bridge/BridgeTestSupport.swift` — relabeling/deduplicating/restructuring of shared test-support helpers, most pre-existing — fall under the review contract's blanket exception for refactoring existing test code and are not tracked.)