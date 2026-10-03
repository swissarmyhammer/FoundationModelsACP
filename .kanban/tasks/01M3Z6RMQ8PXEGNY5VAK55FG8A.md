---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m40t55qeezzhb1przqvnfg1g
  text: |-
    Research done.
    - Digest check: `gh api .../releases/tags/schema-v2.0.0-alpha.7` gives schema.unstable.json sha256:75b2aa359dd26cd9d0468674be96482b14a2d181bc8e3ea8c91a8e598f63e3b5 (432210 bytes). The scratch copy matches.
    - Reachable closure of CompactionUpdate, CompactionSummaryChunk, Notice in the unstable schema = the six listed types + ContentBlock (and its closure). The unstable ContentBlock closure differs from the stable one ONLY in description text (doc links). So ContentBlock must resolve to the stable top-level type, not be emitted again.
    - The generator already supports a namespaced SchemaSet, but `Emitter.file` wraps each file in `public enum <Namespace> {`. With more than one file (Identifiers, Models, Unions, Unresolved) that declares the enum more than once and cannot compile. Also `public enum Unstable` already exists in MethodTable.generated.swift. Plan: namespaced files use `extension <Namespace> {`, and an empty declaration list emits no file.
    - Plan for config: `GeneratorConfig.rootDefinitions` (emit only the reachable closure) and `sharedDefinitions` (resolve to the primary set's type, never emit, do not walk into). Stale entries fail generation.
    - Patch types already get `folded(onto:)` from the emitter when a field is in `patchSemanticsFields`.
    - `SessionUpdate.unknown(type, payload)`: payload excludes the `sessionUpdate` member. The internal helpers `JSONValue.decoded(as:)` and `JSONValue.encode(result:)` do the transcode.
    - VendoredSchemaTests.checkedInOutputMatchesAFreshRun requires the Generated directory to hold exactly the primary set's files; it must learn about all sets.
  timestamp: 2026-10-03T11:59:55.118476+00:00
- actor: claude-code
  id: 01m40tq1n8qwtfe3z02fmn84nz
  text: |-
    Implementation landed (not committed).
    - Vendored Schema/acp-v2.unstable.json (sha256 75b2aa35…e3b5, same as the release asset). Schema/README.md: table row added, the "deliberately not vendored" paragraph replaced by "The unstable schema document"; bump steps now name schema.unstable.json. CONTRIBUTING.md artifact list updated.
    - Generator: `GeneratorConfig.rootDefinitions` + `sharedDefinitions` (stale entries fail generation); `GeneratorConfig.acpV2Unstable`; `SchemaSet.acpV2Unstable` (label "v2-unstable", namespace "Unstable", no manifests); `SchemaSet.all = [.acpV2, .acpV2Unstable]`.
    - Namespaced files now open `extension <Namespace> {` (the old `public enum <Namespace> {` cannot compile with more than one file). A namespaced set emits no file for an empty declaration list. The top-level set still emits all four base files: 11 existing generator tests depend on that (first attempt skipped empty lists for every set and broke them; reverted to namespaced-only).
    - Generated: Unstable.Identifiers/Models/Unions.generated.swift + .Unstable.schema-hash. Six types only; ContentBlock resolves to the stable type.
    - Hand-written Sources/FoundationModelsACP/Session/UnstableSessionUpdate.swift: `Unstable.SessionUpdate` and `SessionUpdate.init(_ update: Unstable.SessionUpdate) throws`.
    - CI codegen gate now drops every stamp (`.schema-hash` and `.*.schema-hash`), else the unstable set short-circuits.
    - VendoredSchemaTests: checked-in output and stamp checks now cover every set.
    - Verified: build --build-tests 0 warnings; swift test 426 + 128 tests pass; generate-documentation --target FoundationModelsACP --warnings-as-errors passes; IntegrationTests 7 tests pass.
  timestamp: 2026-10-03T12:09:40.776697+00:00
- actor: claude-code
  id: 01m40tq6cj92n0kss0ed3sce0y
  text: |-
    ### implement — changed
    - evidence: 21 files — Schema/acp-v2.unstable.json, Schema/README.md, CONTRIBUTING.md, .github/workflows/ci.yml, Sources/ACPGenerateCore/{Emitter,GeneratorConfig,SchemaGenerator,SchemaSet}.swift, Sources/FoundationModelsACP/Generated/{Unstable.Identifiers,Unstable.Models,Unstable.Unions}.generated.swift + .Unstable.schema-hash, Sources/FoundationModelsACP/Session/UnstableSessionUpdate.swift, Tests/ACPGenerateTests/{ReachableSubsetTests,UnstableVendoredSchemaTests,VendoredSchemaTests,SchemaSetTests}.swift, Tests/FoundationModelsACPTests/{UnstableSessionUpdateTests,UnstableCompactionNoticeRoundTripTests}.swift. swift build --build-tests: 0 warnings; swift test: 426 + 128 pass; DocC --warnings-as-errors: pass; IntegrationTests: 7 pass.
    - next: /review
  timestamp: 2026-10-03T12:09:45.618093+00:00
- actor: claude-code
  id: 01m40v4hka38jc1gnzgj497748
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (10df3da). 0 findings, 0 confirmed, 0 refuted. 14 validator runs attempted, 0 failed, 0 skipped. 15 files reviewed. 6 files not reviewed: 2 files are excluded by .reviewignore (.kanban/), and no validator matches 4 files (CONTRIBUTING.md, Schema/README.md, Schema/acp-v2.unstable.json, Sources/FoundationModelsACP/Generated/.Unstable.schema-hash).
    - next: The task is in done. No prior findings sections are open.
  timestamp: 2026-10-03T12:17:03.082237+00:00
- actor: claude-code
  id: 01m40v4snx1ceg0ndc083m4eg1
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 21 files, vendored unstable schema, Unstable types, Unstable.SessionUpdate view
    - test: green — scratch-path build 0 warnings; swift test 426+128 passed; IntegrationTests 7 passed
    - commit: 10df3da
    - review: clean — 0 findings; task moved to done
  timestamp: 2026-10-03T12:17:11.357615+00:00
position_column: done
position_ordinal: a480
title: Vendor schema.unstable.json and generate unstable compaction and notice session updates
---
## What

Vendor the upstream `schema.unstable.json` of `schema-v2.0.0-alpha.7` and generate Swift types for the unstable session updates that we handle: `compaction_update`, `compaction_summary_chunk` and `notice`. The user decided this on 2026-10-02.

## Why

An agent compacts its MODEL CONTEXT (for example, FoundationModelsACPAgent with its Router). Upstream defines an unstable ACP surface for this: `CompactionUpdate` (an upsert keyed by `compactionId`, with `status`, retained `summary: [ContentBlock]`, `error`, `_meta`, patch semantics; "the first update fixes the compaction's timeline position") and `CompactionSummaryChunk` (appends one content block to the summary of an in-progress compaction). `Notice` is "fire-and-forget advisory information ... live events rather than session history".

Today these decode as `SessionUpdate.unknown(type, payload)`, so the engine shows raw JSON entries and cannot merge them.

FoundationModelsACP must stay independent of Router: it only implements the ACP schema.

## Steps

1. Download `schema.unstable.json` from the tag `schema-v2.0.0-alpha.7`, verify its digest with `gh api`, and add it to `Schema/` and to the table in `Schema/README.md`. Remove the "deliberately not vendored" paragraph and explain the new use.
2. Extend the generator with an input slot for the unstable schema. Generate ONLY the types reachable from these session update variants: `CompactionId`, `CompactionStatus` (with `.unknown(String)`), `CompactionUpdate`, `CompactionSummaryChunk`, `Notice`, `NoticeSeverity` (with `.unknown(String)`). Put them in the `Unstable` namespace, and mark them clearly unstable in DocC.
3. Do NOT add cases to the stable `SessionUpdate` enum. Add a typed view, for example `Unstable.SessionUpdate` with cases `compactionUpdate`, `compactionSummaryChunk`, `notice`, and an initializer that reads a stable `SessionUpdate.unknown(type, payload)` (returns nil for other types). Also a way to encode one back to a `SessionUpdate` for an agent to send.
4. `CompactionUpdate` gets patch fields for `summary`, `error`, `_meta` and a generated `folded(onto:)`, like the other patch types. Note: `summary: []` also clears the summary.

## Acceptance criteria

- The vendored file matches the release asset byte for byte.
- Round-trip tests for each new type, including unknown status and severity values and the patch semantics of `summary` (omitted, null, `[]`, value).
- A test that a `compaction_update` sent as a `SessionUpdate` reaches the peer and is read back with `Unstable.SessionUpdate`.
- `swift build --build-tests` has 0 warnings; `swift test` passes; DocC with `--warnings-as-errors` passes.