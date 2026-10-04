---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m43jffhvsjsp3ww5592mme2f
  text: |-
    Research done. The wait condition is met: foundationmodelsacpclient-ae reported on 2026-10-04 that the client does not use the two APIs (commit a65af8a). The user approved the removal.

    Uses found:
    - Sources/FoundationModelsACP/Session/SessionUpdateAggregator.swift (the type).
    - ClientSideConnection.updates(for:) (deprecated wrapper on subscribe(to:)).
    - Tests/FoundationModelsACPTests/SessionUpdateAggregatorTests.swift: the aggregator suite (with @diagnose(DeprecatedDeclaration, as: ignored)) and TerminalContentPlacementTests (not about the aggregator; keep it in its own file).
    - SessionUpdateStreamTests.swift: two @available(*, deprecated) tests of updates(for:) and their MARK section. All shared helpers (createSession, startPrompt, promptAckEnvelope) have other users.
    - PatchFieldTests.swift: one doc comment names SessionUpdateAggregator.
    - README.md, plan.md, CONTRIBUTING.md and the two DocC catalogs have no references.

    Aggregator behaviors with no engine test: empty-array content clears a message; omitted content on a new message starts empty; unknown tool-call status survives; tool-call update content replaces, then chunks append; chunk after a cleared content; new terminal has every field unknown; non-UTF-8 chunk bytes; clear a field and replace output in one terminal_update; malformed base64 snapshot and chunk are dropped; two plan IDs do not interfere; state and usage updates add no transcript entry. These get engine tests. ToolCallUpdate.appendContent, PatchField.resolved(onto:) and AccumulatedTerminal stay in use by the engine.
  timestamp: 2026-10-04T13:43:27.547197+00:00
- actor: claude-code
  id: 01m43jpd0wfbps38p6knd0ddt1
  text: |-
    Implementation landed.

    - Deleted Sources/FoundationModelsACP/Session/SessionUpdateAggregator.swift and ClientSideConnection.updates(for:). AccumulatedTerminal stays (the engine uses it).
    - Deleted SessionUpdateAggregatorTests.swift with its @diagnose(DeprecatedDeclaration, as: ignored). Its unrelated suite TerminalContentPlacementTests moved to Tests/FoundationModelsACPTests/TerminalContentPlacementTests.swift. The move also replaced the two `guard case` blocks with exact `#expect` equality, because the swift optionals rule forbids `guard` in a test.
    - Deleted the two @available(*, deprecated) updates(for:) tests and their MARK section in SessionUpdateStreamTests.swift. The kept-updates behavior is still covered by anUpdateSentBeforeTheNewSessionResponseReachesTheFirstSubscriber. No shared helper existed only for updates(for:).
    - Added 13 engine tests to SessionMergeEngineTranscriptTests for each behavior that only the aggregator suite tested. Added the fixture helpers terminalChunk(base64:) and terminalSnapshot(base64:command:).
    - The PatchFieldTests doc comment now names SessionMergeEngine.
    - README.md, plan.md, CONTRIBUTING.md and the DocC catalogs had no references.

    Note: the new engine tests pin behavior that already works, so they passed on the first run. This is correct for a move of coverage.
  timestamp: 2026-10-04T13:47:14.332016+00:00
- actor: claude-code
  id: 01m43jpgyzvq94qwzh0trkp54f
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsACP/Connection/ClientSideConnection.swift, Sources/FoundationModelsACP/Session/SessionUpdateAggregator.swift (deleted), Tests/FoundationModelsACPTests/SessionUpdateAggregatorTests.swift (deleted), Tests/FoundationModelsACPTests/TerminalContentPlacementTests.swift (new), Tests/FoundationModelsACPTests/SessionMergeEngineTests.swift, Tests/FoundationModelsACPTests/SessionUpdateStreamTests.swift, Tests/FoundationModelsACPTests/PatchFieldTests.swift. `swift test --scratch-path …/scratchpad/build`: 435 + 128 tests passed, 0 warnings. `swift build --package-path IntegrationTests --build-tests --scratch-path …/scratchpad/build-it`: build complete. `generate-documentation --target FoundationModelsACP --warnings-as-errors`: clean. rg for SessionUpdateAggregator, updates(for, DeprecatedDeclaration, @available(*, deprecated outside .build and .kanban: 0 hits.
    - next: /review
  timestamp: 2026-10-04T13:47:18.367596+00:00
- actor: claude-code
  id: 01m43jvvvtavqjxj76p9xajh81
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (aa1b367). 0 findings, 0 confirmed, 0 refuted. 7 files reviewed. 0 validators failed. 2 .kanban files are excluded by .reviewignore. Some code-hygiene tool rules did not read 2 files, because the commit deletes them.
    - next: The task is in done. No work is open.
  timestamp: 2026-10-04T13:50:13.370300+00:00
- actor: claude-code
  id: 01m43jw4j2vjpg3a85vpzxh821
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — removed SessionUpdateAggregator and updates(for:), 13 replacement engine tests
    - test: green — scratch-path build 0 warnings; swift test 435+128 passed; IntegrationTests 7 passed
    - commit: aa1b367
    - review: clean — 0 findings; task moved to done
  timestamp: 2026-10-04T13:50:22.274767+00:00
- actor: claude-code
  id: 01m443vnt9wegg9k88sbj1tsks
  text: |-
    ### correction — test count
    The "Implementation landed." comment says 13 engine tests were added. Commit aa1b367 adds 12 `@Test` functions to Tests/FoundationModelsACPTests/SessionMergeEngineTests.swift (checked with `git show aa1b367 | rg -c '^\+\s*@Test'`). The implementer's own list of behaviors also has 12 items, so no behavior is without a test. Only the number in that comment was wrong.
  timestamp: 2026-10-04T18:47:12.969254+00:00
depends_on:
- 01M3YQZE249S3VCDBHV2NPY0DA
- 01M3YQZ0HNG9KMTZKX51HEG5DF
position_column: done
position_ordinal: a780
title: Remove deprecated SessionUpdateAggregator and updates(for:)
---
## What

Delete `SessionUpdateAggregator` and `ClientSideConnection.updates(for:)`. Both are deprecated by ^2npy0da (merge engine) and ^1heg5df (`subscribe(to:)`).

## Wait condition

Do NOT start this task until the session `foundationmodelsacpclient-ae` reports that FoundationModelsACPClient no longer uses them (ACPSessionState is deleted). Until then, this task stays in todo.

## Acceptance criteria

- No code or tests in this package use the two removed APIs; the tests use the engine and `subscribe(to:)`.
- DocC has no links to the removed names.
- `swift test` passes with no warnings.