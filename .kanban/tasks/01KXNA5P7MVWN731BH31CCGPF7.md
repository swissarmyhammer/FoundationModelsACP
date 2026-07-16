---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
title: 'TranscriptBuilder: merge multi-update tool calls so terminal-embed turns round-trip losslessly'
---
## What

`Sources/FoundationModelsACP/Bridge/TranscriptBuilder.swift` — in `fold(_:)`, every `.toolCallUpdate` unconditionally appends a fresh `.toolOutput` entry via `toolOutputEntry(from:)`. But this bridge's own wire stream can emit more than one `tool_call_update` per call: `ClientEnvironment.runCommand` (`Sources/FoundationModelsACP/Bridge/ClientEnvironment.swift`, the `status: .inProgress` update whose only content is `.terminal(Terminal(...))`) is followed later by `TranscriptMapper`'s `completed` update. Folding such a turn yields a spurious empty `.toolOutput` plus a duplicate entry for the same `toolCallId` — so FM → ACP → FM is not lossless for command-running tools, the exact composition the bridge ships.

Fix in `fold(_:)` / `toolOutputEntry(from:)`: skip non-final updates (ignore `tool_call_update` whose `status` is not `completed`/`failed`, and/or ones with no foldable content), or merge updates by `toolCallId` into the already-appended `.toolOutput` entry (the builder already tracks `toolNamesByCallId`, so id-keyed state is an established pattern). Preserve the existing straggler policy and document the chosen rule in the `fold(_:)` doc comment.

Current round-trip tests (`Tests/FoundationModelsACPTests/Bridge/RoundTripTests.swift`) only cover streams produced by `TranscriptMapper` alone, which is why this was missed.

## Acceptance Criteria

- [ ] Folding a stream containing a `tool_call_update(status: .inProgress, content: [.terminal(...)])` followed by a `tool_call_update(status: .completed, ...)` for the same `toolCallId` produces exactly one `.toolOutput` entry for that id, with the completed content — no empty or duplicate entries.
- [ ] Round-trip equivalence holds for a turn that includes a terminal-embed update sequence (re-projecting the folded transcript through `TranscriptMapper` yields the same final update set as before).
- [ ] Existing straggler-tolerance behavior and all current `RoundTripTests`/`TranscriptBuilder` tests remain green.
- [ ] The `fold(_:)` doc comment states the multi-update merge/skip rule.

## Tests

- [ ] New regression test in `Tests/FoundationModelsACPTests/Bridge/RoundTripTests.swift` (or the TranscriptBuilder test file) folding an `inProgress` terminal-embed update + `completed` update for one `toolCallId`; fails before the fix (two entries, one empty), passes after (one entry).
- [ ] A round-trip test whose update stream is the composed bridge output shape (tool call → terminal embed in_progress → completed), asserting lossless re-projection.
- [ ] `swift test --skip FoundationModelsACPEvals` → green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.