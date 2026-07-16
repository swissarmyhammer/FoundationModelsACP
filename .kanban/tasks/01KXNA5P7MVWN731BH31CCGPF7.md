---
assignees:
- claude-code
comments:
- actor: wballard
  id: 01kxne4t0p8e5whbjatk0bynv4
  text: |-
    Picked up. Read the task + the three referenced threads (^gg0pz84 TranscriptBuilder, ^gs0d3kp TranscriptMapper, ^0gxpjd4 FM-tools/ClientEnvironment).

    ROOT CAUSE confirmed in Sources/.../Bridge/TranscriptBuilder.swift: fold's `.toolCallUpdate` case unconditionally appends a fresh `.toolOutput` via toolOutputEntry(from:). The shipped bridge composition for a command tool emits, for ONE toolCallId, three updates in order: tool_call(status .pending, from TranscriptMapper) → tool_call_update(status .inProgress, content [.terminal(Terminal(terminalId:))], from ClientEnvironment.runCommand) → tool_call_update(status .completed, text content, from TranscriptMapper). Folding today produces a .toolCalls entry + TWO .toolOutput entries for the id — the first empty (a .terminal ToolCallContent has no Transcript.Segment form, so segment(from:) returns nil) plus the real completed one. Not lossless.

    DESIGN (merge-by-id, the FM model: exactly one Transcript.ToolOutput per ToolCall.id):
    - New stored `toolOutputIndexByCallId: [String: Int]`; the first tool_call_update for an id creates the .toolOutput entry and records its index, every later update merges its segments into that existing entry (existing.segments + newSegments). Appends never shift recorded indices, so this stays valid alongside flushOpenGroup.
    - Terminal handle: a .terminal content block has no Transcript segment form; it is a transient live-render signal (spec §9), not persisted agent output. The command's real output (text, from the completed update) is preserved. Documented as the one inherently-unrepresentable field.
    - Update fold(_:) doc to state the merge rule.

    FM API check: Transcript.ToolOutput(id:toolName:segments:) — segments is a plain array; merge = concatenation. No new/invented API; matches the constructors verified in ^gs0d3kp/^gg0pz84.

    TDD plan: (1) regression — fold [tool_call, inProgress-terminal-embed, completed] asserts exactly one .toolOutput entry with the completed text (2 entries before fix). (2) round-trip — build canonical = TranscriptMapper().consume([toolCall,toolOutput]); compose stream = [canonical[0], inProgress terminal embed, canonical[1]] (exact bridge shape); fold → rebuilt → reproject; assert reproject == canonical. Both fail before, pass after. Existing 5 RoundTripTests (incl. straggler) stay green — each has exactly one update per id, so merge-map records once.
  timestamp: 2026-07-16T12:24:10.518762+00:00
position_column: doing
position_ordinal: '80'
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