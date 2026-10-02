---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3yr4z6dpf6k5wtbvhysfcv2
  text: 'API decision (agreed with foundationmodelsacpclient-ae): each `Change` case carries the new value, not only the ID: `entryAdded(index, entry)`, `entryChanged(index, entry)` (with the entry ID in the entry), and one case for each state field with its new value. The client can then update exactly one observable object without a second lookup. Also add a `reset()` (or an equivalent) so that a client that resumes an already-open session can clear the transcript before the replay; otherwise replayed chunks append again to existing messages.'
  timestamp: 2026-10-02T16:46:22.413310+00:00
- actor: claude-code
  id: 01m3yrg30ky22tcc17q2f78wdr
  text: 'Migration decision: do NOT delete `SessionUpdateAggregator` in this task. Mark it `@available(*, deprecated, message: "Use the session merge engine")` and keep it working (with the `name` fold from ^g2mkx79). FoundationModelsACPClient''s ACPSessionState still uses it until that package deletes ACPSessionState. A separate task removes it after foundationmodelsacpclient-ae reports that ACPSessionState is gone.'
  timestamp: 2026-10-02T16:52:26.771135+00:00
depends_on:
- 01M3YQYR2Y867FQBAZJG2MKX79
position_column: todo
position_ordinal: '8280'
title: Replace SessionUpdateAggregator with a Sendable session merge engine
---
## What

Replace `SessionUpdateAggregator` (`Sources/FoundationModelsACP/Session/SessionUpdateAggregator.swift`) with a `Sendable` struct engine that folds the full `session/update` stream into the complete session state. Do not keep the old API.

Two packages build on this engine:
- FoundationModelsACPClient: its `@MainActor @Observable` `SessionModel` (one observable object for each transcript entry) applies each change from the engine.
- FoundationModelsACPAgent: it uses the engine as its retained history, and replays it on `session/resume`.

This package does NOT add Observation or `@MainActor`.

## State the engine keeps

1. An ORDERED transcript. Each entry has a stable ID and a kind: user message, agent message, thought, tool call, terminal, plan, unknown.
   - Messages and thoughts: a whole update replaces `content`; a `*_chunk` appends (as now).
   - Tool calls: the first update creates the entry; later updates fold each field with `PatchField.folded(onto:)`, including `name`. Prefer a fold that cannot silently miss a new generated field (for example, a generated `folded(onto:)` on patch types, or a test that fails when a field is not folded).
   - Terminals: decoded bytes (`Data`); a chunk appends; an `output` snapshot replaces.
   - Plans: replaced by `planId`; the entry keeps the position where it first appeared.
   - Unknown: an unknown `SessionUpdate` case becomes an `unknown` entry with the type string and the raw `JSONValue`. Never drop it. Unknown content blocks stay in their message as the generated `.unknown` value.
   - Each entry keeps its `_meta`, folded with the wire field's rules.
2. Last-value state:
   - `availableCommands: [AvailableCommand]?`. `nil` = not reported. A seed comes from `NewSessionResponse` / `ResumeSessionResponse` (an omitted or empty list there leaves `nil`). Each `available_commands_update` replaces it (`[]` = "no commands").
   - `configOptions`: replaced by each `config_option_update` (it carries the full set).
   - `usage`: replaced by each `usage_update`.
   - `agentState`: replaced by each `state_update` (running / idle with `StopReason?` / requires action). `StopReason.unknown(String)` keeps extension values such as `_truncated`.
   - `sessionInfo`: FOLDED as a patch. `session_info_update` says that omitted fields stay unchanged and `null` clears. A title-only update must not clear `updatedAt`.

## API shape

- `apply(_ update: SessionUpdate) -> Change`, where `Change` tells what changed: an entry was added (with its index), an entry changed (with its ID), or a state field changed. A client model uses it to change only the affected observable object.
- A way to seed from `NewSessionResponse` and `ResumeSessionResponse`.
- A way to read the transcript as `SessionUpdate` values again, for replay by an agent (ID-stable: a replayed message keeps its ID).

## Acceptance criteria

- Tests for each update kind, including the order of entries, the plan position, the `sessionInfo` patch fold, the `availableCommands` nil / `[]` difference, the unknown entry, and the tool-call `name` fold.
- A test that a replay of the transcript, applied to a new engine, gives the same state.
- DocC for the public API. `swift test` passes with no warnings.