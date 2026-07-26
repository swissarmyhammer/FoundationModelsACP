---
depends_on:
- 01KYD58WPKKF4BAN3AKFZV61KY
position_column: todo
position_ordinal: '8380'
title: 'M3 Connections and transports: full-duplex, fail loud'
---
## Starting point

**This is a rewrite, and the most salvageable one on the board.** `plan.md` -> *Starting point* has the full inventory.

A working v1 implementation of nearly everything in this task was deleted and is in git history: `Connection/Connection.swift`, `RoleConnectionCore.swift`, `RoleDispatch.swift`, `AgentSideConnection.swift`, `ClientSideConnection.swift`, `SessionUpdateRouter.swift`, and `Transport/{NDJSONCodec, StdioTransport, InMemoryTransport, SubprocessTransport, DescriptorIO}.swift`, plus their tests (`ConnectionTests`, `DisconnectTests`, `StdioTransportTests`, `InMemoryTransportTests`, `NDJSONCodecTests`, `SubprocessReapTests`, `SessionUpdateStreamTests`, `RoleDispatchTests`, `FactoryClosureTests`).

**Read that code before writing new code.** The read loop, continuation correlation, per-request `Task` dispatch, fail-loud disconnect, ndJSON framing, and the factory-closure pattern are all **protocol-version-agnostic** and were reviewed and tested. The v2 delta here is genuinely small: the payload types change, and `session/prompt` stops being long-lived. Recovering and re-typing this is the expected approach — not a from-scratch rewrite.

The `acp-test-agent` executable target (a subprocess fixture for stdio transport tests) was also deleted; restore it if the stdio tests need it.

## What

`plan.md` -> **Connection model: full-duplex, notification-first**.

Two symmetric connection objects over one byte stream, each taking a **factory closure** so a handler can capture its own connection for reverse calls:

```swift
AgentSideConnection(stream:)  { conn  in RoutedACPAgent(conn, router) }
ClientSideConnection(stream:) { agent in MyClient(agent) }
```

Implementation:

- **One read loop per connection.** Correlation by monotonic request id and `[RequestID: CheckedContinuation]` inside the connection actor, which also serializes writes.
- **Each inbound request dispatches as its own `Task`**, so a slow handler cannot head-of-line-block a `session/cancel` or a reverse request.
- **v2 makes this simpler:** `session/prompt` acknowledges immediately, so no request is held open for a whole turn. The only genuinely long-lived requests are the ones waiting on a human -- `session/request_permission` and `elicitation/create` -- and those must never block the read loop.
- **Fail loud on disconnect** (a real gap in other SDKs): on EOF or error, reject every pending continuation and finish every stream. Per-request timeouts. Honor `Task` cancellation.
- **Tolerate late and out-of-order notifications.** Correlation is by `messageId` / `toolCallId` / `terminalId`, never arrival order; an upsert may arrive after the state it refers to has moved on.

**Transports:** stdio with ndJSON framing, and `InMemoryTransport.pair()`. The in-process pair is **production**, not just a fixture: it is how a SwiftUI app runs an agent in the same process while still speaking the protocol.

## Acceptance Criteria

- [ ] Both connection sides work over both transports.
- [ ] Requests and notifications flow concurrently in both directions.
- [ ] Each inbound request runs in its own `Task`; a slow handler does not stall others.
- [ ] Disconnect rejects all pending continuations and finishes all streams -- no hangs.
- [ ] Per-request timeouts and `Task` cancellation honored.
- [ ] Batch JSON-RPC messages supported (v2 states batch support).
- [ ] The connection and transport test suites listed above exist again, retargeted to v2.

## Tests

- [ ] A slow `session/prompt` handler does not delay a concurrent `session/cancel`.
- [ ] EOF mid-request rejects the pending continuation promptly rather than hanging.
- [ ] Out-of-order and late notifications are delivered without reordering assumptions.
- [ ] A reverse request from inside a handler reaches the peer (factory-closure capture works).
- [ ] Malformed ndJSON frame produces a clean protocol error, not a crashed read loop.
- [ ] Batched messages are handled.
