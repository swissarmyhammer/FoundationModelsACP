---
comments:
- actor: wballard
  id: 01kyf48d1pk4gx397q21tzas7n
  text: |-
    ## Add to the verification list: do display terminals exist at all?

    A correction to this task's premise. The plan previously asserted that v2 replaces client-run terminals with an *agent-owned display terminal* stream, and three ACP-family plans were written on that basis. **The sources disagree, and the one I relied on is not the authoritative one.**

    **Certain:** all five client `terminal/*` methods are removed.

    **Unconfirmed:** the display-only successor. The v1->v2 **migration guide** describes it concretely -- `terminal_update` upserts keyed by `terminalId`, `terminal_output_chunk` appending RFC 4648 base64 bytes, a `terminal` content reference, and *"The surface is display-only: it has no input, resize, interrupt, kill, wait, release, or execution semantics"* -- and does **not** mark it unstable or feature-flagged.

    But the code-generating surfaces do not show it:

    - the v2 **content page** lists exactly five variants: `text`, `image`, `audio`, `resource`, `resource_link` -- **no `terminal`**;
    - the v2 **schema** shows no `terminal_update`, no `terminal_output_chunk`, and no terminal content block;
    - there is **no v2 Terminals doc page**, where v1 has one.

    What the schema *does* carry: a **`TerminalId`** type and a **`terminalId`** field on **`CommandPermissionSubject`** -- *"The associated terminal, when already known. Omitted and `null` are equivalent."* So a permission request for a command can reference a terminal the client already has by other means, without ACP providing any terminal surface itself.

    ### What to determine

    - [ ] Do `terminal_update` / `terminal_output_chunk` exist as `session/update` variants in the **stable** v2 schema?
    - [ ] Is there a `terminal` content block variant?
    - [ ] If neither: are they in an **unstable** v2 schema companion?
    - [ ] Confirm `TerminalId` and `CommandPermissionSubject.terminalId` are the only terminal-shaped things in the stable surface.

    Then **correct all three ACP-family plans with the answer** -- `FoundationModelsACP`, `FoundationModelsACPClient` (its M5 is currently scoped as "verify, then render only if real"), and `FoundationModelsACPAgent` (whose §8.6 no longer plans ShellTool -> display-terminal plumbing pending this).

    Caveat on my own evidence: the schema fetch was reported as truncated, so a negative result there is weaker than the content page's explicit five-variant list. Read the schema file directly rather than trusting that summary.
  timestamp: 2026-07-26T11:51:37.782612+00:00
position_column: todo
position_ordinal: '80'
title: M0 Vendor the v2 schema, delete v1, verify the inventory
---
## Starting point

**This is a rewrite, not a greenfield build.** A complete ACP v1 implementation lived in this repo and was deleted on the `v2-reset` branch; see `plan.md` -> *Starting point* for the full kept/dropped inventory. Everything below assumes that reset has already landed.

**Already done by the reset** (do not redo):

- The v1 schema artifacts (`Schema/acp-v1*.json`) and every generated v1 source are gone.
- `Schema/` is empty; `Sources/FoundationModelsACP/` retains only `Core/{JSONValue, AbsolutePath, MethodInfo, WireRawValueCodable}.swift`.
- `swift build` and `swift test` are green (43 generator tests).

**Still standing, and yours to work with:** the codegen pipeline — `Sources/ACPGenerateCore/` (schema model, emitter, tagged/anyOf union stages, routing-table builder, hash stamp), `Sources/acp-generate/`, and the `GenerateACP` command plugin. It is schema-vocabulary-independent and does not need rewriting.

## What

`plan.md` -> **M0**. First task of the v2-only reset.

- **Vendor `acp-v2.json`** (+ its meta manifest) from https://agentclientprotocol.com/protocol/v2/schema. Vendor a `meta.unstable.json` companion **only if v2 actually publishes one** — v2 may have no unstable namespace at all.
- **Re-point the generator's v1-shaped configuration.** `SchemaSet.acpV1` and `GeneratorConfig.acpV1` in `Sources/ACPGenerateCore/` still carry v1 names, v1 file paths, and v1-specific field mappings (`ReadTextFileRequest.path`, `CreateTerminalRequest.cwd`, `LoadSessionRequest.*`, `WriteTextFileRequest.path`) — for types v2 deletes. Rename to v2 and rebuild the `wireInvariantFields` map from the actual v2 schema.
- Regenerate; confirm the SwiftPM command plugin (`swift package generate-acp`), the content-hash no-op, and the CI fail-on-diff gate all come back green against the new schema. **The CI codegen job fails today** because there is no vendored schema — restoring it is part of this task.
- If v2 publishes no unstable manifest, the generator's `Unstable` namespace support (`unstableMethodModels`, `Emitter.unstableNamespaceDeclaration`, `UnstableMethodInfo`) is dead code. Say so explicitly, and either remove it or record why it stays.
- **Verify the actual method and payload inventory against the schema, not against `plan.md`.** Only the overview, migration, session-setup, and content pages were read closely; the migration guide has already proven to run ahead of the schema on terminals. Known unknowns to resolve:
  - Does `session/delete` exist alongside `session/close`? (v1 had `deleteSession`; v2 may not.)
  - The exact `session/update` variant list and their discriminator strings.
  - Do `terminal_update` / `terminal_output_chunk` and a `terminal` content variant exist in the v2 schema at all? The migration guide describes them; the schema and content-block list do not show them.
  - Whether `mcp/connect` / `mcp/message` / `mcp/disconnect` exist in v2. They were v1-unstable and do not appear in v2's published method lists. If absent, say so explicitly in the plan so nothing is built on them.
  - Whether a whole-message upsert can **delete** a message or only clear its content.
- Record any divergence between the schema and `plan.md` by **correcting the plan**, not by working around it.

## Test coverage to re-establish

The reset dropped 44 tests that were pinned to the v1 vendored schema. This task restores the vendored-schema half; `plan.md` -> *Starting point* tracks the rest against their milestones.

- Emission assertions driven by the real vendored schema — that generation over `acp-v2.json` produces the expected declarations, deterministically.
- The hash-stamp tests now run on a synthetic fixture (`SyntheticArtifacts` in `Tests/ACPGenerateTests/GenerationTestSupport.swift`); decide whether to also assert against the real vendored artifacts.

## Acceptance Criteria

- [ ] `acp-v2.json` (+ meta) vendored, with SHA-256 and upstream source recorded in `Schema/README.md`.
- [ ] `SchemaSet` and `GeneratorConfig` renamed off `acpV1` and re-pointed; `wireInvariantFields` rebuilt from the v2 schema.
- [ ] `swift package generate-acp` produces the v2 surface; output checked in.
- [ ] Content-hash no-op verified (second run changes nothing).
- [ ] CI codegen diff gate green again.
- [ ] Vendored-schema emission tests restored against v2.
- [ ] `plan.md` corrected wherever the schema disagrees with it, including every known unknown above.
- [ ] The `Unstable` namespace question answered explicitly.
- [ ] README already states v2 is **draft** and that v1 is not served — confirm it still matches what the schema turned out to be.

## Tests

- [ ] `swift build` and `swift test` green.
- [ ] Regeneration is idempotent.
- [ ] A deliberate hand-edit to a generated file is caught by the CI gate (verified, then reverted).

## Workflow

- Read the v2 schema first; treat it as authoritative over the plan.
- `git log -p` on the reset commit's parent shows the deleted v1 generated output — useful as a shape reference for what the generator emits.
