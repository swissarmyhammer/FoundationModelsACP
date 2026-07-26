# Contributing

## Regenerating the ACP types

The protocol types under `Sources/FoundationModelsACP/Generated/` are generated from the vendored JSON schema in `Schema/` and checked in, so consumers just compile source — no plugin or tool needed to build the package.

- **Regenerate:** `swift package generate-acp`. A build does zero codegen work unless the schema's content hash changed, so this is a no-op after a normal checkout.
- **Bump the ACP version:** drop in the new `schema.json` / `meta.json` / `meta.unstable.json` artifact set and run `swift package generate-acp` — nothing else changes by hand. The full procedure (pinned release, SHA-256 verification, the routing manifest) lives in [`Schema/README.md`](Schema/README.md).
- **Changing the generator itself:** the content-hash stamp keys off the *vendored artifacts*, so a generator change alone makes `swift package generate-acp` report "up to date" and write nothing. Delete `Sources/FoundationModelsACP/Generated/.schema-hash` to force a full run. `VendoredSchemaTests` catches a stale checked-in surface either way — it generates in memory on every run and compares.
- **CI diff gate:** CI regenerates from the vendored schema and runs `git diff --exit-code`, failing on any drift — the committed output always matches the schema. A separate step builds the DocC documentation with warnings-as-errors, so the public API always documents cleanly.

## Tests

`swift test` runs the full deterministic suite — no live model, no network, no gated targets.
