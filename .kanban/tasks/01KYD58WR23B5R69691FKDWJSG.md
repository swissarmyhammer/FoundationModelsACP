---
comments:
- actor: claude-code
  id: 01kyfghfjh0pxxm8tswhjt8dfq
  text: |-
    Corrected against the vendored `Schema/acp-v2.meta.json` / `acp-v2.meta.unstable.json` (`schema-v2.0.0-alpha.2`, vendored in M0).

    The card named `elicitation/create` alongside `session/request_permission` as the long-lived human-waiting requests. Only `session/request_permission` qualifies: it is one of exactly two entries in the stable `clientMethods` manifest (the other being the `session/update` notification). `elicitation/create` is unstable-only.

    What changed:
    - That bullet now matches `plan.md` verbatim in substance: one remaining long-lived stable request, `session/request_permission`, with `elicitation/create` carried as an "if and when elicitation becomes stable" caveat rather than a present-tense requirement. Design the read loop for one, not two.
    - Added a bullet noting `$/cancel_request` is protocol-level (the sole `protocolMethods` entry), so it lands in this layer rather than on the `Agent` / `Client` protocols -- the corresponding note went onto M2 (^fzv61ky), and this is the other half of it.

    Nothing else touched. The connection design in this card is protocol-version-agnostic and was not affected by the vendor.
  timestamp: 2026-07-26T15:26:18.193637+00:00
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
- **v2 makes this simpler:** `session/prompt` acknowledges immediately, so no request is held open for a whole turn. The one remaining long-lived request in the stable surface is the one that genuinely waits on a human -- `session/request_permission` -- and it must never block the read loop. (`elicitation/create` would join it if and when elicitation becomes stable; it is unstable-only in the vendored `schema-v2.0.0-alpha.2`, so do not design around it now.)
- **`$/cancel_request`** is protocol-level rather than a role method, so it belongs to this layer, not to `Agent`/`Client`.
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
- [ ] `$/cancel_request` is served at the connection layer on both sides, not on either role protocol.
- [ ] The connection and transport test suites listed above exist again, retargeted to v2.

## Tests

- [ ] A slow `session/prompt` handler does not delay a concurrent `session/cancel`.
- [ ] EOF mid-request rejects the pending continuation promptly rather than hanging.
- [ ] Out-of-order and late notifications are delivered without reordering assumptions.
- [ ] A reverse request from inside a handler reaches the peer (factory-closure capture works).
- [ ] Malformed ndJSON frame produces a clean protocol error, not a crashed read loop.
- [ ] Batched messages are handled.
