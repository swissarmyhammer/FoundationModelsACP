---
depends_on:
- 01KYD58WWGMA9JWPT0B1PQPP65
position_column: todo
position_ordinal: '8780'
title: 'M7 Session updates: upserts, chunks, and display terminals'
---
## Starting point

**This is a rewrite** — see `plan.md` -> *Starting point*. The v1 `Connection/SessionUpdateRouter.swift` and `SessionUpdateStreamTests` were deleted. The router's **fan-out and straggler-tolerance** behaviour (per-session `AsyncStream`, updates for a session with no subscriber are dropped, late updates tolerated) is version-agnostic and worth recovering from git history.

The **update semantics are not.** v1 appended; v2 upserts. `tool_call` create is gone, three-state `content` semantics are new, and `messageId` is now required everywhere. Recover the plumbing, rewrite the semantics.

**Blocked on an M0 answer:** display terminals may not exist in the v2 schema at all. The migration guide describes `terminal_update` / `terminal_output_chunk` / a `terminal` content variant, but the v2 schema and content-block list do not show them. Do not build the terminal section of this task until M0 confirms. If it turns out absent, drop those bullets rather than inventing the shape.

## What

`plan.md` -> **M7**. `session/update` carries everything that happens in a session.

**Messages.** `user_message` / `agent_message` / `agent_thought` are **whole-message upserts** taking `content` arrays with three-state semantics: **omitted = unchanged, `null`/`[]` = cleared, concrete array = replaced.** The `*_chunk` variants **append**. Every chunk and update carries a required, agent-generated **`messageId`**.

**Tool calls.** `tool_call` create is **removed**; `tool_call_update` is an upsert that both creates and patches -- the first update with a new `toolCallId` creates it. Only `toolCallId` is required, though agents should include `title` on first report. `tool_call_content_chunk` appends individual content items; an update carrying `content` **replaces** accumulated content, and later chunks append to that replacement. `status` gains **`cancelled`** and becomes **extensible**.

**Display terminals (new, PENDING M0 CONFIRMATION).** Agents own them; clients only render:
- content reference `{"type": "terminal", "terminalId": …}`
- `terminal_update` upserts keyed by `terminalId`, patching `command`, absolute `cwd`, an output snapshot, and `exitStatus`
- `terminal_output_chunk` appends **base64-encoded bytes** (RFC 4648)
- output is an **authoritative replacement snapshot** for replay, correction, or resynchronization

**Plans.** `plan` becomes `plan_update` with required `planId` and a tagged `type: "items"`; each update replaces that plan's entries. `status` gains `cancelled` and is extensible.

**Diffs.** A `changes` array of operations (`add`, `delete`, `modify`, `move`, `copy`) with `path`, optional `fileType` and `mimeType`, replacing v1's single `path` + `oldText`/`newText`; plus an optional renderable `git_patch`.

Also: `config_option_update`, and slash-command availability with a required `type: "text"` discriminator on command `input`.

## Acceptance Criteria

- [ ] Every `session/update` variant is modeled and round-trips.
- [ ] Three-state `content` semantics implemented exactly (omitted / cleared / replaced).
- [ ] `tool_call_update` creates on first sight of a `toolCallId` and patches thereafter.
- [ ] `tool_call_content_chunk` appends; a `content` field replaces, and later chunks append to the replacement.
- [ ] Terminal upserts and base64 output chunks handled, **or** recorded as not present in v2.
- [ ] `plan_update` replaces entries per `planId`.
- [ ] Extensible `status` enums preserve unknown values.
- [ ] Per-session update stream with straggler tolerance restored.

## Tests

- [ ] Omitted vs `null` vs `[]` vs array each produce the specified result -- four distinct assertions, since silently conflating them corrupts history.
- [ ] First `tool_call_update` creates; second patches; neither duplicates.
- [ ] Content replace-then-append ordering matches spec.
- [ ] Base64 terminal output decodes to exact bytes, including non-UTF8 (if terminals exist).
- [ ] A terminal snapshot replaces prior accumulated output (if terminals exist).
- [ ] Unknown `status` and unknown update variants survive a round trip.
- [ ] Updates for a session with no subscriber are dropped without error.
