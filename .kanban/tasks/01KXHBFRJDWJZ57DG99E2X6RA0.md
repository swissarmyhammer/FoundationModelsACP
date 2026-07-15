---
comments:
- actor: wballard
  id: 01kxkvfjb31cm35vgynn4085jw
  text: |-
    Implementation landed (green). swift build --build-tests: 0 warnings/0 errors. swift test: 176 FoundationModelsACPTests (+5) + 108 ACPGenerateTests = 284 pass, 0 failures, 0 skipped.

    PRODUCTION SEAM (the only production change): FoundationModelsAgent gains an internal, wire-test-only scripted-turn seam — `private let scriptedTurns = Mutex<[SessionId: [TurnGenerator]]>([:])`, `nonisolated func enqueueScriptedTurn(for:_:)`, `private func takeScriptedTurn(for:)`, and one branch in `prompt` that runs a queued scripted turn in place of `streamTurn`. It is internal (never public), never populated in production, and an empty queue leaves prompt driving the real LanguageModelSession unchanged — so it honors §7.1 (no engine protocol, no second execution path) while letting a full `session/prompt` round-trip run over the wire with NO live model. It reuses the exact production turn path (serializeTurn → runTurn → TranscriptMapper → session/update → StopReason), and runTurn still binds ClientEnvironment.$current around the generator, so a scripted "tool" reaching ClientEnvironment.current is exercised for real. `Mutex` + `nonisolated` lets a test enqueue synchronously from the connection factory, before the read loop can dispatch a prompt (closes the race).

    WHY NOT ReplayTransport-through-Connection for the golden: ReplayTransport finishes its `bytes` stream immediately (eager script-in-init), so the Connection read loop hits EOF → shutDown() → cancels the in-flight prompt inbound Task before the async turn completes. That makes any async turn racy/cancelled. Golden replay therefore drives the real AgentSideConnection over an InMemoryTransport driver end (raw `send` with STRING ids per the transports-task note; `AgentFrameCollector` captures the exact agent→client bytes) and never closes the driver mid-turn — deterministic. ReplayTransport keeps its codec-level round-trip test (ReplayTransportTests, unchanged).

    TESTS:
    - EndToEndTests.swift (back-to-back over InMemoryTransport, real ClientSideConnection ↔ real FoundationModelsAgent, real RecordingEnvironmentClient):
      * backToBackFullDuplexIsDeterministic — full initialize handshake + session/new + session/prompt ALL over the wire; the scripted turn reaches ClientEnvironment.current mid-turn and issues reverse fs/read_text_file + session/request_permission (granted) landing on the real client while the prompt is still open; asserts StopReason .endTurn, both reverse calls recorded, and the update sequence. Repeated 100× in one test → proves no flakiness (0.22s).
      * cancelDuringOpenPromptYieldsCancelled — prompt opened in a Task, first update read to prove the turn is live (activeGeneration registered), session/cancel sent over the wire, asserts .cancelled AND the trailing update still lands.
      * lateUpdateAfterResponseReachesClient — a session/update emitted after the prompt response still reaches the client's updates(for:) stream.
    - GoldenReplayTests.swift:
      * goldenSessionReplayMatchesFixture — records/asserts Tests/.../Fixtures/golden-session-script.ndjson (client→agent) + golden-session-agent.ndjson (agent→client) byte-for-byte; structural asserts on framing/ordering/tool-call pairing (shared toolCallId call-1)/StopReason; readable first-differing-line diff on drift.
      * adversarialWireInputIsTolerated — garbage line skipped (codec drops it, no error frame), interleaved concurrent initialize+session/new each correlate by id, cancel mid-turn → .cancelled, late tool_call_update after the response still delivered.

    CLIENTENVIRONMENT AMBIENT INJECTION — CONFIRMED END-TO-END (the FM-tools task's open question): the back-to-back flagship force-reads ClientEnvironment.current inside the turn generator and its reverse fs + permission calls land on the real client over the wire, 100/100 runs. Caveat: this confirms the injection propagates into any code the turn generator runs within runTurn's structured-concurrency tree (which is where FM invokes a Tool.call); it cannot prove the live FM runtime invokes tools within that tree — that remains unverifiable without a live model, as the FM-tools thread noted.

    FIXTURE CAPTURE PROCEDURE documented in Tests/FoundationModelsACPTests/Fixtures/README.md: `RECORD_GOLDEN=1 swift test --filter GoldenReplayTests` rewrites both fixtures from the live run; without it the test asserts the committed bytes. Fixtures use STRING JSON-RPC ids to avoid Double formatting drift and are excluded from the target (loaded via #filePath). Checkpoint + review next.
  timestamp: 2026-07-15T21:38:45.731631+00:00
depends_on:
- 01KXHBEC0KP7222Z5M20GXPJD4
- 01KXHBAS76FYGF2AFEEN8K8GQJ
- 01KXHBERPC2RPCY6TQFVFMSTVY
position_column: doing
position_ordinal: '80'
title: 'End-to-end wire tests: back-to-back roles + golden transcript replay'
---
## What
Prove the whole stack (spec §8) with deterministic end-to-end tests:

- **Back-to-back:** a real `Client` and the `FoundationModelsAgent` (over a scripted-session provider, no live model) wired through `InMemoryTransport`: full initialize handshake → `session/new` → `session/prompt` turn with reverse `fs/*` + `request_permission` calls mid-turn → `StopReason` — the fastest full-duplex exercise of the entire bidirectional surface.
- **Golden replay:** capture a full session's ndJSON byte stream as a fixture (`Tests/Fixtures/*.ndjson`); `ReplayTransport` feeds the client→agent script and the test asserts the agent's emitted frame sequence against the golden agent→client fixture — framing, ordering, tool-call pairing, late `tool_call_update`, `StopReason` all verified deterministically. Capture once, replay forever.
- Include a fixture with adversarial cases: interleaved concurrent requests, a garbage line, a late `tool_call_update` after the prompt response, and a cancel mid-turn.
- Document the capture procedure (tee the stream) in the test target's README so new fixtures are a one-liner to record.

## Acceptance Criteria
- [ ] Back-to-back test exercises both directions concurrently (reverse request during open prompt) and passes deterministically over 100 repeated runs (`swift test --repeat` or a loop)
- [ ] Golden replay matches frame-for-frame, and fails loudly with a readable diff when the agent's output drifts
- [ ] Adversarial fixture passes: garbage skipped, stragglers accepted, cancel yields `cancelled`

## Tests
- [ ] `Tests/FoundationModelsACPTests/EndToEndTests.swift` — the back-to-back scenario
- [ ] `Tests/FoundationModelsACPTests/GoldenReplayTests.swift` — fixture replay assertions
- [ ] Run `swift test` — exits 0

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.