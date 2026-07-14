---
depends_on:
- 01KXHBADH1XF34Q5C911R8GYD6
- 01KXHBAS76FYGF2AFEEN8K8GQJ
position_column: todo
position_ordinal: 8a80
title: 'JSON-RPC Connection actor: correlation, concurrency, fail-loud disconnect'
---
## What
Implement the full-duplex JSON-RPC engine (spec §5) in `Sources/FoundationModelsACP/Connection/Connection.swift`, porting the classic Rust-SDK oneshot + pending-map design (spec §1):

- A connection `actor` holding a monotonic numeric request id and a `[RequestID: CheckedContinuation]` pending map; the actor also serializes writes (no separate write queue).
- One read loop dispatches each inbound message by kind: **request** → handler → send response keyed by `id`; **notification** → route to handler; **response** → resolve the pending continuation for that `id`.
- **Each inbound request is dispatched as its own `Task`** so a slow `session/prompt` never head-of-line-blocks an incoming `session/cancel`, `request_permission`, or `fs/*` callback. Long-lived requests (`session/prompt`, `terminal/wait_for_exit`) are just suspended continuations and must never block the read loop.
- **Fail loud on disconnect** (a real TS-SDK gap we must not reproduce): on EOF or stream error, reject every pending continuation with a connection-closed error and finish all AsyncStreams — never leave callers hung.
- **Per-request timeout** (configurable) and honor Swift `Task` cancellation so a stuck peer can't wedge a caller.
- JSON-RPC errors map to typed `RequestError`; unknown methods answer -32601 method-not-found; `_meta` preserved on every message.

## Acceptance Criteria
- [ ] Multiple requests in flight in both directions simultaneously resolve to the correct callers
- [ ] A slow inbound request handler does not delay handling of a subsequent notification (verified with an ordering test)
- [ ] On transport EOF, every pending request throws connection-closed (test with 3+ pending); no hang
- [ ] Cancelling the Swift `Task` awaiting a request unblocks it; a per-request timeout fires when the peer never answers

## Tests
- [ ] `Tests/FoundationModelsACPTests/ConnectionTests.swift` — over `InMemoryTransport`: concurrent bidirectional requests, id correlation, notification routing, method-not-found
- [ ] `Tests/FoundationModelsACPTests/DisconnectTests.swift` — EOF rejects all pending; timeout; Task-cancellation propagation
- [ ] Run `swift test` — exits 0

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.