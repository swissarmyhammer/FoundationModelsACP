---
comments:
- actor: wballard
  id: 01kxk5d578ace4m2z185p7w5y3
  text: |-
    Picked up. Research done across this card + generator-core (^kkm2xf) + routing-table (^t9qwxj) threads. Current state: generate(schemaJSON:metaJSON:unstableMetaJSON:) -> [GeneratedFile] is byte-idempotent but has NO explicit hash-stamp short-circuit and NO schema-set descriptor (inputs are constants in main.swift + GeneratorConfig.acpV1). No Plugins/ or .github/ yet. Swift 6.4 real toolchain (macOS 27). .gitignore does not exclude dotfiles.

    Design (pre-empting review churn):
    - SchemaSet descriptor (Sources/ACPGenerateCore/SchemaSet.swift): versionLabel + schemaPath/metaPath/unstableMetaPath + optional outputNamespace + GeneratorConfig; static .acpV1 and .all. Adding a set = a data entry, no generator code change.
    - generate(..., namespace:) wraps declarations in `public enum <namespace>` (indented) and prefixes filenames; namespace=nil keeps acp-v1 output byte-identical.
    - Hash-gate: SchemaGenerator.artifactHash(...) SHA-256 over length+presence-framed artifacts; GenerationOutcome (.unchanged(hash:) / .regenerated(files:hash:)); generateIfChanged(..., previousHash:) emits a .schema-hash stamp file (SwiftPM ignores dotfiles, so no target build impact; git still diffs it). generate() itself stays stamp-free so existing Core tests are untouched.
    - CLI (main.swift) iterates SchemaSet.all, reads Generated/.schema-hash, generateIfChanged, no-op skip on unchanged.
    - Command plugin Plugins/GenerateACP/ (URL-based PackagePlugin API, .writeToPackageDirectory permission) forwarding to acp-generate.
    - CI .github/workflows/ci.yml: build, test, `swift package --allow-writing-to-package-directory generate-acp`, git diff --exit-code.
    - Tests: HashStampTests + SchemaSetTests (toy namespaced descriptor).
  timestamp: 2026-07-15T15:12:58.088319+00:00
- actor: wballard
  id: 01kxk5vfhp7662jqgp3vty86dx
  text: |-
    Implementation landed (TDD-style: HashStampTests + SchemaSetTests written alongside the code, all green). Summary:

    SCHEMA-SET DESCRIPTOR (Sources/ACPGenerateCore/SchemaSet.swift): public struct SchemaSet {versionLabel, outputNamespace?, schemaPath, metaPath?, unstableMetaPath?, config}. static .acpV1 (namespace nil = top-level) and .all = [.acpV1]. Adding a second set is an append to .all + its Schema/ artifacts; generator and CLI iterate the list unchanged.

    NAMESPACE EMISSION: generate() gained namespace: String? = nil. Emitter.file(declarations:namespace:) wraps declarations in `public enum <namespace> {…}` (each decl indented one level) and generate() prefixes every emitted file name with `<namespace>.`. namespace=nil path is byte-identical to before — all prior tests + regeneration idempotence preserved.

    HASH STAMP (Sources/ACPGenerateCore/HashStamp.swift): SchemaGenerator.artifactHash(schemaJSON:metaJSON:unstableMetaJSON:) = hex SHA-256 (CryptoKit) over presence-flag + LE-byte-count framed artifacts. GenerationOutcome enum (.unchanged(hash:) / .regenerated(files:hash:)). generateIfChanged(...,previousHash:) short-circuits to .unchanged when the fresh hash equals previousHash; otherwise generates + appends a `.schema-hash` stamp file. generate() itself stays stamp-free so existing Core tests are untouched. Stamp is a dotfile → SwiftPM ignores it (no target-build impact, no Package.swift exclude), git still diffs it. stampFileName(namespace:) → .schema-hash / .<ns>.schema-hash.

    CLI (Sources/acp-generate/main.swift): now descriptor-driven — iterates SchemaSet.all, reads Generated/<stamp>, generateIfChanged, and on .unchanged prints "vN: up to date … nothing regenerated" and writes NOTHING (mtimes preserved). Only optional arg is output-dir; still tree-relative-guarded.

    PLUGIN (Plugins/GenerateACP/plugin.swift + Package.swift .plugin): COMMAND plugin `generate-acp` with .writeToPackageDirectory permission, forwards args to acp-generate via Process, cwd = package root (URL-based PackagePlugin API — warning-free on Swift 6.4). Verified: `swift package plugin --list` shows it; `swift package --allow-writing-to-package-directory generate-acp` runs and reports the no-op.

    CI (.github/workflows/ci.yml): macos-15 — swift --version, build, test, `swift package --allow-writing-to-package-directory generate-acp`, then `git diff --exit-code` diff gate.

    VERIFICATION: swift build clean; two consecutive generator runs → run 1 stamps (only .schema-hash new; all .generated.swift byte-identical), run 2 is a no-op. swift test: 108 ACPGenerateTests + 70 FoundationModelsACPTests = 178, zero warnings, zero failures. Left in doing for review.
  timestamp: 2026-07-15T15:20:47.414511+00:00
depends_on:
- 01KXHB8QAXW73Z00S3HEE3F2AZ
- 01KXHB95AAD18C1CN4QTT9QWXJ
position_column: review
position_ordinal: '80'
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