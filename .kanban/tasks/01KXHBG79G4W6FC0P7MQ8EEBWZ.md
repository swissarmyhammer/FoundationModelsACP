---
comments:
- actor: wballard
  id: 01kxkvxhsmyep94skbsq6jrn7n
  text: |-
    Picked up. EVALUATIONS FRAMEWORK PROBE (macOS 27 beta SDK, MacOSX27.0.sdk, arm64-apple-macosx27, Xcode-beta) — NOT AVAILABLE. What I tried:
    - `import Evaluations` / `import Evaluation` / `import ModelEvaluation` / `import FoundationModelsEvaluation` via `xcrun swiftc -sdk <sdk> -target arm64-apple-macosx27 -typecheck` → all "error: no such module 'X'".
    - Framework dir scan: `ls $SDK/System/Library/Frameworks | grep -iE 'eval|assess|benchmark|scor|metric'` → only AutomaticAssessmentConfiguration.framework + MetricKit.framework (unrelated).
    - No *.swiftmodule matching eval/assess/benchmark; no module.modulemap mentioning "eval"; no *.swiftinterface declaring EvaluationSuite/EvaluationCase/etc.
    - FoundationModels itself imports fine (binary module, no swiftinterface) but exposes no evaluation submodule/symbols.

    CONCLUSION: the WWDC 2026 Evaluations framework simply does not ship in this beta. Per the task's explicit instruction, I will NOT fake it. Falling back to the spec's intent using only what IS available: a hand-rolled scoring harness over the live on-device SystemLanguageModel via FoundationModelsAgent. Divergence (framework unavailable → hand-rolled scoring harness) will be documented in code and here. The eval LAYER is the deliverable; the specific framework is the means.

    Plan: Tests/FoundationModelsACPEvals/ test target driving prompt cases through the live model via the bridge, scoring tool-selection + well-formed-tool-call (+ structured-result) metrics statistically with a documented threshold, seeded from the captured golden transcripts; gated behind availability + an opt-in env flag so eval variance never blocks the deterministic wire suite; distinct CI job.
  timestamp: 2026-07-15T21:46:23.924940+00:00
- actor: wballard
  id: 01kxkw5nx5g7v00jptqr0jqsw1
  text: |-
    LIVE MODEL PROBE (standalone swiftc against MacOSX27.0.sdk, arm64-apple-macosx27):
    - SystemLanguageModel.default.availability == .available on this machine.
    - A directive prompt ("Use the getWeather tool to look up the weather in Paris.") against a LanguageModelSession(tools:[getWeather]) reliably emits a well-formed tool_call: name=getWeather, args={"city":"Paris"}, every snapshot. Turn latency ~3.6s. On-device tool selection for directive prompts is highly reliable in this beta.

    DESIGN LOCKED (hand-rolled scoring harness; framework unavailable):
    - New test target FoundationModelsACPEvals (Tests/FoundationModelsACPEvals/), depends on FoundationModelsACP.
    - EvalCase + loader parses a golden-format ndjson transcript PAIR (client->agent script + agent->client stream) into { name, prompt blocks, expectedTool(name, argKeys)? }: prompt from the session/prompt request, expected tool from the first tool_call session/update (title + rawInput keys). Proves "one transcript is both fixture and eval case" and seeds the set from captured goldens (incl. the wire golden at Tests/FoundationModelsACPTests/Fixtures/).
    - EvalTools: FoundationModels Tool impls the harness registers (getWeather{city}; reader{path} reading via ClientEnvironment.current so the live reverse fs/read is exercised too).
    - Harness drives each case serially through the REAL FoundationModelsAgent over InMemoryTransport with a live-model-backed session (initialize .readOnly + session/new + session/prompt), collects the session/update stream, scores tool-selection + well-formed-tool-call (+ structured-result). N samples/case, aggregate pass rate.
    - Metrics: tool-selection = fraction of samples emitting a tool_call whose title==expected; well-formed = fraction with non-empty toolCallId AND rawInput a JSON object containing the expected arg keys; structured-result = fraction with a completed tool_call_update. THRESHOLD 0.8 (documented; probe showed ~100%, 0.8 leaves beta headroom). samples=5/case.
    - Gating/CI isolation: live scoring runs only when availability==.available AND RUN_EVALS=1; otherwise skipped with a clear reason, so plain `swift test` (wire suite) never drives the model and never flakes. The loader-parses-every-fixture unit test is deterministic and always runs. CI gets a distinct eval job (Apple Silicon) that sets RUN_EVALS=1; the wire job does not.
    - Concurrency: cases serial, one session per case, one turn at a time -> no SIGTRAP.

    Proceeding to implement via /tdd.
  timestamp: 2026-07-15T21:50:50.277224+00:00
- actor: wballard
  id: 01kxkwyg8686b8ah16fps2cwjt
  text: |-
    Implementation landed (green). New test target Tests/FoundationModelsACPEvals/ (added to Package.swift, Fixtures excluded — #filePath-loaded):
    - EvalTranscript.swift: EvalCase + ToolExpectation + loader parsing a golden-format ndjson PAIR (prompt from session/prompt request; expected tool name+arg-keys from first tool_call session/update) + JSONValue nav helpers.
    - EvalTools.swift: FoundationModels Tools registered on every session — getWeather{city} (fixed string) and reader{path} (reads via ClientEnvironment.current, defensive). EvalToolRegistry.all/knownToolNames.
    - EvalHarness.swift: drives each case through the REAL FoundationModelsAgent over InMemoryTransport with a live-model-backed session; EvalRecordingClient records session/update + serves fs/read + grants permission; 120s per-turn timeout so a wedged turn fails rather than hangs.
    - EvalScore.swift: SampleOutcome (tool-selected / well-formed / structured-result) + CaseScore + EvalReport(meetsThreshold, summary). EvalPolicy.samplesPerCase=5, passThreshold=0.8 (documented rationale in-code). Gated metrics = selection + well-formed; structured-result reported not gated.
    - EvalFixtures.swift: discovers <name>.script/.agent.ndjson pairs; also seeds the wire golden (Tests/FoundationModelsACPTests/Fixtures/golden-session-*).
    - EvalSuiteTests.swift @Suite("FoundationModelsACPEvals"): (1) loader parses EVERY seeded fixture [always runs]; (2) every live-scored fixture declares a known directive tool [always runs]; (3) live scoring meets threshold [.enabled(if: RUN_EVALS && model available), else skipped with reason].
    - Fixtures/: weather-paris + read-file pairs (directive prompts) + README documenting the add-a-case-from-a-captured-run procedure.
    - CI: added a distinct `evals` job (runs-on [self-hosted, macOS, ARM64], RUN_EVALS=1, `swift test --filter FoundationModelsACPEvals`), separate from the wire `build-test-codegen` job whose plain `swift test` self-skips live scoring.

    VERIFICATION: swift build --build-tests 0 warnings/0 errors. Plain `swift test` = 176 FoundationModelsACPTests + 108 ACPGenerateTests + 3 FoundationModelsACPEvals = 287 pass, 0 failures; the ONE skip is the gated live eval (by design — CI isolation). Live run `RUN_EVALS=1 swift test --filter FoundationModelsACPEvals` = PASS, overall select 100% / well-formed 100% / result 100% across both cases (10 live turns, ~44s). No SIGTRAP (cases serial, one session/turn at a time).

    DISCOVERY (resolves the bridge/e2e open question): with a LIVE model, the reader case's turn produced a completed tool_call_update (structured-result 100%), i.e. the FM runtime invoked the tool INSIDE runTurn's structured-concurrency tree where ClientEnvironment.$current is bound — so the ambient injection reaches the live FM tool call (the reader tool read through the client over reverse fs/read_text_file). The e2e thread could only confirm this for scripted turns; the live eval now confirms it end-to-end. Checkpoint + review next.
  timestamp: 2026-07-15T22:04:23.686425+00:00
- actor: wballard
  id: 01kxkxjnx0pqwxsqk76mqb380f
  text: |-
    RESOLVED → done. Converged in one review pass (finding fixed at root + a follow-on comment-accuracy finding, both cleared; re-review clean, 0 findings). Not forced.

    Local commits only (nothing pushed):
    - 89b54c7 test(evals): behavioral eval suite over the live SystemLanguageModel
    - d3b3990 refactor(evals): extract shared fixturesExclude in Package.swift (review finding 1)
    - 1d5de2b docs(evals): correct the Fixtures-exclude comment (review finding 2)
    - c93f488 chore(kanban): mark task done

    Review trail (sha HEAD~1..HEAD each pass): pass 1 = 1 finding (Package.swift "Fixtures" literal duplicated across two test targets) → extracted `fixturesExclude`; pass 2 = 1 finding (my new comment over-claimed "every test target") → scoped the comment (ACPGenerateTests has no Fixtures dir); pass 3 = CLEAN (0 findings, 14 validators attempted, 0 failed).

    FINAL VERIFICATION:
    - swift build --build-tests: 0 warnings / 0 errors.
    - Plain `swift test`: 176 FoundationModelsACPTests + 108 ACPGenerateTests + 3 FoundationModelsACPEvals = 287 pass, 0 failures. The single skip is the gated live eval (by design — CI isolation), reported with a clear reason.
    - `RUN_EVALS=1 swift test --filter FoundationModelsACPEvals`: PASS. OVERALL select 100% / well-formed 100% / result 100% across weather-paris + read-file (5 samples each = 10 live turns, ~44s), threshold 0.8.

    EVALUATIONS FRAMEWORK: NOT available on this toolchain (documented divergence). Delivered the eval LAYER as a hand-rolled scoring harness over the live on-device SystemLanguageModel via the real bridge, per the card's fallback clause.

    METRICS + THRESHOLD: tool-selection (a tool_call named the expected tool) and well-formed-tool-call (non-empty toolCallId + rawInput object carrying the expected arg keys) are the gated metrics; structured-result (completed tool_call_update) is reported. Pass threshold 0.8 on the aggregate of the two gated metrics across all samples; 5 samples/case. Rationale in EvalScore.swift + Fixtures/README.md.

    CI ISOLATION: two independent jobs in .github/workflows/ci.yml — `build-test-codegen` (macos-15, plain `swift test`, live scoring self-skips → eval variance can never fail it) and `evals` (self-hosted macOS ARM64, RUN_EVALS=1, `swift test --filter FoundationModelsACPEvals`). Distinct job statuses → wire tests pass/fail independently.

    For README (^0td21b4): eval suite lives in Tests/FoundationModelsACPEvals/; new cases are added as golden-format <name>.script/.agent.ndjson pairs in its Fixtures/ (+ a tool in EvalToolRegistry if new) — full procedure in Tests/FoundationModelsACPEvals/Fixtures/README.md. The wire golden doubles as a seeded eval case (loader-parsed).
  timestamp: 2026-07-15T22:15:24.832118+00:00
depends_on:
- 01KXHBFRJDWJZ57DG99E2X6RA0
position_column: done
position_ordinal: '9480'
title: Evaluations-framework eval suite over the local SystemLanguageModel
---
## What
Add the behavioral-quality layer (spec §8): point WWDC 2026's **Evaluations framework** at `FoundationModelsAgent` running over the on-device `SystemLanguageModel` — free, no API keys, reproducible enough to gate CI on Apple Silicon.

- An eval target/suite (e.g. `Tests/FoundationModelsACPEvals/`) that runs prompt cases through the live local model via the bridge and scores: does the prompt reliably produce a well-formed `tool_call`, the right tool, a correct structured result — measured statistically across cases, not single-shot asserts.
- Seed the eval set from the captured golden transcripts (spec §8: one transcript is both a deterministic fixture and an eval case).
- Wire into CI as a separate job/step that runs on Apple Silicon; deterministic wire tests stay independent so eval flake never blocks them. Choose and document a pass threshold.
- Document how to add a new eval case from a captured run.

## Acceptance Criteria
- [x] Eval suite runs against the live local model with zero network/API-key configuration
- [x] At least the tool-selection and well-formed-tool-call metrics are scored across a multi-case set with a documented threshold
- [x] CI has a distinct eval job; wire tests pass/fail independently of it

## Tests
- [x] The eval suite itself (`RUN_EVALS=1 swift test --filter FoundationModelsACPEvals`) — PASS, 100% select/well-formed/result across both cases (threshold 0.8)
- [x] A unit test that eval-case loading parses every seeded transcript fixture
- [x] Run `swift test` — exits 0 (287 tests; the one skip is the gated live eval, by design)

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

DIVERGENCE (recorded): the WWDC 2026 Evaluations framework does not ship on this toolchain (probed via `import Evaluations`/variants + SDK framework/module scan — all absent). Per the card, not faked: the eval layer is a hand-rolled scoring harness over the live on-device SystemLanguageModel driven through the real FoundationModelsAgent bridge. See task thread for the full probe.

## Review Findings (2026-07-15 17:04)

- [x] `Package.swift:74` — Literal "Fixtures" repeated in exclude lists across multiple test targets (also appears on line 62); should be extracted to a named constant so changes are made in one place. Define `let testFixturesExclude = ["Fixtures"]` at package level and reference it in both test targets' exclude properties. RESOLVED in d3b3990 (extracted `fixturesExclude`) + 1d5de2b (corrected the accompanying comment). Re-review of the delta is clean (0 findings).