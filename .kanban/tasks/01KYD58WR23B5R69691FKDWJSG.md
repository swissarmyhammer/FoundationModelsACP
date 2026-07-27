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
- actor: claude-code
  id: 01kyjhmt0705aysh1hjn6s5p71
  text: |-
    Implementation landed. Recovered the v1 connection/transport design from git history (commit 02964e2^, the reset-branch deletion commit) and re-typed it against v2:

    - Transport/{NDJSONCodec,DescriptorIO,StdioTransport,InMemoryTransport,SubprocessTransport}.swift restored near-verbatim from git history (protocol-version-agnostic as the card predicted), with one enhancement: NDJSONCodec now yields NDJSONFrame {.message, .malformed} instead of silently dropping unparseable lines, so Connection can answer a malformed frame with a clean -32700 parse-error response (id: null) instead of dropping it — this is what the "malformed ndJSON frame produces a clean protocol error, not a crashed read loop" acceptance test needed; v1 only logged-and-dropped.
    - Connection.swift: same actor design as v1 (monotonic id, [RequestID: PendingRequest], per-request Task, fail-loud shutdown, timeout tasks) plus two v2-only additions: batch JSON-RPC (dispatchBatch/owesResponse/deliver collect owed responses into one aggregate array reply; notification-only batches get no reply) and $/cancel_request handling at the connection layer (inboundTasks now keyed by RequestID instead of a monotonic counter so a cancel notification can look a running handler up and cancel it; outbound Task cancellation now also fires a best-effort $/cancel_request to the peer, only when there was still something pending to cancel).
    - RoleConnectionCore/RoleDispatch: straight port; dropped v1's DeprecatedRouting (session/set_mode has no v2 equivalent) and callEmpty (every v2 Agent method returns a typed response, so the "response the caller discards" case doesn't exist in v2).
    - AgentSideConnection/ClientSideConnection: rebuilt against v2's much smaller method set (10 Agent methods + sessionCancel notification; Client has only sessionUpdate + requestPermission) — no fs/*, no terminal/*, no authenticate/loadSession/setSessionMode holdovers from v1.
    - SessionUpdateRouter: kept (per-session AsyncStream demux), retyped to SessionId/UpdateSessionNotification/SessionUpdate.
    - RequestError.swift: added wireValue/init(wire:) (tolerant decode of a peer's error object) since v2's RequestError is the generated ACPError, not v1's hand-rolled struct with those already on it.
    - acp-test-agent fixture restored, Package.swift updated (executable target + test dependency).

    Test suites re-established, all retargeted to v2 types: ConnectionTests, DisconnectTests, NDJSONCodecTests, InMemoryTransportTests, StdioTransportTests, SubprocessReapTests, SessionUpdateStreamTests, RoleDispatchTests, FactoryClosureTests, plus WireTestSupport/TransportProcessSupport helpers. Added tests beyond straight v1 ports for the two v2-only behaviors (batch handling, $/cancel_request) and for the malformed-frame parse-error change.

    Verified: `swift build --build-tests` — 0 errors, 0 warnings. `swift test` — 213 tests / 21 suites passing (138/11 in FoundationModelsACPTests, 75/10 in ACPGenerateTests), 0 failures. Baseline before this task was 136/19, so net +77 tests / +2 suites (the two new suites are RoleDispatchTests.swift's two @Suite structs; every other new file uses plain top-level @Test funcs, which swift-testing doesn't count as a suite).

    Adversarial double-check dispatched; will record its verdict once it returns.
  timestamp: 2026-07-27T19:43:19.047396+00:00
- actor: claude-code
  id: 01kyjq85ny4ye2y2j6qfaze6zn
  text: |-
    Adversarial double-check round 1 verdict: REVISE, two actionable findings, both in Connection.swift:

    1. Medium: dispatchRequest's inboundTasks[id] = task could silently overwrite an already-in-flight task sharing the same wire id (two batch items with the same id, or a peer reusing an id before the first resolved) -- misdirecting a later $/cancel_request and losing track of the first task.
    2. Low: deliver's fallback branch silently wrote a spurious standalone frame instead of failing loud when a batchToken was missing from `batches`, which would mask a future batch-accounting bug rather than surface it.

    Both fixed:
    - dispatchRequest is now async and checks `inboundTasks[id] != nil` before registering; a colliding id gets an immediate `invalidRequest` response (via respond, honoring batch accounting) instead of overwriting the first task's slot. First task is untouched and completes normally.
    - deliver now distinguishes "no batchToken" (standalone write, unchanged) from "batchToken present but not found in `batches`" (now logs a diagnostic instead of silently falling through to a standalone write).
    - Added regression test `duplicateInboundRequestIdWhileFirstIsInFlightIsRejectedNotMisdirected` (ConnectionTests.swift) proving the second colliding request gets -32600 immediately and the first completes normally afterward.

    Third finding (blocking synchronous write(2) under a mutex in DescriptorIO/StdioTransport/SubprocessTransport, no suspension point) was explicitly called "no fix required" by the reviewer -- it matches the historical v1 design this task was told to recover from git history, and changing it would be scope creep (a different concurrency architecture for the transport layer, not a v2 delta). Left as-is, logged here per the review contract rather than silently ignored.

    Re-verified after the fix: `swift build --build-tests` 0 errors/0 warnings; `swift test` 214 tests / 21 suites passing (139/11 + 75/10), up from 213/21. Bounded second double-check round dispatched to confirm the fix and give final sign-off; will record its verdict next.
  timestamp: 2026-07-27T21:21:16.478869+00:00
- actor: claude-code
  id: 01kyjqzyp9tgfmv8jke5a94s0b
  text: |-
    Adversarial double-check round 2 (bounded final pass) verdict: PASS.

    Confirmed against the actual current source: the id-collision check in dispatchRequest runs synchronously before any suspension point, with the sole call site already serialized inside the single-threaded read loop, so no window exists for a second same-id request to slip in before the first's registration completes; $/cancel_request still keys off the untouched inboundTasks entry for the original task. deliver's two fallback paths (no batchToken vs. batchToken present but missing) are now distinct, with the latter logging instead of silently emitting a stray frame. The new regression test was confirmed non-tautological -- without the fix both handler invocations would block on the same gate and the test would hang to its 1-minute limit rather than pass.

    Final fresh verification: `swift build --build-tests` -- 0 errors, 0 warnings. `swift test` -- 214 tests / 21 suites passing (139/11 FoundationModelsACPTests + 75/10 ACPGenerateTests), 0 failures. Baseline before this task was 136/19.

    Task is done and green. Leaving in `doing` for `/review` per the /implement contract.
  timestamp: 2026-07-27T21:34:15.753071+00:00
- actor: claude-code
  id: 01kyjv3q1v50xetybz4v9mdnzf
  text: |-
    Independent test verification (rm -rf .build, clean rebuild, repeated swift test runs).

    Baseline: swift build --build-tests clean, 0 warnings. swift test x3 = 214 tests / 21 suites (139+75, 11+10) / 0 failures each run. git diff/status on Sources/FoundationModelsACP/Generated/ empty -- no generated-code drift. DocC (swift package generate-documentation --target FoundationModelsACP --warnings-as-errors) clean.

    Stress-testing per the task's flakiness concern (swift test --filter ... --maximum-repetitions N --repeat-until fail) found a REAL deadlock, not flakiness-that-passes-eventually: running the five subprocess-spawning tests (agentOverStdioCompletesInitializeHandshake, agentStdoutIsPureNDJSONWhileLoggingToStderr, malformedFrameOverStdioGetsACleanParseErrorNotACrash, closingTransportReapsSpawnedChild, closingConnectionReapsChildAgent) at higher repetition counts hung permanently (confirmed via `sample` on the stuck swiftpm-testing-helper process, 0% CPU, no children).

    Root cause: both StdioTransportTests.swift (two tests) and the production Sources/FoundationModelsACP/Transport/SubprocessTransport.swift called the synchronous, thread-blocking `Process.waitUntilExit()` from async test/production code. On Darwin, Swift Concurrency's cooperative pool is backed by a fixed-size GCD queue (com.apple.root.default-qos.cooperative); enough concurrent blocking waits exhaust every worker thread, and nothing is left to run the notification that would free any of them -- a genuine, permanent, self-inflicted deadlock (not a race that resolves on retry).

    Fixed both:
    - Tests/FoundationModelsACPTests/TransportProcessSupport.swift: added terminateAndAwaitExit(_:), an async helper using Process.terminationHandler + withCheckedContinuation instead of blocking.
    - Tests/FoundationModelsACPTests/StdioTransportTests.swift: both raw-Process tests now call it instead of process.terminate(); process.waitUntilExit().
    - Sources/FoundationModelsACP/Transport/SubprocessTransport.swift: reap() no longer blocks; terminationHandler (installed at spawn) now records exit status into a new exitStatus: Mutex<Int32?> and closes stdin once the child actually exits. isRunning/terminationStatus read that recorded state. close()/deinit/stream-teardown now only signal termination (process.terminate()), never wait.
    - Tests/FoundationModelsACPTests/SubprocessReapTests.swift: closingTransportReapsSpawnedChild now polls (waitUntil) instead of asserting synchronously right after close(), since the exit is no longer observed synchronously.

    Re-verified after the fix: the same 5 subprocess tests at --maximum-repetitions 20 (100 spawns) complete in 0.49s, 0 failures. The full FoundationModelsACPTests target at --maximum-repetitions 20 --parallel (2,780 executions) completes in 1.1s, 0 failures -- previously this combination hung indefinitely. Re-ran the full default swift test 3x after the fix: still 214/21/0, 0 warnings. No swift format run.

    No other flakiness observed. Two now-orphaned hung swiftpm-testing-helper processes from the pre-fix repro were killed during cleanup.
  timestamp: 2026-07-27T22:28:44.731272+00:00
depends_on:
- 01KYD58WPKKF4BAN3AKFZV61KY
position_column: doing
position_ordinal: '80'
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
