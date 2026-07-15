---
comments:
- actor: wballard
  id: 01kxhjcpxz8j0q4rbwdtw06yew
  text: 'Picked up by finish loop. Plan: locate latest schema-v1.19.x release in the agentclientprotocol GitHub org, vendor schema.json / meta.json / meta.unstable.json byte-identical as Schema/acp-v1*.json, add Schema/README.md with tag + bump procedure, and add SchemaFixtureTests (TDD).'
  timestamp: 2026-07-15T00:21:26.079609+00:00
- actor: wballard
  id: 01kxhjpm7vnjazfpe9xpdv8jr9
  text: 'Implementation landed (TDD). Vendored release tag schema-v1.19.0 from agentclientprotocol/agent-client-protocol; all three files SHA-256 verified byte-identical against GitHub asset digests (schema.json 92c1dfcd…, meta.json e0bf36f8…, meta.unstable.json 30268982…). Added Schema/README.md (tag/URL, digest table, bump procedure) and SchemaFixtureTests.swift (watched RED with 4 failures first, then GREEN). Discovery: the release meta manifests use agentMethods/clientMethods/protocolMethods routing tables, NOT the x-side/x-method shape the card guessed — tests assert the real shape, session/prompt present in both manifests. Also present upstream but not vendored (out of scope): schema.unstable.json. swift test: 5/5 pass, exit 0. really-done verified, double-check verdict PASS. Leaving in doing for review.'
  timestamp: 2026-07-15T00:26:51.003952+00:00
depends_on:
- 01KXHB6V536ZBBFC24M9WQXWMM
position_column: doing
position_ordinal: '80'
title: Vendor ACP schema v1.19.x artifacts
---
## What
Vendor the canonical ACP schema artifacts (spec §6, §7.2) into `Schema/`:

- Download from the `agentclientprotocol` org's `schema-v1.19.x` GitHub release (the org relocated from `zed-industries`, which now hosts only the schema crate): `schema/v1/schema.json`, `schema/v1/meta.json`, and `meta.unstable.json`.
- Commit as `Schema/acp-v1.json`, `Schema/acp-v1.meta.json`, `Schema/acp-v1.meta.unstable.json`.
- Add `Schema/README.md` documenting the exact release tag vendored and the bump procedure: "bumping ACP = dropping in the new artifact pair, then `swift package generate-acp`" — nothing else changes by hand.

## Acceptance Criteria
- [x] All three artifacts committed and byte-identical to the release assets for the pinned v1.19.x tag
- [x] `Schema/README.md` records the release tag/URL and bump procedure
- [x] The vendored files parse as JSON and contain the expected top-level structure (definitions in schema.json; `x-side`/`x-method` routing entries in meta.json)

## Tests
- [x] `Tests/FoundationModelsACPTests/SchemaFixtureTests.swift` — Swift Testing test that loads each vendored file, parses it with `JSONSerialization`/`JSONValue`, and asserts the expected top-level keys exist (e.g. method routing entries present in meta.json, `session/prompt` among them)
- [x] Run `swift test` — exits 0

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.