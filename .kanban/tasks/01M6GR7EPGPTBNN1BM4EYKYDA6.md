---
assignees:
- claude-code
position_column: todo
position_ordinal: '8480'
title: Merge _meta by top-level key in SessionMergeEngine (alpha.9 rule)
---
## What
Since schema-v2.0.0-alpha.9 a concrete `_meta` object in an upsert patches the stored `_meta` by top-level key: an omitted key is unchanged, a key set to `null` is removed, any other value replaces that key without merging nested objects. `null` clears all; omitted leaves it. `SessionMergeEngine` and the generated `folded(onto:)` still replace the whole `_meta` object (`PatchField.folded(onto:)`). This applies to `UserMessage`, `AgentMessage`, `AgentThought`, `ToolCallUpdate`, `TerminalUpdate`, `CompactionUpdate`, `SessionInfoUpdate`, `SubagentUpdate`, `SessionMessage`. The re-vendor card (2adavte) did not cover this.

Decide where the rule lives (a `PatchField<JSONValue>` fold for `_meta`, used by the generator for every `_meta` patch field), then change all callers at once (no backward compatibility, see `ARCHITECTURE.md`).

## Acceptance Criteria
- [ ] Every `_meta` patch field folds by top-level key.
- [ ] Replay of a folded entry gives the same `_meta`.

## Tests
- [ ] Add tests: omitted key kept, new key added, `null` key removed, nested object replaced whole, `null` clears all.
- [ ] Run `swift test`. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents