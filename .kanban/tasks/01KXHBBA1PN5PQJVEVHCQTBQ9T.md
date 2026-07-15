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
- actor: wballard
  id: 01kxj03zc1672rh9qxze86774k
  text: |-
    Iteration 2: fixed both review findings from checkpoint 3dc1e99 (TDD, RED watched for each behavior change).

    1. Inbound jsonrpc-version validation: dispatch() now rejects envelopes whose `jsonrpc` != "2.0". Shape-aware handling (this matters — double-check caught a real defect in the naive first version): request-shaped → -32600 reply when id present; response-shaped → the awaiting caller is failed immediately with RequestError.invalidRequest and NO reply is written (JSON-RPC never answers a response, and both sides number requests from 1 so an echoed id could collide with one of the peer's own in-flight calls and reject an unrelated pending request on their side); neither shape → log and drop. The naive guard would have silently HUNG the caller on a sloppy peer's unversioned response (timeouts are opt-in) — the regression test hit the 60s time limit on RED exactly as predicted.
    2. RequestError round-trip coverage extended: authRequired now round-trips throw → wireValue → wire → init(wire:) → caught equal (plus the two -32600 request-shape tests and the response-shape hang test).

    Suite now 106 tests (70 + 36), exit 0, zero warnings. Double-check on the delta: REVISE (the hang defect above) → fixed → re-check PASS with independent fresh test run. Both review-finding checkboxes flipped to [x].

    Interop note for downstream tasks: the connection is now STRICT about `"jsonrpc": "2.0"` on every inbound message — raw-wire tests and replay fixtures must stamp the version on every envelope (all existing fixtures already do).
  timestamp: 2026-07-15T04:21:19.873886+00:00
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
- [x] Multiple requests in flight in both directions simultaneously resolve to the correct callers
- [x] A slow inbound request handler does not delay handling of a subsequent notification (verified with an ordering test)
- [x] On transport EOF, every pending request throws connection-closed (test with 3+ pending); no hang
- [x] Cancelling the Swift `Task` awaiting a request unblocks it; a per-request timeout fires when the peer never answers

## Tests
- [x] `Tests/FoundationModelsACPTests/ConnectionTests.swift` — over `InMemoryTransport`: concurrent bidirectional requests, id correlation, notification routing, method-not-found
- [x] `Tests/FoundationModelsACPTests/DisconnectTests.swift` — EOF rejects all pending; timeout; Task-cancellation propagation
- [x] Run `swift test` — exits 0

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-07-14 23:01)

- [x] `Sources/FoundationModelsACP/Connection/Connection.swift:182` — All outbound messages enforce 'jsonrpc': '2.0' (lines 117, 185, 221), establishing the invariant that all valid JSON-RPC messages carry this version field. But inbound messages in dispatch() are never validated to have this field—a peer message with 'jsonrpc': '1.0' or missing 'jsonrpc' entirely would be processed as JSON-RPC 2.0 without complaint. The same token's handling is asymmetric: enforced on write, not checked on read. Add a validation in dispatch() (e.g., after line 180) to check that fields['jsonrpc'] == .string('2.0'). If not, either log a diagnostic and continue, or treat it as unclassifiable (answer with -32600 invalid request if the message has an id, per JSON-RPC spec).
- [x] `Tests/FoundationModelsACPTests/ConnectionTests.swift:132` — RequestError.swift defines seven error-type constructors (parseError, invalidRequest, methodNotFound, invalidParams, internalError, authRequired, resourceNotFound), each capable of being thrown by a handler, serialized to JSON-RPC wire format via wireValue, and deserialized by init(wire:). The test handlerRequestErrorPropagatesCodeMessageAndData verifies the full round-trip (throw → serialize → send → receive → deserialize → compare) for only resourceNotFound. The other error variants—invalidParams, authRequired—are defined but never tested as handler throwables in a round-trip, leaving the serialize/deserialize path for those types untested. Add one test that throws RequestError.invalidParams or RequestError.authRequired from a handler, sends it to a client, and verifies the client deserializes and matches the thrown error—demonstrating that the serialize/deserialize path handles these variants.

## Review Findings (2026-07-14 23:21)

- [ ] `Sources/FoundationModelsACP/Connection/Connection.swift:87` — JSON-RPC version '2.0' is hardcoded as .string("2.0") in 4 places (request, notify, dispatch, respond methods); repeated literals should be named constants for maintainability and to centralize version control. Define a constant `private static let JSONRPC_VERSION = "2.0"` and use it in all 4 locations instead of hardcoding the literal.
- [ ] `Sources/FoundationModelsACP/Connection/Connection.swift:131` — Deep nesting exceeds 4 levels: the timeout task code is nested through withTaskCancellationHandler → withCheckedThrowingContinuation → .map closure → Task closure, reaching 4-5 levels at the innermost code (lines 133-135), making the control flow harder to follow. Extract the timeout task creation into a private helper method (e.g., `private func createTimeoutTask(for id: RequestID, limit: Duration?) -> Task<Void, Never>?`) to reduce request() nesting to 2-3 levels, or replace the .map with an explicit if-let condition for the optional Duration.
- [ ] `Sources/FoundationModelsACP/Connection/Connection.swift:148` — Repeated hardcoded JSON-RPC version '2.0' in notify method; same literal appears in request (line ~87), dispatch (line ~176), and respond (line ~212). Use extracted constant instead of hardcoded .string("2.0").
- [ ] `Sources/FoundationModelsACP/Connection/Connection.swift:166` — Log message prefix 'Connection: ' is hardcoded and repeated in 6 diagnostic log calls throughout the file; should be extracted to a named constant. Define a constant `private static let LOG_PREFIX = "Connection: "` and use string interpolation in log calls.
- [ ] `Sources/FoundationModelsACP/Connection/Connection.swift:173` — Repeated hardcoded 'Connection: ' log prefix; same literal appears in 5 other log calls (lines ~166, ~194, ~204, ~243, ~271). Use extracted constant instead of hardcoded prefix.
- [ ] `Sources/FoundationModelsACP/Connection/Connection.swift:176` — Repeated hardcoded JSON-RPC version '2.0' in dispatch version check; same literal appears in request (line ~87), notify (line ~148), and respond (line ~212). Use extracted constant instead of hardcoded .string("2.0").
- [ ] `Sources/FoundationModelsACP/Connection/Connection.swift:194` — Repeated hardcoded 'Connection: ' log prefix; same literal appears in 5 other log calls (lines ~166, ~173, ~204, ~243, ~271). Use extracted constant instead of hardcoded prefix.
- [ ] `Sources/FoundationModelsACP/Connection/Connection.swift:204` — Repeated hardcoded 'Connection: ' log prefix; same literal appears in 5 other log calls (lines ~166, ~173, ~194, ~243, ~271). Use extracted constant instead of hardcoded prefix.
- [ ] `Sources/FoundationModelsACP/Connection/Connection.swift:212` — Repeated hardcoded JSON-RPC version '2.0' in respond method; same literal appears in request (line ~87), notify (line ~148), and dispatch (line ~176). Use extracted constant instead of hardcoded .string("2.0").
- [ ] `Sources/FoundationModelsACP/Connection/Connection.swift:243` — Repeated hardcoded 'Connection: ' log prefix; same literal appears in 5 other log calls (lines ~166, ~173, ~194, ~204, ~271). Use extracted constant instead of hardcoded prefix.
- [ ] `Sources/FoundationModelsACP/Connection/Connection.swift:250` — The block `if let id { await respond(id: id, outcome: .failure(.invalidRequest)) }` is duplicated elsewhere in dispatch(); identical error handling logic appears in multiple failure paths, creating maintenance burden. Extract the conditional-respond pattern into a helper method to eliminate duplication. Example: `private func respondWithInvalidRequestIfIdPresent(_ id: JSONValue?) async { guard let id else { return }; await respond(id: id, outcome: .failure(.invalidRequest)) }`.
- [ ] `Sources/FoundationModelsACP/Connection/Connection.swift:271` — Repeated hardcoded 'Connection: ' log prefix; same literal appears in 5 other log calls (lines ~166, ~173, ~194, ~204, ~243). Use extracted constant instead of hardcoded prefix.
- [ ] `Sources/FoundationModelsACP/Connection/Connection.swift:273` — The block `if let id { await respond(id: id, outcome: .failure(.invalidRequest)) }` is duplicated elsewhere in dispatch(); same error response logic as line ~250. Use the helper method suggested for the first occurrence rather than repeating the pattern.