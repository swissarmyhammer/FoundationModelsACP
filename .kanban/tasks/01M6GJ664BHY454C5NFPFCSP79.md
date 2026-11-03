---
depends_on:
- 01M6GJ8GX6C0YRHJW0W2ADAVTE
position_column: todo
position_ordinal: '80'
title: Add the unstable subagent_update, session_message and session_message_chunk session updates to the generated Swift types
---
## What
The ACP v2 "Subagent Sessions" RFD makes each sub-agent an ACP child session. FoundationModelsACPAgent (tag `subagents` on its board) cannot send, and FoundationModelsACPClient cannot read, these updates, because the Swift `SessionUpdate` union has no case for them.

Finding: the vendored unstable schema `Schema/acp-v2.unstable.json` already defines them: `SessionUpdate` variants `subagent_update` (line near 6075, `$ref SubagentUpdate`), `session_message` and `session_message_chunk` (lines near 6091 and 6107), and the types `SubagentUpdate` (line near 7713) and `SubagentSessionCapabilities` (line near 7677, with the `cancel` capability). The stable schema (`Schema/acp-v2.json`) has none of them. The generated Swift (`Sources/FoundationModelsACP/Generated/`, `Unions2.generated.swift` has `enum SessionUpdate`) has no `Subagent` type. The generator (`Sources/ACPGenerateCore/`) uses the unstable document only for the routing manifest and the `Unstable` method namespace; it does not emit unstable-only variants of a stable union.

Decide and do one of:
- (Recommended) Extend `ACPGenerateCore` (`SchemaGenerator.swift`, `Emitter.swift`) so that unstable-only variants of `SessionUpdate`, with their types, are emitted. Mark them unstable in the doc comments. Run `swift package generate-acp`.
- Or write the types by hand in `Sources/FoundationModelsACP/Session/` and keep the union closed. Say why in the task comment.

Rules from the RFD that the types must keep:
- `subagent_update`: only `update.sessionId` is required. Omitted field = unchanged; `null` clears; a value replaces the whole field. `capabilities` replace as a whole. In v2 a concrete `_meta` object patches by top-level key. Use the existing `PatchField` pattern of the package if it fits (the schema fields `title`, `description`, `capabilities`, `state`, `cwd`, `additionalDirectories` are nullable patches).
- `session_message`: required `messageId`; optional nullable `content`, `senderSessionId`, `recipientSessionId`, `senderMessageId`, `recipientMessageId`. `session_message_chunk` appends one content block to a `messageId`.
- The send rules (`Sources/FoundationModelsACP/Session/SessionUpdateSendRules.swift`): check that a child `sessionId` is never empty, and that `SessionUpdateRouter` (`Connection/SessionUpdateRouter.swift`) handles updates for a child session id that was announced by a parent (the client side must not drop them as unknown).

Consumers, for context: FoundationModelsACPAgent board tasks `1vmbam7` (announce), `nwsamy7` (session_message), `awnkj0k` (replay); FoundationModelsACPClient card `rt8h1fs` (observable model).

## Acceptance Criteria
- [ ] `SessionUpdate` has the cases for `subagent_update`, `session_message` and `session_message_chunk`, and decoding of the JSON examples in the RFD gives them.
- [ ] A value round-trips: encode then decode gives an equal value, with omitted, `null` and concrete patch fields kept apart.
- [ ] The unstable marking is in the doc comments of the new types.
- [ ] `SessionUpdateRouter` and the client side connection deliver an update with an announced child id (no drop).
- [ ] Regeneration is repeatable: `swift package generate-acp` gives no diff after the first run.

## Tests
- [ ] `Tests/FoundationModelsACPTests/SubagentUpdateCodingTests.swift`: decode, encode, round trip, patch semantics, unknown capability key kept.
- [ ] `Tests/FoundationModelsACPTests/SessionMessageCodingTests.swift`: message, chunk, participant ids.
- [ ] A generator test in the `ACPGenerateCore` tests that the unstable-only variants are emitted (if the generator is extended).
- [ ] Run `swift test`. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents