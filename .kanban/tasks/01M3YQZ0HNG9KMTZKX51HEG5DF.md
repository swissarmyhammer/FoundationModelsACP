---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3yr4xc1gyrh4p5hcn44jy84
  text: 'API decision (agreed with foundationmodelsacpclient-ae): an overflow can occur only while a session has no subscriber, so the mark is known when a subscriber attaches. Replace `updates(for:)` with a subscription value, for example `subscribe(to: SessionId) -> SessionUpdateSubscription` with `updates: AsyncStream<SessionUpdate>` and `missedUpdates: Bool`. The first subscriber takes the buffer and the mark; then both are cleared. The old `updates(for:)` does not need to be kept. The router clears the buffer and the mark by itself when the client sends `session/close` through the connection; the client does not call a separate method.'
  timestamp: 2026-10-02T16:46:20.545961+00:00
- actor: claude-code
  id: 01m3yrg5bj1db4j6v3bcq083my
  text: 'Migration decision: keep `updates(for:)` as a deprecated wrapper over `subscribe(to:)` (it returns only the stream). FoundationModelsACPClient still calls it until it deletes ACPSessionState. A separate task removes it later. The buffer limits (1024 updates per session, 64 sessions) MUST be configurable when the `ClientSideConnection` is created; a client test sets a small limit to cause an overflow before the session/new response.'
  timestamp: 2026-10-02T16:52:29.170660+00:00
depends_on:
- 01M3YQYR2Y867FQBAZJG2MKX79
position_column: todo
position_ordinal: '8180'
title: Buffer session updates that have no subscriber, with an overflow mark
---
## Problem

`SessionUpdateRouter.deliver` (`Sources/FoundationModelsACP/Connection/SessionUpdateRouter.swift:78`) drops an update when its session has no subscriber. For `session/new`, the client cannot subscribe before the request, because the agent gives the session ID only in the response. An update that the agent sends before the response (for example `available_commands_update`) is lost.

## Design (agreed with the user and with AgentViewKit)

1. The router keeps a buffer of updates, in order, for each session ID that has no subscriber.
2. The first subscriber gets the buffered updates first, in order, and then the live updates. Then the buffer is removed.
3. Limits: 1024 updates for each session, and at most 64 session IDs with a buffer. Both limits are configurable on `ClientSideConnection`.
4. When a session buffer is full: do NOT drop single updates. Discard the buffer for that session, mark the session as "overflowed", and log a warning with the connection logger. When there are more than 64 buffered session IDs, discard the oldest one with the same mark and warning.
5. A subscriber can read the overflow mark for its session (for example, a stream element or a property next to the stream). The client model uses it to set `hasMissedUpdates`. Choose the API shape; document it.
6. Remove the buffer and the mark on `session/close` (when the client sends it) and on connection close.
7. Update the `updates(for:)` documentation: "updates for a session with no active subscriber are dropped" is no longer true.

A resume does not need the buffer: the session ID is known, so the client subscribes before it sends `session/resume`. Document this order on `updates(for:)`.

## Acceptance criteria

- Tests: an update that arrives before the first subscription is delivered to that subscriber, in order, before live updates.
- Tests: a second subscriber does not get the buffered updates again.
- Tests: overflow discards the buffer, sets the mark, and logs a warning; the 65th session ID evicts the oldest.
- Tests: the buffer is cleared on session/close and on connection close.
- `swift test` passes with no warnings.