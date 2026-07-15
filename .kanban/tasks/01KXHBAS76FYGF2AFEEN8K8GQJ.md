---
comments:
- actor: wballard
  id: 01kxhwvzdkq9jvdvjj8q1jhwcg
  text: |-
    Implementation landed via TDD (9 new tests written first, watched RED — missing-type build failure — then GREEN). Full suite: 82 tests (46 + 36), exit 0, zero warnings. Double-check verdict: PASS.

    Decisions later connection/e2e tasks should know:

    - `InMemoryTransport` (Sources/FoundationModelsACP/Transport/InMemoryTransport.swift): struct, compiler-checked Sendable. `pair()` returns two connected ends (role-symmetric — assign client/agent arbitrarily). Semantics mirror a pipe HALF-CLOSE: `a.close()` finishes b's `bytes` stream (after delivering buffered chunks) but leaves b→a open until b closes. `write` throws `InMemoryTransport.ClosedError` when the outgoing direction is terminated (self-closed OR peer stopped consuming). No backpressure — unbounded AsyncThrowingStream buffering, fine for test infra.
    - `ReplayTransport` (Sources/FoundationModelsACP/Transport/ReplayTransport.swift): final class, Mutex<Data>-guarded capture (import Synchronization). `init(script:)` splits the raw ndJSON script eagerly, yields one line per chunk WITH its trailing \n (unterminated final line fed as-is, empty script finishes immediately), then finishes. `capturedOutput: Data` is the raw ndJSON written so far — same format as the script, so captures can be committed directly as golden fixtures.
    - Golden-file determinism: NDJSONCodec.encode's [.sortedKeys, .withoutEscapingSlashes] makes emitted bytes stable; fixtures use STRING JSON-RPC ids ("req-1") to sidestep Double formatting of JSONValue.number in goldens.
    - Fixtures live in Tests/FoundationModelsACPTests/Fixtures/ loaded via #filePath (same pattern as SchemaFixtureTests), and Package.swift excludes "Fixtures" from the test target — they are not bundle resources.
    - Swift toolchain gotcha: the pattern `case .string(let m)? = dict["k"]` crashed the Xcode-beta frontend diagnostic path; `case .string(let m) = dict["k", default: .null]` is the safe spelling used in tests.
  timestamp: 2026-07-15T03:24:32.051068+00:00
- actor: wballard
  id: 01kxhxkthhn2ywsf8kn9s51hhe
  text: |-
    Review pass on checkpoint 89a252c (HEAD~1..HEAD) came back clean: 0 findings, 14/14 checks, 0 failed (first attempt had 1 engine subtask fail with 0 findings; re-run completed clean). Task done in two implement→test→commit→review iterations — iteration 1 landed the transports (checkpoint 2f8b904), iteration 2 fixed 3 doc-comment findings on the public `bytes` properties (checkpoint 89a252c).

    For downstream connection/e2e tasks (^qtbq9t, ^2x6ra0): wire back-to-back tests with `let (client, agent) = InMemoryTransport.pair()` — remember half-close semantics (`close()` finishes only the peer's incoming stream; close both ends to finish both directions). For golden replay tests, `ReplayTransport(script:)` + drive the agent loop + compare `capturedOutput` byte-for-byte against a committed fixture; keep JSON-RPC ids as strings in fixtures to avoid Double formatting drift. Fixtures pattern: Tests/FoundationModelsACPTests/Fixtures/ via #filePath, excluded in Package.swift.
  timestamp: 2026-07-15T03:37:33.489329+00:00
depends_on:
- 01KXHBADH1XF34Q5C911R8GYD6
position_column: done
position_ordinal: '8580'
title: InMemoryTransport and ReplayTransport test infrastructure
---
## What
Ship the two test transports (spec §8) against the transport abstraction from the ndJSON codec task, in `Sources/FoundationModelsACP/Transport/`:

- `InMemoryTransport` — a pair of in-process `AsyncStream`s (as `rebornix/acp-swift-sdk` does) so a `Client` and `Agent` can be wired back-to-back in one test with no pipes or subprocess. `InMemoryTransport.pair()` returns two connected ends.
- `ReplayTransport` — feeds a recorded client→agent ndJSON script line by line and captures everything the agent emits, so a test can assert the emitted `session/update` sequence against a golden fixture. Recording format = the raw ndJSON byte stream (spec §8: tee the stream while it runs and you have a replayable script).

These live in the main target (they're useful to consumers' tests too), with no test-only dependencies.

## Acceptance Criteria
- [x] Two codec instances over `InMemoryTransport.pair()` exchange messages in both directions concurrently
- [x] `ReplayTransport` replays a fixture script and exposes captured output for assertion, deterministically across runs

## Tests
- [x] `Tests/FoundationModelsACPTests/InMemoryTransportTests.swift` — bidirectional concurrent exchange, stream finish on close
- [x] `Tests/FoundationModelsACPTests/ReplayTransportTests.swift` — replay a small fixture, assert captured emissions match a golden file
- [x] Run `swift test` — exits 0

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-07-14 22:25)

- [x] `Sources/FoundationModelsACP/Transport/InMemoryTransport.swift:15` — `bytes` is a public property but has no documentation comment. Public declarations require `///` documentation to describe the property's purpose and role in the API. Add a `///` documentation comment above the `bytes` property. For example: `/// Delivers incoming messages from the peer, finishing when the peer closes its outgoing direction.`.
- [x] `Sources/FoundationModelsACP/Transport/ReplayTransport.swift:13` — Public property `bytes` lacks documentation — callers need to understand what stream this provides and how to use it. Add a documentation comment above line 13 describing what `bytes` represents, e.g. the replayed script stream being fed line by line.
- [x] `Sources/FoundationModelsACP/Transport/ReplayTransport.swift:16` — `bytes` is a public property but has no documentation comment. Public declarations require `///` documentation to describe the property's purpose and role in the API. Add a `///` documentation comment above the `bytes` property. For example: `/// The replayed script, delivered one line per chunk until exhausted.`.