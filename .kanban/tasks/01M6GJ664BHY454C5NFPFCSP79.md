---
depends_on:
- 01M6GJ8GX6C0YRHJW0W2ADAVTE
position_column: todo
position_ordinal: '80'
title: Add the unstable subagent_update, session_message and session_message_chunk session updates to the generated Swift types
---
## What
The ACP v2 "Subagent Sessions" RFD makes each sub-agent an ACP child session. FoundationModelsACPAgent (tag `subagents` on its board) cannot send, and FoundationModelsACPClient cannot read, these updates, because the Swift `SessionUpdate` union has no case for them.

Facts (checked against the vendored schema-v2.0.0-alpha.13, not alpha.8):
- The stable schema (`Schema/acp-v2.json`) has none of them. The unstable schema (`Schema/acp-v2.unstable.json`) defines them: `SessionUpdate` variants `subagent_update` (`SubagentUpdate`), `session_message` (`SessionMessage`) and `session_message_chunk` (`SessionMessageChunk`). Supporting types: `SubagentSessionCapabilities` (field `cancel`, type `SessionCancelCapabilities`) and `BackgroundSubagent`.
- The stable `BackgroundWork` has only `terminal` and `tool_call`. The unstable `BackgroundWork` adds the entry `{type: subagent, sessionId}` (`BackgroundSubagent`). The agent needs it to list running children in the `background` list of `state_update`. This card gives it too.
- No client capability is needed for subagents. `ClientCapabilities` has only `auth`, `elicitation` and `_meta`. The `SubagentUpdate` description says: "Understanding this update, registering child sessions, and applying their operation restrictions are baseline v2 requirements. No Client capability is required." Per-child permissions come in `SubagentUpdate.capabilities`.
- The generator uses the unstable document only for the routing manifest and the `Unstable` method namespace; it does not emit unstable-only variants of a stable union.

Do: extend `ACPGenerateCore` with an explicit overlay (`GeneratorConfig.unstableOverlay`). The overlay names (a) definitions to copy from the unstable document, and (b) union variants, by discriminator value, to append to a stable union. Do NOT make the other unstable parts (plan_removed, providers, archive and so on) emit. Mark the new types unstable in the doc comments (they keep the schema text). Run `swift package generate-acp`.

Rules from the schema that the types must keep:
- `subagent_update`: only `sessionId` is required. Omitted field = unchanged; `null` clears; a value replaces the whole field. `capabilities` replace as a whole. A concrete `_meta` object patches by top-level key. Use `PatchField` for `title`, `description`, `capabilities`, `state`, `cwd`, `additionalDirectories`, `_meta`.
- `session_message`: required `messageId`; `content`, `senderSessionId`, `recipientSessionId`, `senderMessageId`, `recipientMessageId` and `_meta` are patch fields. `session_message_chunk` appends one content block to a `messageId` and carries no participants.
- `SessionMergeEngine` keeps the retained history for replay. It must handle the three new cases, or they are dropped from the replay: a `subagent_update` upserts the child record; a `session_message` upserts the message; a `session_message_chunk` appends to the message.
- The send rules (`Sources/FoundationModelsACP/Session/SessionUpdateSendRules.swift`): a child `sessionId` is never empty. `SessionUpdateRouter` (`Connection/SessionUpdateRouter.swift`) delivers updates for a child session id that a parent announced (the client side must not drop them as unknown).

Consumers, for context: FoundationModelsACPAgent board tasks `1vmbam7` (announce), `nwsamy7` (session_message), `awnkj0k` (replay); FoundationModelsACPClient card `rt8h1fs` (observable model). The SAH meta card `01M6GP1QC785QS2BS3TNVMKT7A` follows this card and is not part of it.

## Acceptance Criteria
- [ ] `SessionUpdate` has the cases `subagentUpdate`, `sessionMessage`, `sessionMessageChunk`; `BackgroundWork` has the case `subagent`. Decoding gives them.
- [ ] A value round-trips, with omitted, `null` and concrete patch fields kept apart.
- [ ] The unstable marking is in the doc comments of the new types.
- [ ] `SessionMergeEngine` replays the three new updates.
- [ ] `SessionUpdateRouter` and the client side connection deliver an update with an announced child id (no drop).
- [ ] Regeneration is repeatable: `swift package generate-acp` gives no diff after the first run.

## Tests
- [ ] `Tests/FoundationModelsACPTests/SubagentUpdateCodingTests.swift`: decode, encode, round trip, patch semantics, unknown capability key kept.
- [ ] `Tests/FoundationModelsACPTests/SessionMessageCodingTests.swift`: message, chunk, participant ids.
- [ ] Tests for `BackgroundWork.subagent` and for the merge engine replay.
- [ ] A generator test that the overlay emits the unstable-only variants.
- [ ] Run `swift test`. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents