---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01ky3efpdjd4q86rgja346w8ff
  text: 'Picked up. Research done: wire surface verified (AgentSideConnection/ClientSideConnection inits, `.stdio`/`.standardError`, ContentChunk/InitializeRequest default inits, Agent methodNotFound defaults, Connection per-request Task dispatch + fail-loud close, Schema pinned at schema-v1.19.0). plan.md already carries a top scope note dated 2026-07-21; will extend it to record the Bridge/SessionProvider + Evals removal decision (no "Decisions made at rebirth" heading exists — the top blockquote is that note). Plan: TDD — rewrite ReadmeExampleTests to pure-wire EchoAgent + ScriptedAgent examples first, then README, then GUIDE, then plan.md, then grep ACs + swift test + DocC gate.'
  timestamp: 2026-07-21T22:59:29.330407+00:00
- actor: claude-code
  id: 01ky3es12pf808szjmj1w2dzv4
  text: 'Implementation landed. (1) ReadmeExampleTests.swift rewritten first (TDD): pure-wire EchoAgent (README agent example verbatim, plain `import FoundationModelsACP`, no FoundationModels/Bridge symbols) + a client-example test against ScriptedAgent via makeEndToEndPair; reuses newSessionRequest/testCwd/MinimalClient/messageChunkUpdate helpers. (2) README.md rewritten to the wire-only landing page: schema-v1.19.0 tagline, EchoAgent + stdio example, ClientSideConnection example, stdout-sacred note kept. (3) docs/GUIDE.md rewritten: two roles, capability gating (methodNotFound defaults + ClientCapabilities), connection model (full-duplex, per-request Task dispatch, requestTimeout, fail-loud disconnect), ndJSON rules, four transports incl. SubprocessTransport, codegen pointer to CONTRIBUTING. (4) plan.md top scope note extended with dated (2026-07-21) removal decision for Bridge/SessionProvider/TranscriptBuilder/ClientEnvironment + Evals (no "Decisions made at rebirth" heading exists post-f37e562; the top blockquote is the decision note). Verification: both grep ACs empty; `swift test` exit 0 (187+3+116 tests, 3 runs, all pass); `swift package generate-documentation --target FoundationModelsACP --warnings-as-errors` exit 0, no warnings. No DocC catalog under Sources (glob found no .md/.docc).'
  timestamp: 2026-07-21T23:04:35.158719+00:00
- actor: claude-code
  id: 01ky3f0npcea0tjxthe2v0wrej
  text: 'really-done complete: verification commands green (swift test exit 0 — 187+3+116 tests across 3 runs; DocC --warnings-as-errors exit 0; both grep ACs empty) and adversarial double-check verdict PASS. Double-check confirmed: EchoAgent byte-identical between README and test; every GUIDE technical claim verified against source (methodNotFound defaults, requestTimeout nil default, ConnectionError.closed/.timedOut, per-request Task dispatch, garbage-line skip, SubprocessTransport stderr forwarding/one-shot reap, ReplayTransport(script:), .stdio leading-dot); all cross-references resolve; "zero library dependencies" holds (only swift-docc-plugin, a docs plugin). Bridge sources intentionally left in place for the follow-on deletion task. All description checkboxes ticked. Task left in doing for /review per the finish pipeline (no commit made — orchestrator handles checkpoint commits).'
  timestamp: 2026-07-21T23:08:45.644184+00:00
position_column: done
position_ordinal: 9a80
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
- [x] `grep -ri 'SessionProvider\|FoundationModelsAgent\|LanguageModelSession\|TranscriptBuilder' README.md docs/` returns nothing
- [x] `grep -riw 'bridge' README.md docs/` returns nothing
- [x] README example code is exercised by `ReadmeExampleTests` and the suite is green
- [x] plan.md carries the wire-only scoping decision with today's date (2026-07-21)
- [x] DocC build gate passes: `swift package generate-documentation` (CI's `--warnings-as-errors` gate)

## Tests
- [x] `Tests/FoundationModelsACPTests/ReadmeExampleTests.swift` updated to the new examples; `swift test` exits 0
- [x] DocC builds warning-free (CI `docc-target: FoundationModelsACP` gate)

## Workflow
- Use `/tdd` — update `ReadmeExampleTests` to the new example first, then make README match it.