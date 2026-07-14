---
depends_on:
- 01KXHB88Q1GSGHMPXHNSMKM2XF
position_column: todo
position_ordinal: '8580'
title: 'Codegen: method-routing table from meta.json + Unstable namespace'
---
## What
Extend `acp-generate` to derive method routing from the vendored manifests, never hand-wired (spec §6 — this structurally avoids the TS-SDK bug where `setSessionModel` was wired to `session/set_mode`):

- Parse `Schema/acp-v1.meta.json`'s per-method `x-side` / `x-method` entries and emit a routing table: wire method name (`session/new`, `fs/read_text_file`, `terminal/create`, …) ↔ Swift handler name (`newSession`, `readTextFile`, `createTerminal`) ↔ side (agent/client) ↔ kind (request/notification) ↔ param/result types.
- Emit the **stable** set including `session/set_config_option`, `logout`, `session/list`, `session/resume`, `session/delete`, `session/close`, request cancellation, boolean session config options (spec §10 stable list at v1.19). Mark `session/set_mode` deprecated in the emitted table.
- Parse `Schema/acp-v1.meta.unstable.json` and emit those methods (`elicitation/*`, `providers/*`, `session/fork`, `nes/*`, `mcp/*`, `document/did*`) into a clearly separated `Unstable` namespace, capability-gated and documented as unsettled.

## Acceptance Criteria
- [ ] Routing table is generated purely from meta.json — no hand-typed method-name strings in dispatch code
- [ ] Every stable v1.19 method appears with correct side/kind; `session/set_mode` carries a deprecation marker
- [ ] Unstable methods live only under the `Unstable` namespace

## Tests
- [ ] `Tests/ACPGenerateTests/RoutingTableTests.swift` — assert generated table entries for a sample of methods across both sides and both kinds (request vs notification), including `session/prompt` (agent, request) and `session/update` (client, notification)
- [ ] `Tests/ACPGenerateTests/UnstableNamespaceTests.swift` — assert unstable methods are emitted only in the Unstable namespace
- [ ] Run `swift test` — exits 0

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.