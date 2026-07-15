---
comments:
- actor: wballard
  id: 01kxhyyban4tkgc6k7dp0f65a3
  text: |-
    Implementation landed via TDD (20 new tests written first; watched RED as missing-type build failures for Connection/RequestError/ConnectionError, then GREEN). Full suite: 102 tests (66 + 36), exit 0, zero warnings. Double-check verdict: PASS (one REVISE finding fixed, then re-checked PASS).

    Public API (Sources/FoundationModelsACP/Connection/):

    - `actor Connection` — `init(transport:logger:requestTimeout:requestHandler:notificationHandler:) async` (async init is actor-isolated, which is what lets it store the read-loop Task safely); `request(method:params:timeout:) async throws -> JSONValue`; `notify(method:params:) async throws`; `close()`. Handlers are plain closures: `RequestHandler = @Sendable (String, JSONValue?) async throws -> JSONValue`, `NotificationHandler = @Sendable (String, JSONValue?) async -> Void`.
    - `struct RequestError: Error, Codable, Hashable, Sendable` — code/message/data per spec §3, with spec-catalogued statics (parseError, invalidRequest, methodNotFound(_:), invalidParams, internalError(detail:), authRequired, resourceNotFound(uri:)). Generated ACPError was NOT reused: its `code` is the placeholder `ErrorCode = JSONValue`; RequestError has the same wire shape with a real Int code.
    - `enum ConnectionError: Error, Hashable, Sendable` — `.closed` (EOF/stream error/close(): every pending continuation rejected), `.timedOut` (per-request timeout).

    Decisions the role-protocols task (^tq24bc etc.) should know:

    - Envelope validation lives here as promised by the codec task: object + string `method` (+ id → request, no id → notification); no method + id + result/error → response; id but unclassifiable → -32600 response; no id → logged drop. `"error": null` in a response is tolerated as absent.
    - Inbound requests each run in their OWN Task (tracked, cancelled on shutdown); notifications are awaited INLINE in the read loop to preserve arrival order — role-layer notification handlers must return promptly (yield to an AsyncStream), or they delay the wire.
    - nil requestHandler answers everything -32601; handlers throw RequestError for typed errors, anything else maps to -32603 with detail in data. _meta passes through untouched (params/result are opaque JSONValue).
    - Outbound ids are monotonic Ints encoded .number; JSONEncoder emits whole doubles as integers ("id":1) so strict peers interoperate. Inbound ids (including string ids) are echoed verbatim.
    - Cancellation/timeout/response/disconnect all funnel through idempotent `pending.removeValue` — exactly-once resume, no double-resume possible. Registration happens synchronously in the actor before the frame is written, so an instant response always finds its continuation.
    - Timeout default is nil = wait forever (session/prompt relies on this); configure per-connection via init or per-call via `request(timeout:)` override.
    - Double-check finding (fixed): actor reentrancy means two transport.write calls can overlap across suspensions, so ACPTransport.write's doc contract now REQUIRES per-call atomicity + concurrent-call tolerance — the stdio transport task must honor this (a frame > PIPE_BUF written concurrently can interleave; write whole frames atomically).
    - Wiring pattern for role connections: create the role actor first, then `await Connection(...)` inside its init with closures capturing the role actor — no factory seam needed inside Connection itself.
  timestamp: 2026-07-15T04:00:46.933395+00:00
depends_on:
- 01KXHBADH1XF34Q5C911R8GYD6
- 01KXHBAS76FYGF2AFEEN8K8GQJ
position_column: doing
position_ordinal: '80'
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