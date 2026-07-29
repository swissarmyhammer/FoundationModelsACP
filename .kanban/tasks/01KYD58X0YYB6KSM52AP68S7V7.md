---
comments:
- actor: claude-code
  id: 01kypysdqzvr6xeb3tj2qx948y
  text: |-
    Progress so far:

    - Recovered Transport/ReplayTransport.swift from git history (commit 02964e23^) — protocol-agnostic as expected, ported verbatim with updated doc comments explaining WHY it's unsuitable for scripting an agent's own outbound reactive calls (e.g. session/request_permission): the whole script is queued into `bytes` at construction, not paced by consumption, so a live Connection's read loop can race ahead of an outbound call's pending-continuation registration. This governs where ReplayTransport gets used below.
    - Added `exclude: ["Fixtures"]` back to the FoundationModelsACPTests test target in Package.swift, plus Tests/FoundationModelsACPTests/Fixtures/README.md documenting the fixture set and the RECORD_GOLDEN convention.
    - Added Tests/FoundationModelsACPTests/RoutingCoverageTests.swift: end-to-end routing coverage extending M2's static RoleRoutingTests (RoleDispatchTests.swift) with live-connection dispatch. RoleRoutingTests only checks ACPMethodTable's internal consistency; it never calls AgentSideConnection.serve/serveNotification or ClientSideConnection's equivalents, so a mis-wired case label there (the real TS-SDK setSessionModel/session_set_mode bug class) would slip past it silently. RoutingCoverageTests drives every one of the 11 agent-side and 2 client-side stable handlers through a live InMemoryTransport pair with recording Agent/Client stand-ins, asserting exactly the right handler fires.
      - Verified via mutation testing (per task instructions): swapped the "newSession"/"resumeSession" case labels in AgentSideConnection.serve (bodies untouched) — test failed (decode error surfaced). Reverted, then separately renamed "closeSession"'s case label to "deleteSession" (shadowing the real deleteSession case, orphaning closeSession behind default) — test failed on a methodNotFound error for closeSession. Reverted both; `git diff --stat` on AgentSideConnection.swift is clean and RoutingCoverageTests passes again.
      - Did NOT touch `nextRequestID` in Connection.swift at any point.

    Next: ReplayTransport unit tests (mechanics + a fixture-driven decode/re-encode round trip covering session-level unknown-value preservation), a live-pair GoldenSessionEndToEnd test covering the full representative session (initialize/session/new/prompt/streamed messages/tool call+content chunks/terminal/permission request/idle) with a checked-in golden fixture, an out-of-order/late-update convergence test, and the third-party-interop deferral writeup.
  timestamp: 2026-07-29T12:49:59.551343+00:00
- actor: claude-code
  id: 01kypzhkv3567q4zqgg26c2pbx
  text: |-
    Implementation complete, verified green, and adversarially reviewed (double-check agent: PASS, no findings).

    Final state:
    - swift build: clean, 0 warnings.
    - swift build --build-tests: clean, 0 warnings.
    - swift test: FoundationModelsACPTests 247 tests / 23 suites passed; ACPGenerateTests 95 tests / 12 suites passed. Total 342 tests / 35 suites, 0 failures — up from the stated 331/31 baseline by exactly the 11 tests / 4 suites this task added.
    - PromptLifecycleTests --maximum-repetitions 30: still green (Connection.swift itself untouched; nextRequestID untouched).

    Files added: Sources/FoundationModelsACP/Transport/ReplayTransport.swift; Tests/FoundationModelsACPTests/{GoldenFixtureSupport,ReplayTransportTests,GoldenSessionEndToEndTests,OutOfOrderConvergenceTests,RoutingCoverageTests,ThirdPartyInterop}.swift; Tests/FoundationModelsACPTests/Fixtures/{README.md,replay-script.ndjson,replay-golden.ndjson,unknown-values-transcript.ndjson,full-session-agent.ndjson}. Package.swift: re-added exclude: ["Fixtures"]. plan.md: M9 checked off with a summary note, including the wrap-up line that this closes the last open v2-reset milestone.

    Updated the task's own Acceptance Criteria and Tests checkboxes to [x] with pointers to the exact test/file satisfying each. Filed follow-up task ^dsefdb7 for the deferred third-party interop round trip.

    Leaving in doing per the /implement workflow — ready for /review.
  timestamp: 2026-07-29T13:03:12.227887+00:00
- actor: claude-code
  id: 01kyq1aen9z9z0mr9jssghcjhx
  text: |-
    Re-implemented against a fresh 13-item review-findings checklist (2026-07-29 08:11).

    Priority security finding (items 2, 4): GoldenFixtureSupport.swift's fixture()/expectGolden() passed an unvalidated name to appendingPathComponent(). Added a shared requireSafeFixtureName(_:) helper throwing InvalidFixtureName for empty names or names containing "/" or "..", called before either function builds its URL. Test-only code with hardcoded fixture literals, so not currently exploitable, but now hardened against a future untrusted caller.

    Parameter-label findings (items 1, 3, 5, 6, 8, 9, 10, 11, 12): added explicit labels to all flagged bare _: first parameters, matching the codebase's established convention (labeled unless value-preserving conversion): fixture(named:), expectGolden(actual:matchesFixture:), textLines(from:), send(update:) (13 call sites in GoldenSessionEndToEndTests.swift), envelope(for:) (OutOfOrderConvergenceTests.swift), sessionUpdateEnvelope(for:) (ReplayTransportTests.swift, 2 call sites), record(name:) (RoutingCoverageTests.swift, 13 call sites), driveAgentHandler(named:client:), driveClientHandler(named:agentConnection:). Every call site across the test target was grepped and updated; no orphaned bare-arg calls remain.

    Magic number (item 7): GoldenSessionEndToEndTests.swift's hardcoded .timeLimit(.minutes(1)) replaced with file-scope private let standardTestTimeout = 1  // minute, matching the exact pattern already established in PromptLifecycleTests.swift.

    Dead-code marker (item 13): ThirdPartyInterop.swift's ThirdPartyInteropDeferred enum had no inbound callers. Added an explicit reference to follow-up task ^dsefdb7 in its doc comment, plus a new ThirdPartyInteropDeferralTests suite with one trivial test referencing the type (ObjectIdentifier self-equality, deliberately trivial — its purpose is only to supply a real inbound caller, not behavioral coverage) with a failure message pointing back at the doc comment and ^dsefdb7.

    Verification: swift build --build-tests clean (0 warnings). swift test: 248 tests/24 suites + 95 tests/12 suites = 343 tests/36 suites, 0 failures, 0 warnings (baseline was 342/35; +1 test/+1 suite is exactly the new ThirdPartyInteropDeferralTests). git diff --stat on Sources/FoundationModelsACP/Connection.swift is empty (untouched). LSP diagnostics on working tree: 0 errors/0 warnings. No swift format run; git diff --ignore-all-space matches the normal diff exactly (no reformatting churn). double-check agent ran an independent adversarial pass (fresh git diff read, fresh build+test run, edge-case check on the path-traversal guard, confirmed follow-up task ^dsefdb7 is real) and returned PASS with no blocking findings — only a noted, harmless trade-off (the "..\" substring guard is intentionally over-broad, e.g. would reject a hypothetical "foo..bar" fixture name even though it can't escape the directory; none of the four real fixture files hit this).

    Leaving in doing per the /implement workflow — ready for /review.
  timestamp: 2026-07-29T13:34:14.697112+00:00
depends_on:
- 01KYD58WZE2TDS3MEJXQ9S8M89
position_column: doing
position_ordinal: '80'
title: M9 Replay fixtures and third-party interop
---
## Starting point

**This is a rewrite.** `plan.md` -> *Starting point* has the full inventory.

`Transport/ReplayTransport.swift` existed in v1 and was deleted, along with `GoldenReplayTests`, `ReplayTransportTests`, `EndToEndTests`, `WireConformanceTests`, `SchemaFixtureTests`, `MetaPreservationTests`, and their ndJSON transcript fixtures. All of it is in git history.

The transport mechanism itself is protocol-version-agnostic — recover it. The **fixtures** are not: every recorded v1 transcript is worthless against v2 (`session/prompt` no longer completes, `fs/*` and `terminal/*` frames are gone, `messageId` is now required). Record fresh v2 transcripts; do not attempt to migrate the old ones.

Note that `Package.swift` previously carried an `exclude: ["Fixtures"]` on the wire test target because transcripts were loaded via `#filePath` rather than as bundle resources. That target no longer exists; re-add the exclusion when you recreate it.

## What

`plan.md` -> **M9** and **Testing strategy**.

ndJSON makes a session trivially recordable -- tee the byte stream and you have a replayable script. Turn that into the package's regression spine.

- **`ReplayTransport`** replays a recorded client<->agent script against golden fixtures, asserting framing, ordering, upsert application, late/out-of-order updates, and `stopReason`. Deterministic: no model, no network, no clock.
- **Golden fixtures** for a representative full session: initialize, `session/new`, prompt, streamed messages, a tool call with content chunks, a permission request, and an idle close. Include a display terminal **only if M0 confirmed terminal updates exist in the v2 schema**.
- **Routing coverage** asserting every method reaches the correct side's handler -- the structural guard against the wrong-wiring bug class this package exists to avoid.
- **Unknown-value preservation** across a full recorded session, not just unit-level: decode, re-encode, diff.
- **Third-party interop:** once any real v2 agent or client exists, run a live round trip against it. Until then, record why it is deferred rather than leaving a silently unchecked claim. This is the only test that can falsify "we implement v2" as opposed to "we implement our reading of v2" -- especially important because v2 is **draft** and our plan was written from a handful of doc pages plus the migration guide, which has already proven to run ahead of the schema.

## Acceptance Criteria

- [x] `ReplayTransport` replays recorded scripts deterministically. Recovered from git history (protocol-version-agnostic), re-tested on its own mechanics in `ReplayTransportTests`, and used as the vehicle for the session-level unknown-value transcript and (via manual decode loop) the out-of-order convergence fixture. Deliberately NOT used to drive the permission-inclusive golden session — see `ReplayTransport`'s own doc comment for the correlation hazard that would introduce (the whole script is queued into `bytes` at construction, not paced by consumption, so a live `Connection`'s read loop can race ahead of an outbound call's pending-continuation registration).
- [x] Golden fixtures cover the representative full session listed above, recorded fresh against v2. `GoldenSessionEndToEndTests` drives initialize / session/new / session/prompt / streamed thought+message chunks / a tool call with a content chunk and a display terminal reference / the terminal's own upserts / a session/request_permission round trip / the closing idle, over a live InMemoryTransport pair (not ReplayTransport, for the correlation reason above), captured byte-for-byte against `Fixtures/full-session-agent.ndjson`.
- [x] Routing coverage asserts every method / side pair. `RoutingCoverageTests` extends M2's static `RoleRoutingTests` (`RoleDispatchTests.swift`) with live-connection dispatch of all 11 agent-side and 2 client-side stable handlers through recording Agent/Client stand-ins.
- [x] Session-level unknown-value preservation asserted. `ReplayTransportTests.aFullSessionTranscriptWithUnknownValuesRoundTripsLosslessly` decodes a multi-frame transcript (unknown session/update variant, unknown tool-call status, unknown plan-update tag, unknown stopReason, `_`-prefixed `_meta` extensions), re-encodes, and diffs byte-for-byte against the original.
- [x] Third-party interop either run, or explicitly deferred with a stated reason. Explicitly deferred — see `Tests/FoundationModelsACPTests/ThirdPartyInterop.swift` for the full reasoning (no real v2 agent/client exists yet; a self-mocked "interop" test cannot falsify "we implement v2" vs "we implement our reading of v2") and follow-up task ^dsefdb7.

## Tests

- [x] Replay of the golden session reproduces expected state exactly. `GoldenSessionEndToEndTests` (live pair, byte fixture) plus `ReplayTransportTests.replayedFixtureCapturesEmissionsMatchingGoldenFile` (ReplayTransport, byte fixture).
- [x] A fixture with late and out-of-order updates still converges correctly. `OutOfOrderConvergenceTests.lateAndOutOfOrderUpdatesStillConvergeCorrectly` — a scrambled `session/update` transcript replayed through `ReplayTransport`, decoded and applied to a `SessionUpdateAggregator`.
- [x] A fixture containing unknown enum cases and `_`-prefixed extensions round-trips losslessly. See above.
- [x] Every method appears in routing coverage; a deliberately mis-wired route fails the test (verified, then reverted). Verified via two separate mutations in `AgentSideConnection.serve` (a swapped case-label pair between "newSession"/"resumeSession", and a shadowed "closeSession"/"deleteSession" case) — both made the corresponding `RoutingCoverageTests` test fail, both reverted; `git diff --stat` on `AgentSideConnection.swift` confirmed clean afterward.

## Review Findings (2026-07-29 08:11)

- [x] `Tests/FoundationModelsACPTests/GoldenFixtureSupport.swift:16` — First argument label omitted. Fixed: `fixture(_:)` renamed to `fixture(named:)`; call site in `ReplayTransportTests.swift` updated.
- [x] `Tests/FoundationModelsACPTests/GoldenFixtureSupport.swift:17` — Path traversal vulnerability. Fixed: added a shared `requireSafeFixtureName(_:)` helper (throws `InvalidFixtureName`) rejecting empty names or names containing `/` or `..`, called at the top of `fixture(named:)` before constructing the URL.
- [x] `Tests/FoundationModelsACPTests/GoldenFixtureSupport.swift:24` — First argument label omitted. Fixed: `expectGolden(_:matchesFixture:...)` renamed to `expectGolden(actual:matchesFixture:...)`; all 3 call sites (`GoldenSessionEndToEndTests.swift`, `ReplayTransportTests.swift` x2) updated.
- [x] `Tests/FoundationModelsACPTests/GoldenFixtureSupport.swift:46` — Path traversal vulnerability. Fixed: `expectGolden` now calls the same `requireSafeFixtureName(_:)` guard before building its URL.
- [x] `Tests/FoundationModelsACPTests/GoldenFixtureSupport.swift:62` — First argument label omitted. Fixed: `textLines(_:)` renamed to `textLines(from:)`; both call sites in `reportGoldenDrift` updated.
- [x] `Tests/FoundationModelsACPTests/GoldenSessionEndToEndTests.swift:176` — First argument label omitted. Fixed: `send(_:)` renamed to `send(update:)`; all 13 call sites in `runTurn` updated.
- [x] `Tests/FoundationModelsACPTests/GoldenSessionEndToEndTests.swift:208` — Hardcoded timeout. Fixed: added file-scope `private let standardTestTimeout = 1  // minute` (matching the exact convention already used in `PromptLifecycleTests.swift`), referenced as `.timeLimit(.minutes(standardTestTimeout))`.
- [x] `Tests/FoundationModelsACPTests/OutOfOrderConvergenceTests.swift:28` — First argument label omitted. Fixed: `envelope(_:)` renamed to `envelope(for:)`; call site updated.
- [x] `Tests/FoundationModelsACPTests/ReplayTransportTests.swift:70` — First argument label omitted. Fixed: `sessionUpdateEnvelope(_:)` renamed to `sessionUpdateEnvelope(for:)`; both call sites updated.
- [x] `Tests/FoundationModelsACPTests/RoutingCoverageTests.swift:25` — First argument label omitted. Fixed: `record(_:)` renamed to `record(name:)`; all 13 `log.record(...)` call sites updated.
- [x] `Tests/FoundationModelsACPTests/RoutingCoverageTests.swift:112` — First argument label omitted. Fixed: `driveAgentHandler(_:client:)` renamed to `driveAgentHandler(named:client:)`; call site updated.
- [x] `Tests/FoundationModelsACPTests/RoutingCoverageTests.swift:149` — First argument label omitted. Fixed: `driveClientHandler(_:agentConnection:)` renamed to `driveClientHandler(named:agentConnection:)`; call site updated.
- [x] `Tests/FoundationModelsACPTests/ThirdPartyInterop.swift:38` — `ThirdPartyInteropDeferred` had no inbound callers. Fixed: doc comment now explicitly cites follow-up kanban task `^dsefdb7`, and a new `ThirdPartyInteropDeferralTests` suite adds one trivial `@Test` that references the type (via `ObjectIdentifier` equality) with a failure message pointing back at the doc comment and `^dsefdb7` — giving the symbol a real inbound caller.
