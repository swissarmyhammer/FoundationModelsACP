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
- actor: claude-code
  id: 01kyjwmxhq3sh7eqxx310qqgwy
  text: |-
    Resolved the review finding on `RoleDispatch.serveEmpty`.

    Verified before deleting: repo-wide grep (source + tests) for `serveEmpty` found exactly one non-definition hit, a docstring reference in `serve`'s comment — zero real call sites anywhere. Confirmed with the earlier port notes on this task that v2's Agent/Client methods all return typed responses, so there's no missing void-handler wiring to add in a follow-up; this is pure v1-port scaffolding that doesn't apply to v2.

    Deleted:
    - `serveEmpty` function + its docstring.
    - `emptyResult`, the constant that existed solely to support `serveEmpty` (grep confirmed zero other callers) — it became newly dead once `serveEmpty` was removed, so left in place would have just been the next dead-code finding.
    - Corrected the private `serve` helper's docstring, which named both `serveResult` and `serveEmpty` as its callers; now says just `serveResult`.

    Verified clean (rm -rf .build, fresh rebuild): `swift build --build-tests` 0 errors/0 warnings. `swift test` 214 tests / 21 suites / 0 failures (139/11 + 75/10) — identical to the pre-existing baseline, confirming nothing was quietly depending on the removed code. No swift format run. Diff scoped to RoleDispatch.swift only; no generated-code drift.

    Adversarial double-check dispatched; will record its verdict once it returns.
  timestamp: 2026-07-27T22:55:37.015384+00:00
- actor: claude-code
  id: 01kyjww73n6g2rzwje02kkd635
  text: |-
    Adversarial double-check verdict: PASS.

    Confirmed independently: `serveEmpty` and `emptyResult` have zero remaining references anywhere in the repo outside this task's own description text. Removing `emptyResult` alongside `serveEmpty` was judged the right call, not scope creep, since it became dead the instant its only caller was deleted. The rewritten `serve` docstring reads correctly standalone. Fresh `swift build --build-tests`: 0 errors/0 warnings. Fresh `swift test`: 214 tests/21 suites/0 failures (139/11 + 75/10), matching the pre-existing baseline exactly. Diff scope confirmed limited to `RoleDispatch.swift` plus kanban bookkeeping.

    Review finding resolved. Task is green; leaving in `doing` for `/review`.
  timestamp: 2026-07-27T22:59:36.181694+00:00
- actor: claude-code
  id: 01kyjxcxstpy8hzs3qq0f1szmy
  text: |-
    Resolved the 2026-07-27 18:02 review finding on `decodeParams` (RoleDispatch.swift).

    `decodeParams` reimplemented the encode-then-decode pattern already provided by the `decoded(as:)` instance method a few lines below it in the same `extension JSONValue`. Rewrote the body to call `decoded(as:)`:

    ```swift
    do {
        return try (params ?? .object([:])).decoded(as: modelType)
    } catch {
        throw RequestError.invalidParams
    }
    ```

    Deviated from the finding's literal suggested one-liner (which dropped the do/catch entirely) because that would have leaked the raw `DecodingError` on a shape mismatch instead of `RequestError.invalidParams` — breaking the existing test `decodeParamsThrowsInvalidParamsOnAMismatchedShape` in RoleDispatchTests.swift, which asserts `error.code == .invalidParams`. Kept the do/catch wrapper so the nil-becomes-empty-object behavior and the invalidParams conversion are both preserved; only the duplicated JSONEncoder/JSONDecoder lines were removed.

    Verified three call sites (grep for `decodeParams(`): the private `serve` helper in this file, and `try?`-guarded calls in AgentSideConnection.swift and ClientSideConnection.swift — none depend on the internal exception type, so this is behavior-preserving for all of them.

    Verified: `swift build --build-tests` — 0 errors, 0 warnings. `swift test` — 139 tests/11 suites + 75 tests/10 suites = 214 tests/21 suites, 0 failures — identical to the pre-existing baseline, confirming this is a pure refactor. No swift format run. Diff scoped to RoleDispatch.swift only (plus this kanban bookkeeping).

    Adversarial double-check dispatched; will record its verdict once it returns.
  timestamp: 2026-07-27T23:08:43.706905+00:00
- actor: claude-code
  id: 01kyjxeea2ttq7ngxc4x2d6dbc
  text: |-
    Adversarial double-check verdict: PASS, no findings.

    Confirmed independently: the diff is exactly the described 2-line-removed/1-line-added change in RoleDispatch.swift, the do/catch and invalidParams conversion are preserved, the nil-to-empty-object coalescing is unchanged, and none of the three call sites (serve, AgentSideConnection.swift, ClientSideConnection.swift) depend on the concrete thrown-error type. Fresh `swift build --build-tests`: 0 errors/0 warnings. Fresh `swift test`: 139+75 = 214 tests across 11+10 = 21 suites, 0 failures. Diff scope confirmed limited to RoleDispatch.swift plus kanban bookkeeping.

    Review finding resolved. Task is green; leaving in `doing` for `/review`.
  timestamp: 2026-07-27T23:09:33.378949+00:00
- actor: claude-code
  id: 01kyjxz0ya0csxejacmww9ptpf
  text: |-
    Resolved the 2026-07-27 18:13 review finding on RoleDispatch.swift.

    Confirmed current signatures before editing: `static func encode<Model: Encodable>(result: Model) throws -> JSONValue` and `func decoded<Model: Decodable>(as modelType: Model.Type) throws -> Model`, both in `extension JSONValue` — matches the finding's description, no signature drift from prior rounds.

    Extracted the shared transcode mechanics into a new `private static func transcode<From: Encodable, To: Decodable>(_ value: From, as toType: To.Type) throws -> To { try JSONDecoder().decode(toType, from: JSONEncoder().encode(value)) }` in the same extension. `encode` now calls `transcode(result, as: JSONValue.self)`. `decoded` calls `Self.transcode(self, as: modelType)` (`Self.` required since `transcode` is static and `decoded` is an instance method).

    Verified before changing: grep for `JSONValue.encode(result:` and `.decoded(as:` found 5 production call sites (RoleDispatch.swift itself x3, none depending on internal implementation) plus test call sites in SessionUpdateStreamTests.swift and RoleDispatchTests.swift — all exercise only the external signatures, unaffected by the internal dedup.

    Verified: clean rebuild (`rm -rf .build`) then `swift build --build-tests` — 0 errors, 0 warnings. `swift test` — 139 tests/11 suites + 75 tests/10 suites = 214 tests/21 suites, 0 failures — identical to the pre-existing baseline, confirming pure refactor. No swift format run. Diff scoped to RoleDispatch.swift only (plus kanban bookkeeping).

    Adversarial double-check dispatched; will record its verdict once it returns.
  timestamp: 2026-07-27T23:18:36.746665+00:00
- actor: claude-code
  id: 01kyjy3sq1es0h4s5j3cra3ydw
  text: |-
    Adversarial double-check verdict: PASS.

    Confirmed independently against the actual diff: `encode(result:)` and `decoded(as:)` keep their original external signatures; only bodies changed to call the new `private static func transcode<From: Encodable, To: Decodable>(_ value: From, as toType: To.Type) throws -> To`, correctly scoped inside the same `extension JSONValue` block. Verified `decoded`'s `Self.transcode(self, as: modelType)` is not just correct but required (an instance method cannot call a static member unqualified in Swift) — a small improvement over the finding's literal suggested snippet, which omitted the qualifier. All call sites of `encode`/`decoded` across Sources/ and Tests/ use only the unchanged external signatures. Fresh clean-rebuild `swift build --build-tests`: 0 errors/0 warnings. Fresh `swift test`: 139 tests/11 suites + 75 tests/10 suites = 214/21, 0 failures — identical to the pre-existing baseline. Diff scope confirmed limited to RoleDispatch.swift plus kanban bookkeeping.

    Review finding (2026-07-27 18:13) resolved and checked off. Task is green; leaving in `doing` for `/review`.

    Note: an unrelated tooling mishap occurred mid-task — two placeholder background agents were accidentally launched with empty/no-op prompts while waiting on the real double-check agent's result; neither touched any files or the kanban board, and both were harmless no-ops (one correctly returned REVISE for lacking a real task, one returned "ack"). Logged here for transparency; no code or task impact.
  timestamp: 2026-07-27T23:21:13.185238+00:00
- actor: claude-code
  id: 01kyjytnm8d9pbcaph8f349pm4
  text: |-
    Resolved the 2026-07-27 18:23 review findings on RoleDispatch.swift (round 4, both items).

    1. Renamed `RoleRouting.wire(handler:on:)` to `RoleRouting.wireMethod(for:on:)` — the `for:` label reads as "wire method for handler on side," removing the verb/noun ambiguity of the bare `wire` name. Updated every call site: the internal call inside `methodNotFound`, both call sites now routed through the new shared helper (see below), and the two test call sites in RoleDispatchTests.swift (`wireResolvesEveryAgentHandlerToItsRoutingTableWireMethod` / `wireResolvesEveryClientHandlerToItsRoutingTableWireMethod`). Repo-wide grep for `wire(handler:` and `RoleRouting.wire\b` after the change found zero remaining references outside this task's own historical description text. Confirmed AgentSideConnection.swift/ClientSideConnection.swift never called `wire` directly (they use the higher-level `notify`/`callResult`), so they needed no changes.

    2. Extracted the duplicated wire-method-resolution + params-encoding logic shared by `notify` and `call` into a new `private static func wireCall<Params: Encodable>(handler:on:_:) throws -> (method: String, params: JSONValue)`. Both `notify` and `call` now call it and only differ in which `connection` method (`notify` vs `request`) they hand the resolved tuple to.

    Verified current signatures/line numbers before editing rather than trusting the finding's cited numbers (per the note on this round) — matched what was there.

    Verified (clean rebuild, `rm -rf .build`): `swift build --build-tests` — 0 errors, 0 warnings. `swift test` — 139 tests/11 suites + 75 tests/10 suites = 214 tests/21 suites, 0 failures — identical to the pre-existing baseline, confirming pure rename/refactor. No swift format run. Diff scoped to RoleDispatch.swift + RoleDispatchTests.swift (plus kanban bookkeeping).

    Swept the rest of the file for further findings of this same class (dead code / naming ambiguity / duplicated encode-decode or param-prep logic): none found. `decodeParams`/`decoded`/`transcode`/`served`/`methodNotFound`/`serveResult`/`serve`/`callResult` all read clean with no remaining duplication.

    Adversarial double-check dispatched; will record its verdict once it returns.
  timestamp: 2026-07-27T23:33:42.664934+00:00
- actor: claude-code
  id: 01kyjz218rabrafdg1jjha32ar
  text: |-
    Adversarial double-check round 1 verdict: REVISE, one finding — not in the Swift code, but in this task's own bookkeeping. The finding confirmed the rename and wireCall extraction are correct, complete, consistent, and behavior-preserving (traced every call site, confirmed no ordering/error-type change since wireMethod cannot throw and encode is the only throwing step, and confirmed a fresh whole-file read found no further findings of this class). Its one actionable finding: the new "Review Findings (2026-07-27 18:23)" checklist items were added to the task description as unchecked ([ ]) even though both were fixed in the same diff and the accompanying progress comment said so — breaking the checked-off convention every prior round (17:35, 18:02, 18:13) followed.

    Fixed: flipped both 18:23 checklist bullets in the task description to [x], matching the established pattern.

    Re-verification not needed for this fix (kanban description edit only, no code touched). Swift verification from the prior comment stands: swift build --build-tests 0 errors/0 warnings; swift test 214 tests/21 suites/0 failures, matching baseline.

    Task is done and green. Leaving in doing for /review.
  timestamp: 2026-07-27T23:37:43.960900+00:00
- actor: claude-code
  id: 01kyjz4vyf848jeqe0vc3jc4ry
  text: |-
    Correction to the prior comment: my kanban `update task` call to flip the 18:23 checkboxes accidentally passed the description with literal backslash-n escape sequences instead of real newlines, collapsing the whole body into one line (visible as `\n` text in the raw .md file) and dropping progress to 0. Caught this by re-reading the task after the edit rather than trusting the "ok: true" response.

    Fixed by editing `.kanban/tasks/01KYD58WR23B5R69691FKDWJSG.md` directly (files op, not kanban update task) to restore proper multi-line markdown with real newlines, keeping both 18:23 checkboxes as `[x]`. Re-verified via `get task`: description now renders with real newlines, progress is back to a sane value (0.263, reflecting 5 of 19 total checklist items checked — the 6 resolved review findings across all four rounds, with Acceptance Criteria/Tests checkboxes still open as expected since those track the parent milestone, not this file's review rounds), and the task is still in the `doing` column.

    No code was touched by this correction — Sources/FoundationModelsACP/Connection/RoleDispatch.swift and RoleDispatchTests.swift are unaffected, and the prior swift build/test verification (214 tests/21 suites/0 failures, matching baseline) still stands.

    Task is done and green. Leaving in doing for /review.
  timestamp: 2026-07-27T23:39:16.815788+00:00
depends_on:
- 01KYD58WPKKF4BAN3AKFZV61KY
position_column: done
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

## Review Findings (2026-07-27 17:35)

Scope: `HEAD~1..HEAD` (6eb810d). Engine returned 7 findings; 6 were dropped under the review skill's blanket test-refactor exception (they asked only to deduplicate/restructure existing test code in `FactoryClosureTests.swift`, `InMemoryTransportTests.swift`, `StdioTransportTests.swift`, `SubprocessReapTests.swift` — recovered v1 tests retargeted to v2, out of scope per policy). One production-code finding stands:

- [x] `Sources/FoundationModelsACP/Connection/RoleDispatch.swift` — `serveEmpty` is added but never called anywhere in the codebase. It is not part of the public API surface (not marked `public`), not an entry point, and not a test. This is dead code that should be deleted. Delete the `serveEmpty` function definition and its docstring. If future handlers that return void are planned, add them and their calls in a follow-up task with that work, rather than shipping unused scaffolding now.

## Review Findings (2026-07-27 18:02)

Scope: `HEAD~1..HEAD` (05fc275).

- [x] `Sources/FoundationModelsACP/Connection/RoleDispatch.swift:17` — `decodeParams` reimplements the encode-decode pattern that the `decoded` instance method already provides. Both encode their input with JSONEncoder and decode it as a model type; `decodeParams` should call `decoded` instead to avoid duplication. Rewrite the function body to reuse `decoded`: `return try (params ?? .object([:]))` called with `.decoded(as: modelType)` to eliminate the duplicated encode-decode logic.

## Review Findings (2026-07-27 18:13)

Scope: `HEAD~1..HEAD` (bbe4d49).

- [x] `Sources/FoundationModelsACP/Connection/RoleDispatch.swift:24` — JSONValue.encode (line 24) and JSONValue.decoded (line 32) both contain the identical transcode pattern: `JSONDecoder().decode(TargetType, from: JSONEncoder().encode(source))`. These differ only in what is encoded and what type to decode to — one function with an argument waiting to be extracted. Extract a shared generic helper: `private static func transcode<From: Encodable, To: Decodable>(_ value: From, as toType: To.Type) throws -> To { try JSONDecoder().decode(toType, from: JSONEncoder().encode(value)) }`. Then update encode (line 24) to `return try transcode(result, as: JSONValue.self)` and decoded (line 32) to `return try transcode(self, as: modelType)`.

## Review Findings (2026-07-27 18:23)

Scope: `HEAD~1..HEAD` (90e5feb).

- [x] `Sources/FoundationModelsACP/Connection/RoleDispatch.swift:81` — Method `wire(handler:on:)` does not form a clear grammatical phrase at the call site. Reading 'wire handler on side' aloud is ambiguous; it's unclear whether 'wire' is a verb or noun, and the phrase lacks the clarity of idiomatic Swift method naming. Rename to `wireMethod(handler:on:)` (reads 'wire method [for] handler on side') or add a preposition like `wireMethod(for:on:)` to clarify the structure and improve readability at the call site.
- [x] `Sources/FoundationModelsACP/Connection/RoleDispatch.swift:191` — The parameter preparation logic (wire method resolution and params encoding) is duplicated between `notify` (lines 195–196) and `call` (lines 220–221). Both perform identical operations that could drift out of sync if one is updated but not the other. Extract a shared helper function that accepts a closure to handle the wire call difference, e.g., a `private static func wireCall<Request>(_:handler:on:_:with:)` that performs parameter preparation and then invokes the provided closure with the prepared values.
