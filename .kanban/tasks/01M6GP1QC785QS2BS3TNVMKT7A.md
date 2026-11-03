---
position_column: todo
position_ordinal: '8280'
title: SAH meta payload that links an agent tool call and its child session
---
## What
An agent run is a session AND a tool (user, 2026-11-03). On the wire it has two faces: a `tool_call` in the parent (the `agents` call) and a child session announced by `subagent_update`. ACP does not link them: `SubagentUpdate` has `sessionId`, `title`, `description`, `capabilities`, `state`, `cwd`, `additionalDirectories` and `_meta`, but no tool call id. The client needs the link to open the child from the tool row, and to remove a finished child when its tool call completes (ACP has no removal message, and a finished agent session is ended and removed).

Add one SAH extension payload type to `Sources/FoundationModelsACP/SAH/SAHMeta.swift`, in the pattern of `SAH.SessionMessage` (`_meta.sah.message`) and `SAH.RuleDenial`:
- `SAH.AgentRun`, stored under `_meta.sah.agentRun`, with two optional members: `toolCallId` (on a `subagent_update`: the id of the `agents` tool call that started the child) and `sessionId` (on a `tool_call` or `tool_call_update`: the id of the child session).
- `extract(from:)` and `inject(into:)` helpers like the other payloads, and tests that an unknown member is kept and a missing payload gives `nil`.
- Document the rule in the doc comment: the agent sends the final `tool_call_update` AFTER the last update of the child; a client removes a child when its linked tool call is final; a peer that ignores `_meta.sah` sees a normal ACP child.
- Name check: `SAH.SessionMessage` already exists under `_meta.sah.message` and is a different thing from the ACP `session_message` update. Keep the names distinct in docs.
- Bump `SAH.version` only if the policy of that file says a new payload needs it.

Depends on: the re-vendor card (`01M6GJ8GX6C0YRHJW0W2ADAVTE`) and the wire types card (`01M6GJ664BHY454C5NFPFCSP79`), because this payload rides on `subagent_update`. Consumers: FoundationModelsACPAgent (announce and projection tasks), FoundationModelsACPClient card, AgentViewKit card.

## Acceptance Criteria
- [ ] `SAH.AgentRun` encodes under `_meta.sah.agentRun` and decodes back; both members optional.
- [ ] `inject` keeps other `_meta.sah` members and other `_meta` keys.
- [ ] `extract` gives `nil` when there is no payload or when it is malformed, and does not throw.
- [ ] The doc comment states the removal rule and the ordering rule.

## Tests
- [ ] `Tests/FoundationModelsACPTests/SAHAgentRunMetaTests.swift`: round trip on `subagent_update` and on `tool_call`, keep other keys, missing and malformed payload.
- [ ] Run `swift test --filter SAHAgentRunMetaTests`. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents