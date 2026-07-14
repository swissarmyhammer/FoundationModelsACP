---
depends_on:
- 01KXHB6V536ZBBFC24M9WQXWMM
position_column: todo
position_ordinal: '8280'
title: Vendor ACP schema v1.19.x artifacts
---
## What
Vendor the canonical ACP schema artifacts (spec §6, §7.2) into `Schema/`:

- Download from the `agentclientprotocol` org's `schema-v1.19.x` GitHub release (the org relocated from `zed-industries`, which now hosts only the schema crate): `schema/v1/schema.json`, `schema/v1/meta.json`, and `meta.unstable.json`.
- Commit as `Schema/acp-v1.json`, `Schema/acp-v1.meta.json`, `Schema/acp-v1.meta.unstable.json`.
- Add `Schema/README.md` documenting the exact release tag vendored and the bump procedure: "bumping ACP = dropping in the new artifact pair, then `swift package generate-acp`" — nothing else changes by hand.

## Acceptance Criteria
- [ ] All three artifacts committed and byte-identical to the release assets for the pinned v1.19.x tag
- [ ] `Schema/README.md` records the release tag/URL and bump procedure
- [ ] The vendored files parse as JSON and contain the expected top-level structure (definitions in schema.json; `x-side`/`x-method` routing entries in meta.json)

## Tests
- [ ] `Tests/FoundationModelsACPTests/SchemaFixtureTests.swift` — Swift Testing test that loads each vendored file, parses it with `JSONSerialization`/`JSONValue`, and asserts the expected top-level keys exist (e.g. method routing entries present in meta.json, `session/prompt` among them)
- [ ] Run `swift test` — exits 0

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.