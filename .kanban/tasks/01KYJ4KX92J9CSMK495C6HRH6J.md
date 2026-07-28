---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kymckjs2dg1a661n2j4j82h4
  text: |-
    Implemented the fix.

    What changed (Tests/ACPGenerateTests/VendoredSchemaTests.swift only, no generator/production changes):
    - Added a new private static helper originalSchemaNames() (placed right after memberSorted()). It parses the vendored schema's own $defs JSON keys, applies the same forward transform the generator applies before emitting each declaration (config.typeRenames, then a locally mirrored copy of SchemaGenerator.applyKnownAcronymCasing's word-split-and-uppercase algorithm — that method is private to SchemaGenerator and unreachable even via @testable import, so the algorithm is reimplemented rather than reused), filters out config.handwrittenDefinitions (never emitted), and builds [emittedName: originalSchemaName] via Dictionary(uniqueKeysWithValues:).
    - declarationsAreEmittedInSortedSchemaNameOrder now calls try Self.originalSchemaNames() instead of the old Dictionary(uniqueKeysWithValues: Self.set.config.typeRenames.map { ($1, $0) }) which only inverted typeRenames and missed all six knownAcronyms-only names (MCPCapabilities, MCPHTTPCapabilities, MCPServerHTTP, MCPServerStdio, MCPStdioCapabilities, HTTPHeader).
    - Chose "walk $defs forward, computed once from the schema" over trying to algorithmically un-invert applyKnownAcronymCasing, since that inversion is not guaranteed unambiguous (a schema name already spelled HTTP and one spelled Http both re-case to HTTP).

    Regression verification (mutation-testing discipline): built a disposable synthetic-schema test (not committed) with two definitions, FooHaBar and FooHttpBar, knownAcronyms=["HTTP"]. Real generator emission order is FooHaBar then FooHTTPBar (schema-key-sorted, ground truth). Confirmed:
    - The fixed logic recovers the true spelling and correctly sees this real order as sorted.
    - The OLD buggy logic (reverse map from typeRenames only, empty here) falls back to the emitted spelling for FooHttpBar, and wrongly concludes the same correct order is UNSORTED — a false failure over the wrong string, exactly the failure class the task described. This proves the fix is load-bearing, not cosmetic; deleted the throwaway test file afterward.

    Verification:
    - swift build --build-tests: clean, exit 0.
    - swift test: 292 tests / 28 suites / 0 failures / 0 warnings (matches stated baseline exactly).
    - LSP diagnostics on working tree: 0 errors / 0 warnings.
    - Did not run swift format.

    Adversarial double-check agent dispatched per really-done gate; awaiting verdict before final handoff.
  timestamp: 2026-07-28T12:53:44.866343+00:00
- actor: claude-code
  id: 01kymcqa2mpchbart87gdxzjc3
  text: |-
    Adversarial double-check verdict: PASS.

    The reviewer independently diffed the test's reimplemented acronym-casing algorithm against SchemaGenerator.applyKnownAcronymCasing/emittedName and found them structurally identical; simulated the same transform against the real Schema/acp-v2.json $defs (146 keys, 144 after excluding the two handwrittenDefinitions) and confirmed all six task-cited names resolve correctly with zero emitted-name collisions across the 144 entries, so the Dictionary(uniqueKeysWithValues:) call cannot fatal-crash on the current vendored artifact. Confirmed handwrittenDefinitions (AbsolutePath, ProtocolVersion) are never emitted, so excluding them from the reverse map is safe. Confirmed swift build --build-tests and swift test --filter VendoredSchemaTests are green. No structural, correctness, or completeness issues found; no scope drift.

    Final fresh verification re-run just now: swift test -> 198 tests/16 suites + 94 tests/12 suites = 292 tests / 28 suites, 0 failures, 0 warnings (grep for "warning:" across the full log returned 0 matches). Matches the stated baseline exactly. swift format was not run at any point.

    Task is done and green. Leaving in doing per the implement skill for /review to pick up.
  timestamp: 2026-07-28T12:55:47.028457+00:00
position_column: done
position_ordinal: '8880'
title: VendoredSchemaTests sort-order check doesn't account for knownAcronyms renames
---
`declarationsAreEmittedInSortedSchemaNameOrder` in `Tests/ACPGenerateTests/VendoredSchemaTests.swift` reconstructs each emitted declaration's "original schema spelling" via a reverse map built only from `config.typeRenames` (`Dictionary(uniqueKeysWithValues: Self.set.config.typeRenames.map { ($1, $0) })`). It has no knowledge of `GeneratorConfig.knownAcronyms` / `SchemaGenerator.applyKnownAcronymCasing(to:)`, added on `^qzht036` to uniformly uppercase acronym words (e.g. `McpServer` -> `MCPServer`) in emitted type names.

For the six names affected only by `knownAcronyms` (not also in `typeRenames`) — `MCPCapabilities`, `MCPHTTPCapabilities`, `MCPServerHTTP`, `MCPServerStdio`, `MCPStdioCapabilities`, `HTTPHeader` — the reverse map misses, so `schemaNames[$0] ?? $0` falls back to the *emitted* spelling instead of the true original schema spelling when checking sort order.

Verified by hand this currently still passes for a real structural reason: `applyKnownAcronymCasing` only changes the case of letters *inside* a word, never a word's initial capital, and every first-differing character between these six names and their sorted neighbors in the vendored schema sits at a word boundary — so substituting the emitted spelling for the original doesn't change relative order today. But the test's own logic doesn't guarantee that invariant; a future acronym addition or schema change could make it pass coincidentally-sorted-but-wrong, or fail without explaining why (comparing the wrong strings).

Fix: extend the test's reverse-map construction to also invert `knownAcronyms` casing (or otherwise recover true original schema spelling for every emitted name), so the check is correct by construction rather than by accident.

Found during the adversarial `double-check` review of ^qzht036's 2026-07-27 review-findings round (non-blocking there; the change under review didn't introduce a regression, it just exposed the gap).