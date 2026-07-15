# Eval fixtures

Seed transcripts for the behavioral eval suite (spec §8). Each case is a
golden-format ndJSON **pair**, loaded by path (`#filePath`) and excluded from
the test target in `Package.swift`, so they are plain data, never compiled
resources.

The Evaluations framework of WWDC 2026 is not present on this toolchain (probed
via `import Evaluations` and an SDK framework/module scan — see the task
thread), so the eval layer is a hand-rolled scoring harness over the live
on-device `SystemLanguageModel`, driven through the real `FoundationModelsAgent`
bridge. A captured transcript is therefore both a deterministic wire fixture and
a live eval case.

## File layout

Each case `<name>` is two files:

- `<name>.script.ndjson` — the client→agent requests (`initialize`,
  `session/new`, `session/prompt`). The `session/prompt` request supplies the
  case's **prompt**.
- `<name>.agent.ndjson` — the agent→client stream a correct turn produces. The
  first `tool_call` `session/update` supplies the **expected tool** (its
  `title`) and the **argument keys** its `rawInput` object must carry.

The loader (`EvalCase.load`) reads exactly those two facts; the rest of the
stream documents the ideal turn. The end-to-end wire golden
(`../FoundationModelsACPTests/Fixtures/golden-session-*.ndjson`) is seeded here
too, proving one transcript serves both layers.

## Scoring

`EvalHarness` drives each case's prompt through the real bridge over the live
model `EvalPolicy.samplesPerCase` times and scores three metrics per sample:

- **tool selection** — a `tool_call` named the expected tool appeared;
- **well-formed call** — that call carried a non-empty id and a `rawInput`
  object holding every expected argument key;
- **structured result** — the turn emitted a completed `tool_call_update`
  (reported, not gated).

A run **passes** when the aggregate tool-selection and well-formed rates both
clear `EvalPolicy.passThreshold` (0.8). The threshold is conservative: an
on-device probe selected the correct tool for these directive prompts on every
trial, so 0.8 leaves headroom for beta-toolchain variance while still catching a
real regression.

Live scoring runs only when `RUN_EVALS=1` is set **and** the model is available;
otherwise it is skipped, so a plain `swift test` never drives the model. Run it
explicitly:

```sh
RUN_EVALS=1 swift test --filter FoundationModelsACPEvals
```

## Adding a new eval case from a captured run

1. **Capture a run.** Drive a real session (e.g. via the `acp-test-agent` over
   stdio, or the end-to-end golden recorder `RECORD_GOLDEN=1 swift test --filter
   GoldenReplayTests`) and tee the client→agent and agent→client byte streams to
   two files. Curate them so the agent stream shows the *correct* tool call —
   this is the ground truth the eval scores against.
2. **Name the pair** `Tests/FoundationModelsACPEvals/Fixtures/<name>.script.ndjson`
   and `<name>.agent.ndjson`. Use a directive prompt (name the tool and the
   argument), so the on-device model reliably selects it.
3. **Register the tool.** If the case names a tool not already in
   `EvalToolRegistry`, add a `FoundationModels.Tool` for it (see `EvalTools.swift`)
   and its name to `knownToolNames`. Existing tools: `getWeather` (`city`) and
   `reader` (`path`, served over the reverse `fs/read_text_file` path).
4. **Verify.** `swift test --filter FoundationModelsACPEvals` parses the new
   fixture deterministically; `RUN_EVALS=1 swift test --filter
   FoundationModelsACPEvals` scores it against the live model.
