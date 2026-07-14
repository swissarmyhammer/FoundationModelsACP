---
depends_on:
- 01KXHBBTQ24BC8586M5K0N872Z
position_column: todo
position_ordinal: 8c80
title: Client-side per-session AsyncStream<SessionUpdate> with straggler tolerance
---
## What
Surface the dominant stream as the primary client API (spec §5): on `ClientSideConnection`, expose per-session `session/update` notifications as `AsyncStream<SessionUpdate>` (the stream AgentViewKit's adapter consumes).

- `ClientSideConnection.updates(for: SessionId) -> AsyncStream<SessionUpdate>` (exact shape may follow prevailing style) — routed from the read loop by `sessionId`.
- **Tolerate late and out-of-order notifications** (spec §5, a real interop hazard): a `tool_call_update` may arrive *after* the prompt response or after `session/cancel` — keep accepting them; correlate every notification to its session/turn and attribute or drop stragglers deliberately (documented policy, not accidental).
- `session/cancel` is a notification; the turn still ends via the prompt response with `StopReason.cancelled`, possibly after more updates land — the stream must deliver those trailing updates.
- Streams finish when the session closes or the connection dies (ties into fail-loud disconnect).

## Acceptance Criteria
- [ ] Updates for two interleaved sessions demux to the correct streams
- [ ] A `tool_call_update` arriving after the `prompt` response is still delivered on the session's stream
- [ ] After cancel, trailing updates then the `cancelled` stop reason are observed in order
- [ ] Connection EOF finishes all session streams

## Tests
- [ ] `Tests/FoundationModelsACPTests/SessionUpdateStreamTests.swift` — demux, late tool_call_update after prompt response, post-cancel stragglers, stream finish on disconnect (driven via ReplayTransport fixtures)
- [ ] Run `swift test` — exits 0

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.