---
depends_on:
- 01KXHBDAK0NQ5RA2NWTF1ESXQP
position_column: todo
position_ordinal: '9180'
title: 'Bridge session management: provider hooks → list/resume/delete/close'
---
## What
Forward the session-management surface to the `SessionProvider` hooks (spec §7.1 — note §7.2: this seam is the ACP v2 baseline shape, not optional polish):

- `listSessions` → `provider.listSessions` (→ `[SessionSummary]`); `resumeSession`/`loadSession` → `provider.restoreSession` (typically `LanguageModelSession(model:tools:transcript:)`); `deleteSession` → `provider.deleteSession`; `closeSession` drops the live session from the bridge's map (and is supported whenever sessions are).
- Absent hooks → capability off in `initialize` AND JSON-RPC -32601 method-not-found if called anyway (spec §4).
- The bare one-liner (`FoundationModelsAgent(connection:session:)`) advertises none of these — it doesn't pretend to have a store.
- A resumed session behaves identically to a fresh one for subsequent prompts (same turn path).

## Acceptance Criteria
- [ ] With all hooks present: `session/list`, `session/resume`, `session/delete`, `session/close` round-trip through the provider and return correct wire responses
- [ ] With hooks absent: capabilities are off and direct calls answer -32601
- [ ] A prompt on a resumed session runs the normal turn path against the restored `LanguageModelSession`

## Tests
- [ ] `Tests/FoundationModelsACPTests/Bridge/SessionManagementTests.swift` — in-memory provider store exercising all four methods, both hook-present and hook-absent variants
- [ ] Run `swift test` — exits 0

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.