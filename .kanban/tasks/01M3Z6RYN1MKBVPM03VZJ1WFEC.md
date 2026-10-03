---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m40va9p5e5m8hwf5aqn7ephn
  text: |-
    Research done.
    - The engine (Session/SessionMergeEngine.swift) routes all entry kinds through one generic `upsert(id, initial:, extract:, embed:, change:)`. Compaction uses the same path.
    - `Unstable.SessionUpdate.init?(_:) throws` reads the three unstable types from `SessionUpdate.unknown`. The engine calls it in the `.unknown` case.
    - Decision: a known unstable type whose payload does not decode (init throws) stays an `unknown` entry, the same as each other undecodable update. The engine does not crash and does not drop the update.
    - Decision: the entry kind is a new `SessionEntry.Compaction` struct (`compactionId`, `status`, `summary: [ContentBlock]`, `error: PatchField<String>`, `meta: PatchField<JSONValue>`), the same shape as `SessionEntry.Message`. An update folds with the generated `Unstable.CompactionUpdate.folded(onto:)`.
    - Decision: a chunk before an update makes the entry with status `Unstable.CompactionStatus.unknown("")` (public constant `SessionEntry.Compaction.unreportedStatus`). This value round-trips on the wire, so the replay of such an entry gives the same entry.
    - Chunk `_meta` folds onto the compaction `_meta`, the same as the other chunk kinds in the engine.
    - Replay encodes through `SessionUpdate.init(_ update: Unstable.SessionUpdate) throws`. Each compaction value came from a JSON decode, so the encode cannot fail; a failure is a defect (preconditionFailure), the same as the existing upsert invariant.
  timestamp: 2026-10-03T12:20:11.589404+00:00
- actor: claude-code
  id: 01m40vgtsqzvdvsr7p3wbn1vmk
  text: |-
    Implementation landed (TDD: RED was a compile failure on the missing API; GREEN after the change).

    Public names:
    - `SessionEntry.ID.compaction(Unstable.CompactionId)`
    - `SessionEntry.Kind.compaction(SessionEntry.Compaction)`
    - `public struct SessionEntry.Compaction: Hashable, Sendable` with `compactionId: Unstable.CompactionId`, `status: Unstable.CompactionStatus`, `summary: [ContentBlock]`, `error: PatchField<String>`, `meta: PatchField<JSONValue>`, and `static let unreportedStatus = Unstable.CompactionStatus.unknown("")`
    - `SessionMergeEngine.Change.notice(Unstable.Notice)`

    Behavior:
    - First `compaction_update` adds the entry at the end; a later one folds with the generated `Unstable.CompactionUpdate.folded(onto:)`. `summary: []` and `summary: null` clear the summary.
    - `compaction_summary_chunk` appends one block; chunk `_meta` folds onto the compaction `_meta`. A chunk before any update makes the entry with `unreportedStatus`.
    - `notice` returns `.notice(n)`; the engine state does not change; nothing replays.
    - A known unstable type with a malformed payload stays an `unknown` entry (no crash, no drop).
    - `transcriptUpdates` replays each compaction as one `compaction_update` (final status, summary, error, meta) at its position.

    Open for the push step: send the new names to `foundationmodelsacpclient-ae` and `foundationmodelsacpagent-bb` (the card says "when pushed"; this step does not commit or push).
  timestamp: 2026-10-03T12:23:45.719344+00:00
- actor: claude-code
  id: 01m40vgwq2ndrbgv6mz793g271
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsACP/Session/SessionEntry.swift, Sources/FoundationModelsACP/Session/SessionMergeEngine.swift, Tests/FoundationModelsACPTests/SessionMergeEngineCompactionTests.swift (new, 13 tests), Tests/FoundationModelsACPTests/SessionMergeEngineTests.swift (replay round trip covers two compaction entries). `swift build --build-tests`: 0 warnings, 0 errors. `swift test`: 439 + 128 tests pass, 0 failures. `swift package generate-documentation --target FoundationModelsACP --warnings-as-errors`: passes.
    - next: /review
  timestamp: 2026-10-03T12:23:47.682262+00:00
- actor: claude-code
  id: 01m40vnatvzqvnyz8v4y6ydytw
  text: |-
    ### implement — changed (coordinator correction)
    - Change: `SessionEntry.Compaction.unreportedStatus` is now `Unstable.CompactionStatus.unknown("_unreported")`, not `.unknown("")`. Reason: the unstable schema keeps `CompactionStatus` values that begin with `_` for implementation-specific extensions, and values that do not begin with `_` for future ACP statuses. An empty string does not conform. The DocC on `unreportedStatus` now gives this reason.
    - TDD: the new test `theReplayOfAnUnreportedCompactionSendsAnExtensionStatus` failed first (the replay sent `""`), then passed. The replay round-trip test now also checks that the replayed compaction with no status has status `.unknown("_unreported")`.
    - evidence: Sources/FoundationModelsACP/Session/SessionEntry.swift, Tests/FoundationModelsACPTests/SessionMergeEngineCompactionTests.swift, Tests/FoundationModelsACPTests/SessionMergeEngineTests.swift. `swift build --build-tests`: 0 warnings, 0 errors. Affected tests (SessionMergeEngine, UnstableSessionUpdate, UnstableCompactionNotice filters): 82 + 2 pass. DocC with `--warnings-as-errors`: passes.
    - next: /test
  timestamp: 2026-10-03T12:26:13.211665+00:00
- actor: claude-code
  id: 01m40vxhx7r07at1dwj6vm60ff
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (081cad7). 0 findings (attempted 7, failed 0, skipped 0). 4 files reviewed. 2 .kanban files not reviewed because of .reviewignore.
    - next: The task is in done. Send the new names to foundationmodelsacpclient-ae and foundationmodelsacpagent-bb, as the acceptance criteria tell.
  timestamp: 2026-10-03T12:30:42.599100+00:00
- actor: claude-code
  id: 01m40vxsf4kycgm7y2r1jpb303
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 4 files, compaction entries, Change.notice, _unreported extension status
    - test: green — scratch-path build 0 warnings; swift test 440+128 passed; IntegrationTests 7 passed
    - commit: 081cad7
    - review: clean — 0 findings; task moved to done
  timestamp: 2026-10-03T12:30:50.340308+00:00
depends_on:
- 01M3Z6RMQ8PXEGNY5VAK55FG8A
position_column: done
position_ordinal: a580
title: 'Merge engine: compaction entries and live notices'
---
## What

Teach `SessionMergeEngine` the unstable compaction and notice updates from ^k55fg8a.

## Rule from the user (2026-10-02)

Compaction is ONLY about what the agent keeps in its model context. The protocol transcript keeps the whole history, and the view stays valid: nothing is lost or compacted in it. Thus:
- A compaction is ONE MORE transcript entry (a marker with its status and summary). The engine NEVER removes or changes earlier entries because of a compaction.
- There is NO trim API. Retained history = the full transcript, including compaction entries. `transcriptUpdates` replays all of it.

## Engine changes

1. `SessionEntry.ID.compaction(CompactionId)` and a kind such as `.compaction(Compaction)` with `status`, `summary: [ContentBlock]`, `error`, `meta`.
2. `compaction_update`: the first update for an ID adds the entry at the end (its position is then fixed). A later update with the same ID folds onto it with the generated `folded(onto:)` (patch semantics; `summary: []` clears). Returns `entryAdded` / `entryChanged`.
3. `compaction_summary_chunk`: appends one content block to the summary of that compaction. If the ID is not known yet, create the entry (status unknown until an update arrives), the same way the engine treats other early chunks.
4. `notice`: NOT stored and NOT replayed ("live events rather than session history"). `apply` returns a new `Change.notice(Unstable.Notice)` so a client model can show it.
5. `transcriptUpdates` replays each compaction as one `compaction_update` with its final status and summary, in its position, with its ID.
6. Unknown types stay `unknown` entries as now.

## Acceptance criteria

- Tests: update then update (patch), chunk appends, chunk before update, `summary: []` clears, earlier entries are not changed by a compaction, position stays fixed when later entries arrive, notice is returned but not stored and not replayed.
- The replay round-trip test also covers a compaction entry.
- `swift build --build-tests` has 0 warnings; `swift test` passes; DocC with `--warnings-as-errors` passes.
- When pushed, send the new names to `foundationmodelsacpclient-ae` (SessionModel shows the compaction entry and notices) and `foundationmodelsacpagent-bb` (agent maps Router compaction to these updates).