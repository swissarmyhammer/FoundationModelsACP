---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m113wgxacxqqc2gqrtgwsx5n
  text: |-
    Research and discoveries.

    Digests. All three release assets agree with the files on disk after the copy:
    - `schema.json` / `acp-v2.json` = `36e8270fb12d4d067005cc02f729f5433930e6834ab4a72260838ee096d62378`
    - `meta.json` / `acp-v2.meta.json` = `ad94c01f2736416776fd53d66e3aaf89242ab72d99832664f39d6ab41e049736` (no change)
    - `meta.unstable.json` / `acp-v2.meta.unstable.json` = `2c274308d2a773628bf6316b7f6c535cf87d2c1ceb495d02be9ee899dce0f0bc` (no change)

    The `$defs` delta is exactly three added names and no removed name: `AuthCapabilities`, `AuthMethodTerminal`, `TerminalAuthCapabilities`. The generator needed no change, as the card said.

    `swift package generate-acp` refuses to run alone. The plugin asks for permission to write into the package directory. The command that works is `swift package --allow-writing-to-package-directory generate-acp`. New schema hash: `851dcdaec5cc7669c2c7204f59393185950114e0a8581d9eb6c2e99d3ac8a8fd`.

    Shard boundaries. The byte budget moved two boundaries only, and it added no `Models10` shard. `Models2` went from 15 declarations to 16, and `Models8` went from 13 to 15. The `Models` total went from 120 to 123, as the card predicted. Eight declarations moved between shards without a change of content: `CancelRequestNotification`, `CancelSessionNotification`, `Diff`, `EmbeddedResource`, `LoginAuthResponse`, `PlanUpdate`, `SelectedPermissionOutcome`, `StringMultiSelectItems`.

    `TaggedUnionRoundTripTests` needed no change. Its table names definitions, and it reads the tags from the vendored schema, so the new `terminal` tag entered the exhaustive half on its own and selects `.terminal`.

    The repository declares no formatter configuration. There is no `.swift-format`, no `.swiftlint.yml`, and no format step in `.github/workflows/ci.yml` or `CONTRIBUTING.md`. So no format command was run. The generated files must not be formatted anyway: `VendoredSchemaTests.checkedInOutputMatchesAFreshRun` compares them byte for byte with a fresh generator run.
  timestamp: 2026-08-27T08:02:51.946266+00:00
- actor: claude-code
  id: 01m113wp2sktpktgw9dbe7yjf7
  text: |-
    ### implement — changed
    - evidence: 13 files — Schema/acp-v2.json, Schema/README.md, Sources/FoundationModelsACP/Generated/.schema-hash, Sources/FoundationModelsACP/Generated/Models{,2,3,4,5,6,7,8}.generated.swift, Sources/FoundationModelsACP/Generated/Unions.generated.swift, Tests/ACPGenerateTests/VendoredSchemaTests.swift. `swift test`: 253 tests in 24 suites passed, plus 107 tests in 14 suites passed; 0 failures, 0 warnings. `cd IntegrationTests && swift test`: 6 tests in 2 suites passed.
    - next: /review
  timestamp: 2026-08-27T08:02:57.241071+00:00
- actor: claude-code
  id: 01m114f34kzdmxdhwgjfc5ptd4
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit cbf541d) — 0 findings, 0 confirmed, 0 refuted, 21 validator passes attempted, 0 failed. 10 files reviewed. Not reviewed: 8 `.kanban/` files (ignore rule), and `Schema/README.md`, `Schema/acp-v2.json`, `Sources/FoundationModelsACP/Generated/.schema-hash` (no validator matches these file types).
    - next: task moved to done. No open findings.
  timestamp: 2026-08-27T08:13:00.435706+00:00
- actor: claude-code
  id: 01m114fr19nhect8rmw4s1szbr
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 13 files (Schema/acp-v2.json, Schema/README.md, Generated/.schema-hash, Generated/Models{,2..8}.generated.swift, Generated/Unions.generated.swift, Tests/ACPGenerateTests/VendoredSchemaTests.swift)
    - test: green — swift test 107 tests / 14 suites passed; IntegrationTests 6 tests / 2 suites passed; 0 failures, 0 warnings
    - commit: cbf541d
    - review: clean — 0 findings, 21 validator passes attempted, 0 failed
    - next: task in done; proceed to the blocked dependants ^29gsgma and ^skm9j5t
  timestamp: 2026-08-27T08:13:21.833282+00:00
position_column: done
position_ordinal: '9880'
title: Vendor ACP schema-v2.0.0-alpha.3 and regenerate
---
## What
Replace the pinned-commit schema with the tagged release `schema-v2.0.0-alpha.3` (published 2026-08-20). Only `schema.json` changes; `meta.json` and `meta.unstable.json` are expected to be byte-identical to the release, but you must verify this.

Steps:
- [x] Download the release asset: `gh release download schema-v2.0.0-alpha.3 --repo agentclientprotocol/agent-client-protocol --pattern schema.json`. Copy it over `Schema/acp-v2.json` byte-identical. Expected SHA-256: `36e8270fb12d4d067005cc02f729f5433930e6834ab4a72260838ee096d62378`.
- [x] Verify all three release digests: `gh api repos/agentclientprotocol/agent-client-protocol/releases/tags/schema-v2.0.0-alpha.3 --jq '.assets[] | "\(.name) \(.digest)"'`. Compare with `shasum -a 256 Schema/acp-v2.json Schema/acp-v2.meta.json Schema/acp-v2.meta.unstable.json`. Expected: `meta.json` = `ad94c01f2736416776fd53d66e3aaf89242ab72d99832664f39d6ab41e049736`, `meta.unstable.json` = `2c274308d2a773628bf6316b7f6c535cf87d2c1ceb495d02be9ee899dce0f0bc`.
- [x] Update `Schema/README.md` "Vendored version" section (lines 6-27): set the source to the tag `schema-v2.0.0-alpha.3`, remove the pinned-commit note and the "Differences from alpha.2" paragraph, update the table column header and the `acp-v2.json` digest. Write the text in ASD-STE100 Simplified Technical English.
- [x] Run `swift package generate-acp`. The content hash changes with the file, so a full run occurs. Commit the regenerated `Sources/FoundationModelsACP/Generated/*.generated.swift` AND the regenerated `Sources/FoundationModelsACP/Generated/.schema-hash` stamp together: `.github/workflows/ci.yml` reads the stamp and `VendoredSchemaTests.checkedInStampMatchesTheVendoredArtifactHash` compares it.
- [x] Repair the pinned inventories in `Tests/ACPGenerateTests/VendoredSchemaTests.swift`, test `declarationsAreEmittedInSortedSchemaNameOrder`: the `emitted.mapValues(\.count) == [...]` map pins per-shard declaration counts. The three new structs (`AuthCapabilities`, `TerminalAuthCapabilities`, `AuthMethodTerminal`) raise the `Models` total from 120 to 123, and the byte-budget sharding can move shard boundaries or add a `Models10.generated.swift` key. Update the map to the fresh output. Do NOT change the generator to keep a stale count. Confirm `noGeneratedFileExceedsTheReviewPromptCap` still passes.
- [x] Confirm the generated output contains the new declarations (see acceptance criteria for the exact commands).

Context: the new schema adds terminal authentication. All changes are additive. The generator already handles the `agent` variant of `AuthMethod`, which has the same `properties.type.const` + `required: ["type"]` + `allOf: [$ref]` shape as the new `terminal` variant, so no generator change is expected. `args` and `env` on `AuthMethodTerminal` are not in `required`, so the generator emits them as optional arrays (`[String]?`, `[EnvVariable]?`) decoded with `forgivingDecodeArrayIfPresent`, the same as `NewSessionRequest.additionalDirectories`.

## Acceptance Criteria
- [x] `shasum -a 256 Schema/acp-v2.json` prints `36e8270fb12d4d067005cc02f729f5433930e6834ab4a72260838ee096d62378`; the two meta digests are unchanged and agree with the release asset digests.
- [x] `Schema/README.md` names the tag, has no pinned-commit note, and its `acp-v2.json` digest matches the file.
- [x] `rg -q 'case terminal\(AuthMethodTerminal\)' Sources/FoundationModelsACP/Generated/Unions*.generated.swift` exits 0.
- [x] `rg -q 'public struct AuthMethodTerminal' Sources/FoundationModelsACP/Generated/` , `rg -q 'public struct AuthCapabilities'`, `rg -q 'public struct TerminalAuthCapabilities'`, and `rg -q 'public var auth: AuthCapabilities\?'` all exit 0 on the generated sources.
- [x] `AuthMethodTerminal` has `methodId: AuthMethodId`, `name: String`, `description: String?`, `args: [String]?`, `env: [EnvVariable]?`, `meta: JSONValue?`.
- [x] `Sources/FoundationModelsACP/Generated/.schema-hash` is regenerated and committed with the sources.

## Tests
- [x] `swift test --filter VendoredSchemaTests` passes: `checkedInOutputMatchesAFreshRun` (the real freshness gate), `checkedInStampMatchesTheVendoredArtifactHash`, `declarationsAreEmittedInSortedSchemaNameOrder` (with the updated count map), and `noGeneratedFileExceedsTheReviewPromptCap`.
- [x] `swift test --filter TaggedUnionRoundTripTests` passes: the exhaustive-over-tags half now includes `terminal` and must select `.terminal`, not `.unknown`.
- [x] `swift test` passes in full.
- [x] `cd IntegrationTests && swift test` passes (`SchemaConformanceTests` validates against the vendored schema).

## Workflow
- This task has no test to write first: the deliverable is a byte-identical vendored file plus regenerated output. Order: drop in the file, verify digests, regenerate, then repair the pinned inventories that go red, then run the full suite. #schema-alpha3