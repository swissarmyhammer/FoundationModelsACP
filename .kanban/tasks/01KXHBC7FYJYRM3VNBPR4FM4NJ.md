---
comments:
- actor: wballard
  id: 01kxkbzcnp2d925ytn2gtpffyy
  text: |-
    Picked up. Research complete across ClientSideConnection (^0n872z role-protocols thread) and Connection actor (^tbq9t fail-loud-on-disconnect thread).

    DESIGN (Sources/FoundationModelsACP/Connection/):
    - New `SessionUpdateRouter: Sendable` (Mutex-backed registry). Fans `session/update` out to per-session AsyncStream<SessionUpdate>. `updates(for:) -> AsyncStream<SessionUpdate>` registers a fresh continuation keyed by (sessionId, monotonic token) so N subscribers per session broadcast; `deliver(_ SessionNotification)` yields `.update` to every subscriber of that sessionId; `finishAll()` finishes every continuation on disconnect. onTermination removes a subscriber when its consumer stops. No pre-subscription buffering (see policy).
    - ClientSideConnection builds the router as a local in init, captures it in the dispatchNotification closure (NOT self, preserving the init-cycle break), stores it, and exposes `public func updates(for: SessionId) -> AsyncStream<SessionUpdate>`. serveNotification for sessionUpdate now routes into the router in addition to calling client.sessionUpdate.
    - Disconnect wiring: add optional `onClose: (@Sendable () -> Void)? = nil` to Connection.init, invoked once at the end of shutDown() (EOF, stream error, or close()). RoleConnectionCore threads it through (default nil, so AgentSideConnection is unchanged). ClientSideConnection passes `router.finishAll`. This is the fail-loud disconnect signal upper layers use to finish derived streams.

    STRAGGLER POLICY (documented): every notification is correlated to its sessionId and delivered to that session's active subscribers. Stream lifetime = subscription -> connection close, INDEPENDENT of turn lifetime, so a tool_call_update arriving after the prompt response or after session/cancel is still delivered (cancel is a notification; the turn ends via the prompt response carrying StopReason.cancelled, and trailing updates land before/after in wire order). Notifications for a session with no active subscriber are dropped deliberately — the client subscribes via updates(for:) before driving the turn.

    TESTS (SessionUpdateStreamTests.swift, TDD RED first): drive raw agent->client frames over InMemoryTransport (WireReader/send helpers) for deterministic ordering (avoids the eager-feed race that would drop head updates): (1) two interleaved sessions demux; (2) late tool_call_update after prompt response still delivered; (3) post-cancel trailing updates then cancelled stop reason in order; (4) agentEnd.close() finishes all session streams.
  timestamp: 2026-07-15T17:07:46.998412+00:00
- actor: wballard
  id: 01kxkc7xt10vvd80v7krk8r9zx
  text: |-
    Implementation landed (TDD: 4 tests written first in SessionUpdateStreamTests.swift, then implemented to green).

    FILES:
    - NEW Sources/.../Connection/SessionUpdateRouter.swift — Mutex-backed fan-out. updates(for:) registers a fresh continuation per (sessionId, monotonic token); deliver() yields notification.update to all subscribers of that sessionId; finishAll() drains+finishes outside the lock (avoids Mutex reentrancy via onTermination); onTermination removes a stopped subscriber.
    - Connection.swift — added `public typealias CloseHandler = @Sendable () -> Void` and optional `onClose` init param, invoked once at the END of shutDown() (after pending rejected). Backward compatible (default nil).
    - RoleConnectionCore.swift — threads onClose through (default nil, AgentSideConnection unchanged).
    - ClientSideConnection.swift — builds router as an init local captured by dispatchNotification + onClose closure (NOT self; init-cycle break preserved), stores it, exposes `public func updates(for: SessionId) -> AsyncStream<SessionUpdate>`; serveNotification now routes into router.deliver THEN still calls client.sessionUpdate (both surfaces work).

    TESTS (swift test exit 0): FoundationModelsACPTests 104 (was 100; +4) + ACPGenerateTests 108 = 212, zero warnings. New: updatesDemuxAcrossInterleavedSessions, lateToolCallUpdateAfterPromptResponseIsDelivered, postCancelTrailingUpdatesThenCancelledStopReasonInOrder, connectionEOFFinishesAllSessionStreams. Pre-existing clientSideSessionUpdateNotificationDispatchesToTheHandler still green (serveNotification change is additive). Tests drive raw agent->client frames over InMemoryTransport (WireReader/send) for deterministic ordering and to subscribe before driving the turn.
  timestamp: 2026-07-15T17:12:26.689464+00:00
depends_on:
- 01KXHBBTQ24BC8586M5K0N872Z
position_column: doing
position_ordinal: '80'
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