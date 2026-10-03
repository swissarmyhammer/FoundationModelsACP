---
assignees:
- claude-code
position_column: todo
position_ordinal: '8680'
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