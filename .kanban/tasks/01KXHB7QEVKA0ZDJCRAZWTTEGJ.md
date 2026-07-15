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
- actor: wballard
  id: 01kxhjr95wg3fx9fejw3msjnqs
  text: 'Checkpoint committed locally: 74c057f "feat(schema): vendor ACP schema-v1.19.0 artifacts" (9 files, +4897/-7). Test suite green at commit time (swift test 5/5, exit 0, no warnings). Proceeding to review scoped to HEAD~1..HEAD.'
  timestamp: 2026-07-15T00:27:45.212723+00:00
- actor: wballard
  id: 01kxhk1kerggt7rdedtxgnnyw8
  text: 'Review pass 1 on HEAD~1..HEAD: 2 confirmed findings (both docstring exactness on the new test helper expectRoutingTables — needs plural - Parameters: block and a - Throws: section). Findings appended to card; task stays in review. Returning to implement to fix.'
  timestamp: 2026-07-15T00:32:50.648591+00:00
- actor: wballard
  id: 01kxhk65hs39sq29a70b4q0hk6
  text: 'Fixed both review findings: expectRoutingTables doc now uses a plural - Parameters: block covering manifest and name, plus a - Throws: section. Checked the rest of the file for the same defect class — loadJSONObject already documents its single param/returns/throws exactly; @Test funcs have no docs (rule-compliant). swift test 5/5 exit 0; double-check verdict PASS. Checkboxes flipped to [x].'
  timestamp: 2026-07-15T00:35:20.249703+00:00
- actor: wballard
  id: 01kxhk77pxa7wwwtk0n2vn1trx
  text: 'Checkpoint committed locally: dc05a1f "docs(tests): complete expectRoutingTables doc comment". Suite green (5/5, exit 0, zero warnings). Running review pass 2 on HEAD~1..HEAD.'
  timestamp: 2026-07-15T00:35:55.229608+00:00
- actor: wballard
  id: 01kxhkcxda3134aq0sfag8ncvp
  text: 'Review pass 2 on HEAD~1..HEAD: clean (0 findings, 14 rules attempted, 0 failed) and all prior findings checked. Task moved to done. Vendored release: schema-v1.19.0 (agentclientprotocol/agent-client-protocol), digests verified byte-identical. Commits: 74c057f (artifacts + README + tests), dc05a1f (doc-comment fix). Local commits only — nothing pushed.'
  timestamp: 2026-07-15T00:39:01.290305+00:00
depends_on:
- 01KXHB6V536ZBBFC24M9WQXWMM
position_column: done
position_ordinal: '8180'
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

## Review Findings (2026-07-14 19:28)

- [x] `Tests/FoundationModelsACPTests/SchemaFixtureTests.swift:41` — Function `expectRoutingTables` has two parameters but documentation uses singular `- Parameter` format for only one of them. The rule requires exactness: document all parameters, returns, and throws the signature has, or omit documentation entirely. With two parameters, the plural `- Parameters:` block format is required. Convert to plural `- Parameters:` block format documenting both parameters:
```
/// - Parameters:
///   - manifest: The parsed top-level object of a meta manifest.
///   - name: The name of the manifest file being tested.
```.
- [x] `Tests/FoundationModelsACPTests/SchemaFixtureTests.swift:41` — Function `expectRoutingTables` has `throws` in its signature but documentation is missing `- Throws:` section. Documentation must be exact: include all parameters, return (if non-Void), and throws that the signature has. Add `- Throws:` documentation to complete the API contract, e.g., `/// - Throws: A test failure if a required routing table is missing or structurally invalid.`.