---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kyq6h24qwv97tc36w3r14g5r
  text: |-
    Fixed. Root cause: neither `acp-test-agent` nor `acp-generate` had an on-disk `.docc` catalog, so DocC synthesized an in-memory root page (title + `@Metadata { @DisplayName(...) }`, no body) and then warned that its own synthesized page was empty.

    Fix:
    - Added `Sources/acp-test-agent/Documentation.docc/acp-test-agent.md` and `Sources/acp-generate/Documentation.docc/acp-generate.md`, each with the same title/`@DisplayName` as before plus a short real prose paragraph describing what the executable does.
    - First pass triggered a new regression caught by adversarial double-check: placing `Documentation.docc` directly under `Sources/<target>` with no manifest declaration made SwiftPM flag it as an "unhandled file" on every `swift build`/`swift test` (not just doc generation). Root cause: swift-docc-plugin's `SourceModuleTarget+doccCatalogPath.swift` finds the catalog via `target.sourceFiles`, which excludes anything not declared as a source/resource — so `exclude:` silences the SwiftPM warning but also hides the catalog from DocC (verified empirically), reintroducing the original warning.
    - Real fix: declared `resources: [.copy("Documentation.docc")]` on both `executableTarget`s in `Package.swift`. This keeps the catalog in `sourceFiles` (so DocC still finds and parses it — confirmed via generated `.doccarchive` JSON containing the new prose) while making SwiftPM classify it as a known resource (no more "unhandled file" warning).

    Verified (fresh, twice — self and via `double-check` subagent):
    - `swift build` — 0 warnings, 0 errors.
    - `swift package generate-documentation` — 0 warnings (both original "No valid content was found in this file" warnings gone).
    - `swift test` — 247 tests/23 suites + 95 tests/12 suites = 342 tests/35 suites, all passing, 0 warnings.
    - `git status`/`git diff` — only `Package.swift` (2-line resources addition per target) and the two new `Documentation.docc` directories changed.

    Did not run `swift format` (repo policy — it rewrites checked-in generated files the CI diff gate pins byte-for-byte). Did not commit/push. Left in `doing` for `/review` per process.
  timestamp: 2026-07-29T15:05:14.135748+00:00
position_column: doing
position_ordinal: '80'
title: Fix pre-existing DocC warnings on acp-test-agent/acp-generate catalogs
---
`swift package generate-documentation` emits 2 warnings, confirmed pre-existing (present both before and after the M9 ^p68s7v7 changes — verified via git stash comparison):

```
warning: No valid content was found in this file
A '.' file should contain a top-level directive ('Tutorials', 'Tutorial', or 'Article') and valid child content. Only '.md' files support content without a top-level directive
 --> ../../../../../..:1:1-5:2
1 + # ``acp_test_agent``
2 +
3 + @Metadata {
4 +   @DisplayName("acp-test-agent")
5 + }
```

Same warning for `acp_generate`. Both are the DocC catalog root pages for the `acp-test-agent` and `acp-generate` executable targets — they carry only a title + `@Metadata` block with no top-level directive (`Article`, `Tutorial`, etc.), so DocC treats them as empty. Fix by adding a minimal `@Article`-wrapped body (or equivalent) to each catalog's landing page so `swift package generate-documentation` runs warning-free.

Found during independent verification of ^p68s7v7 (M9). Not introduced by that task — unrelated to its scope — filed separately so the build can eventually reach true zero-warnings on DocC. #test-failure