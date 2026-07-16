# Contributing

## Regenerating the ACP types

The protocol types under `Sources/FoundationModelsACP/Generated/` are generated from the vendored JSON schema in `Schema/` and checked in, so consumers just compile source — no plugin or tool needed to build the package.

- **Regenerate:** `swift package generate-acp`. A build does zero codegen work unless the schema's content hash changed, so this is a no-op after a normal checkout.
- **Bump the ACP version:** drop in the new `schema.json` / `meta.json` / `meta.unstable.json` artifact set and run `swift package generate-acp` — nothing else changes by hand. The full procedure (pinned release, SHA-256 verification, the routing manifest) lives in [`Schema/README.md`](Schema/README.md).
- **CI diff gate:** CI regenerates from the vendored schema and runs `git diff --exit-code`, failing on any drift — the committed output always matches the schema. A separate step builds the DocC documentation with warnings-as-errors, so the public API always documents cleanly.

## Tests

`swift test` runs the deterministic suite (no live model). The `FoundationModelsACPEvals` target drives the on-device `SystemLanguageModel` and is gated behind `RUN_EVALS=1`; run it with `RUN_EVALS=1 swift test --filter FoundationModelsACPEvals` on Apple Silicon.
