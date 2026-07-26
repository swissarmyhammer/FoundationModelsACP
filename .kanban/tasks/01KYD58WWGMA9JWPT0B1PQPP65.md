---
depends_on:
- 01KYD58WV07Q982G94JHT1SH5G
position_column: todo
position_ordinal: '8680'
title: 'M6 Prompt lifecycle: acknowledge, then report state'
---
## Starting point

**This is a rewrite** — see `plan.md` -> *Starting point*. Of all the milestones, this one has the **least** to salvage: the v1 prompt lifecycle is not a v2 prompt lifecycle with different types, it is a different design. The deleted v1 code held `session/prompt` open for an entire turn and resolved it with a `stopReason`; v2 acknowledges immediately and reports everything through `state_update`. Do not consult the v1 turn code for structure — it will actively mislead you. Its cancellation plumbing is the only part with any carryover.

## What

`plan.md` -> **M6**. The change with the largest blast radius for our agent.

**v1:** `session/prompt` stayed pending for the whole turn and resolved with `stopReason`.
**v2:** it returns **`{}` immediately** to acknowledge acceptance. *"The `session/prompt` response no longer ends the turn. It acknowledges acceptance. Foreground progress and completion arrive as `state_update` notifications, and the stop reason moved there too."*

`state_update` carries three states:

- **`running`** -- foreground work in progress.
- **`idle`** -- ready for the next prompt; carries **`stopReason`** when transitioning from working.
- **`requires_action`** -- foreground work **blocked waiting on the user**. This is a protocol-level state for exactly the permission / elicitation pause, which previously had no representation at all.

Also required: after accepting a prompt the agent must emit a `user_message` or streamed `user_message_chunk` updates carrying an **agent-generated `messageId`** -- the agent owns history, so it owns message identity.

**Cancellation:** `session/cancel` stays a notification, but confirmation now arrives as an `idle` `state_update` with `stopReason: "cancelled"` rather than in the prompt response.

## Acceptance Criteria

- [ ] `session/prompt` returns `{}` immediately, before any work completes.
- [ ] `state_update` emits `running`, `idle` (with `stopReason`), and `requires_action`.
- [ ] Accepting a prompt emits a `user_message` / chunks with an agent-generated `messageId`.
- [ ] `session/cancel` results in an idle state with `stopReason: "cancelled"`.
- [ ] `stopReason` values round-trip, unknown ones preserved.

## Tests

- [ ] The prompt response arrives before the first `state_update` -- assert ordering, since this is the entire semantic change.
- [ ] A full turn produces running -> idle with a `stopReason`.
- [ ] A blocked turn reports `requires_action`, then resumes to `running` once answered.
- [ ] Cancel mid-turn yields idle + `cancelled`.
- [ ] The acknowledged prompt's `messageId` is present and stable across its chunks.
