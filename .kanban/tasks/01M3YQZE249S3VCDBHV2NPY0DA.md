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
- actor: claude-code
  id: 01m3ywmk5a9d4xjdq29vtefs23
  text: |-
    Research done. Findings:
    - No ARCHITECTURE.md. Engine goes in Sources/FoundationModelsACP/Session/ beside the aggregator.
    - Six generated structs have PatchField fields: UserMessage, AgentMessage, AgentThought, ToolCallUpdate, TerminalUpdate, SessionInfoUpdate. `PatchField.folded(onto:)` is internal.
    - Plan for the "fold cannot miss a new field" requirement: the generator (Emitter.structDeclaration) emits `public func folded(onto existing: Self) -> Self` on each struct with a patch field. Patch fields fold, other fields take the new value. VendoredSchemaTests compares the checked-in output, so the Generated files must be regenerated (delete Generated/.schema-hash, then `swift package generate-acp`).
    - Other users of SessionUpdateAggregator: OutOfOrderConvergenceTests and GoldenSessionEndToEndTests. After deprecation they give warnings, so they move to the new engine. SessionUpdateAggregatorTests stays and is marked deprecated so that it does not warn.
    - AccumulatedTerminal is reused by the engine for terminal entries. The shared terminal and tool-call chunk logic moves to internal helpers so that the aggregator and the engine do not copy code.
  timestamp: 2026-10-02T18:04:48.682884+00:00
- actor: claude-code
  id: 01m3yx96eb14rqv69x4ckjzzjz
  text: |-
    Implementation landed (not committed).

    Public API added:
    - `public struct SessionMergeEngine: Hashable, Sendable` with `entries: [SessionEntry]`, `availableCommands: [AvailableCommand]?`, `configOptions: [SessionConfigOption]?`, `usage: UsageUpdate?`, `agentState: StateUpdate?`, `sessionInfo: SessionInfoUpdate` (all `public private(set)`), `init()`, `@discardableResult mutating func apply(_: SessionUpdate) -> Change`, `@discardableResult mutating func seed(from: NewSessionResponse) -> [Change]`, `@discardableResult mutating func seed(from: ResumeSessionResponse) -> [Change]`, `mutating func reset()`, `func entry(withID: SessionEntry.ID) -> SessionEntry?`, `var transcriptUpdates: [SessionUpdate]`, `var stateUpdates: [SessionUpdate]`.
    - `SessionMergeEngine.Change`: `entryAdded(index:entry:)`, `entryChanged(index:entry:)`, `availableCommandsChanged([AvailableCommand])`, `configOptionsChanged([SessionConfigOption])`, `usageChanged(UsageUpdate)`, `agentStateChanged(StateUpdate)`, `sessionInfoChanged(SessionInfoUpdate)`.
    - `public struct SessionEntry: Hashable, Sendable, Identifiable` with `id: ID`, `kind: Kind`; `SessionEntry.ID` (userMessage/agentMessage/agentThought(MessageId), toolCall(ToolCallId), terminal(TerminalId), plan(PlanId), unidentified(position: Int)); `SessionEntry.Kind` (userMessage/agentMessage/agentThought(Message), toolCall(ToolCallUpdate), terminal(TerminalId, AccumulatedTerminal), plan(PlanUpdate), unknown(type:payload:)); `SessionEntry.Message` (messageId, content: [ContentBlock], meta: PatchField<JSONValue>).
    - Generator: each struct with a patch field gets `public func folded(onto existing: Self) -> Self` (ToolCallUpdate, TerminalUpdate, SessionInfoUpdate, UserMessage, AgentMessage, AgentThought). Regenerated.

    Decisions to note:
    - A chunk `_meta` (plain optional) replaces the entry `_meta` when present; absent keeps it.
    - A plan update with unknown content keys by a `planId` string in its payload; with none, it becomes a new `.unidentified` plan entry. It is never dropped.
    - configOptions seed: any present list sets it (also `[]`); only availableCommands treats omitted/empty as "leave nil".
    - `AccumulatedTerminal` moved to its own file (public API same) so that the removal task can delete the aggregator file only.
    - Swift Testing rejects `@available(*, deprecated)` on a `@Suite`. `SessionUpdateAggregatorTests` uses `@diagnose(DeprecatedDeclaration, as: ignored)` instead (Swift 6.4). OutOfOrderConvergenceTests and GoldenSessionEndToEndTests moved to the engine.
    - VendoredSchemaTests shard-count pins changed (Models 15->14, Models3 14->15) because the fold methods move shard boundaries.
  timestamp: 2026-10-02T18:16:03.787810+00:00
- actor: claude-code
  id: 01m3yx9a0k4y2gdvp2ngsgzqsk
  text: |-
    ### implement — changed
    - evidence: `swift test` 349 + 110 tests pass, 0 warnings (rebuild of all touched files); `swift package generate-documentation --target FoundationModelsACP --warnings-as-errors` exit 0. 17 files: Sources/ACPGenerateCore/Emitter.swift, Sources/FoundationModelsACP/Core/PatchField.swift, Sources/FoundationModelsACP/Generated/Models{,2,3,7,8,9}.generated.swift, Sources/FoundationModelsACP/Session/{SessionMergeEngine,SessionEntry,AccumulatedTerminal,SessionUpdateAggregator}.swift, Tests/ACPGenerateTests/{PatchSemanticsTests,VendoredSchemaTests}.swift, Tests/FoundationModelsACPTests/{SessionMergeEngineTests,SessionUpdateAggregatorTests,OutOfOrderConvergenceTests,GoldenSessionEndToEndTests}.swift
    - next: /review
  timestamp: 2026-10-02T18:16:07.443735+00:00
depends_on:
- 01M3YQYR2Y867FQBAZJG2MKX79
position_column: doing
position_ordinal: '80'
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