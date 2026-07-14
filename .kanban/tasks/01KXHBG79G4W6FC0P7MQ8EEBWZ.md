---
depends_on:
- 01KXHBFRJDWJZ57DG99E2X6RA0
position_column: todo
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
- [ ] Eval suite runs against the live local model with zero network/API-key configuration
- [ ] At least the tool-selection and well-formed-tool-call metrics are scored across a multi-case set with a documented threshold
- [ ] CI has a distinct eval job; wire tests pass/fail independently of it

## Tests
- [ ] The eval suite itself (`swift test --filter FoundationModelsACPEvals` or the Evaluations framework's runner) — exits 0 at or above threshold on Apple Silicon
- [ ] A unit test that eval-case loading parses every seeded transcript fixture
- [ ] Run `swift test` — exits 0

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.