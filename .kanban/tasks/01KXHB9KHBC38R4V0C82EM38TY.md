---
depends_on:
- 01KXHB8QAXW73Z00S3HEE3F2AZ
- 01KXHB95AAD18C1CN4QTT9QWXJ
position_column: todo
position_ordinal: '8680'
title: SwiftPM command plugin, hash stamp, and CI diff gate for codegen
---
## What
Wire the generator into the build workflow (spec §6):

- A SwiftPM **command plugin** (`Plugins/GenerateACP/`) exposing `swift package generate-acp` that runs `acp-generate` and writes into `Sources/FoundationModelsACP/Generated/` (command plugins may write to the package dir with explicit permission; build-tool plugins are sandboxed out — do NOT use one).
- **Hash stamp no-op:** the generator stamps the schema artifacts' content hash into the generated output (e.g. `Generated/.schema-hash` or a header constant); on each run it compares and exits immediately when unchanged, so regeneration fires only when a new schema is dropped in.
- **v2 readiness (spec §7.2):** parameterize the generator's inputs as a schema *set* (artifact paths + version label → output namespace) rather than hardcoding `acp-v1.json` — ACP v2 is in active RFD, and when it publishes we must be able to vendor a second schema behind a clearly labeled unstable namespace without rework. Do NOT implement v2; just don't bake in one-schema assumptions.
- **CI workflow** (`.github/workflows/ci.yml`): build, `swift test`, run `swift package generate-acp`, then `git diff --exit-code` — fail on any diff so committed code always matches the vendored schema.

## Acceptance Criteria
- [ ] `swift package generate-acp` regenerates `Sources/FoundationModelsACP/Generated/` from `Schema/`
- [ ] Running it twice in a row: second run is a no-op (verifiable via unchanged mtimes/log output)
- [ ] Generator input paths and version label are configuration (a schema-set descriptor), not constants — adding a hypothetical second set requires no generator code change
- [ ] CI fails when Generated/ is out of sync with Schema/, passes when in sync

## Tests
- [ ] `Tests/ACPGenerateTests/HashStampTests.swift` — same schema hash → generator exits without writing; changed hash → regenerates
- [ ] `Tests/ACPGenerateTests/SchemaSetTests.swift` — generator runs against a second toy schema-set descriptor, emitting into its own namespace
- [ ] CI job itself is the diff-gate test: `swift package generate-acp && git diff --exit-code` step in ci.yml
- [ ] Run `swift test` — exits 0

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.