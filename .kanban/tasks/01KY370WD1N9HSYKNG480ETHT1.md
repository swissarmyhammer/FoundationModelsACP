---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: Rewrite README and GUIDE to the wire-only story; record the scoping decision in plan.md
---
## What
The docs still present the superseded bridge as the flagship. Rewrite them to the reborn, wire-only positioning: **this package is the ACP wire layer for Swift — generated v1.19.0 schema types, `Agent`/`Client` role protocols, `AgentSideConnection`/`ClientSideConnection`, ndJSON framing, transports — with (near-)zero dependencies.** The composition layer (config, slash commands, tool roster, `HarnessACPAgent`) will live in a separate package and is out of scope here.

- `README.md`: remove all bridge references — `FoundationModelsAgent`, `SessionProvider`, `LanguageModelSession`, `TranscriptBuilder` (named around line 49), and the "running the eval suite" link near line 50 (the Evals target is deleted by the follow-on task). Replace the usage example with a pure-wire one: implement `Agent` (a minimal scripted/echo agent), serve it over `AgentSideConnection` + `StdioTransport`; a `ClientSideConnection` example driving an agent. Keep the library-README shape (landing page per commit 27bc7be).
- `docs/GUIDE.md`: delete/replace BOTH bridge-flavored sections — "The FoundationModels bridge" (around line 48) AND "ACP → Transcript" (around line 75, documents `TranscriptBuilder`, which gets deleted). Replace with wire-layer guidance: role protocols, capability gating via default `methodNotFound` implementations, connection model (full-duplex, per-request Task dispatch, timeouts, fail-loud disconnect), ndJSON rules (stdout sacred, logger to stderr), transports, codegen workflow pointer to CONTRIBUTING.
- `Tests/FoundationModelsACPTests/ReadmeExampleTests.swift`: update to compile/exercise the new README examples; no `import FoundationModels` and no reference to any symbol defined under `Tests/FoundationModelsACPTests/Bridge/` or `Sources/FoundationModelsACP/Bridge/` (e.g. `bridgeNewSessionRequest`, `messageChunkUpdate`, `TurnRecorder`, `ClientEnvironment`).
- `plan.md`: add a dated decision note at the top of "Decisions made at rebirth": this package is wire-only with minimal dependencies; the composition target (`FoundationModelsACPAgent`, §§4–7, 9.1, 10.1) moves to a future separate package; the Bridge/`SessionProvider` code and the model-driven Evals target are removed from this repo (§9.1 Superseded note executed).
- Check DocC catalog/landing page (if any under `Sources/FoundationModelsACP`) for bridge mentions and fix.

(CONTRIBUTING.md's Evals/`RUN_EVALS` section is handled by the deletion task, which removes the target itself.)

## Acceptance Criteria
- [ ] `grep -ri 'SessionProvider\|FoundationModelsAgent\|LanguageModelSession\|TranscriptBuilder' README.md docs/` returns nothing
- [ ] `grep -riw 'bridge' README.md docs/` returns nothing
- [ ] README example code is exercised by `ReadmeExampleTests` and the suite is green
- [ ] plan.md carries the wire-only scoping decision with today's date (2026-07-21)
- [ ] DocC build gate passes: `swift package generate-documentation` (CI's `--warnings-as-errors` gate)

## Tests
- [ ] `Tests/FoundationModelsACPTests/ReadmeExampleTests.swift` updated to the new examples; `swift test` exits 0
- [ ] DocC builds warning-free (CI `docc-target: FoundationModelsACP` gate)

## Workflow
- Use `/tdd` — update `ReadmeExampleTests` to the new example first, then make README match it.