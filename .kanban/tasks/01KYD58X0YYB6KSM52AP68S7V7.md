---
depends_on:
- 01KYD58WZE2TDS3MEJXQ9S8M89
position_column: todo
position_ordinal: '8980'
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

- [ ] `ReplayTransport` replays recorded scripts deterministically.
- [ ] Golden fixtures cover the representative full session listed above, recorded fresh against v2.
- [ ] Routing coverage asserts every method / side pair.
- [ ] Session-level unknown-value preservation asserted.
- [ ] Third-party interop either run, or explicitly deferred with a stated reason.

## Tests

- [ ] Replay of the golden session reproduces expected state exactly.
- [ ] A fixture with late and out-of-order updates still converges correctly.
- [ ] A fixture containing unknown enum cases and `_`-prefixed extensions round-trips losslessly.
- [ ] Every method appears in routing coverage; a deliberately mis-wired route fails the test (verified, then reverted).
