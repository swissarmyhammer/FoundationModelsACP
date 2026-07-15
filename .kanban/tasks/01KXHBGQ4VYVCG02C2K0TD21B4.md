---
depends_on:
- 01KXHBFRJDWJZ57DG99E2X6RA0
- 01KXHBF83D8946330PRGG0PZ84
- 01KXHBCR1PXZ8AGKHQ4WRF8DZD
position_column: doing
position_ordinal: '80'
title: Library README and API documentation
---
## What
Write the package's public-facing docs once the API surface is real:

- `README.md` (library mode: no logo, leads with the inline runnable flagship one-liner from spec §7 — `AgentSideConnection(stream: .stdio) { conn in FoundationModelsAgent(connection: conn, session: ...) }.run()`), covering: what ACP is (one paragraph), both roles, the FM bridge, the ACP→Transcript utility, SessionProvider hooks, and the test transports.
- A **loud "stdout is sacred" section** for agent authors (spec §5): all logging to stderr; a stray `print` corrupts framing — the field failure.
- Codegen contributor notes: `swift package generate-acp`, schema bump procedure (link `Schema/README.md`), CI diff gate.
- DocC comments on the primary public entry points (`AgentSideConnection`, `ClientSideConnection`, `FoundationModelsAgent`, `SessionProvider`, the update-stream API) so `swift package generate-documentation` (or Xcode DocC build) succeeds without warnings on those symbols.

## Acceptance Criteria
- [ ] README's usage example compiles (kept honest by a doc-example test, below)
- [ ] stdout-discipline section present and prominent
- [ ] DocC build succeeds; primary entry points documented

## Tests
- [ ] `Tests/FoundationModelsACPTests/ReadmeExampleTests.swift` — a compile-checked version of the README example(s) (behind a scripted provider so no live model is needed)
- [ ] CI step: DocC build (or `swift build` with documentation) exits 0
- [ ] Run `swift test` — exits 0

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.