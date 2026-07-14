---
depends_on:
- 01KXHBEC0KP7222Z5M20GXPJD4
- 01KXHBAS76FYGF2AFEEN8K8GQJ
- 01KXHBERPC2RPCY6TQFVFMSTVY
position_column: todo
position_ordinal: '9380'
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