---
comments:
- actor: claude-code
  id: 01kyfgep6q8wxj99f5jhrwr79t
  text: |-
    Corrected against the vendored `Schema/acp-v2.json` (`schema-v2.0.0-alpha.2`, vendored in M0).

    Terminals: the card gated the terminal section on "PENDING M0 CONFIRMATION" and warned they might be absent. They are present and stable. `TerminalUpdate`, `TerminalOutputChunk`, and `Terminal` are all `$defs`, and `terminal_update` / `terminal_output_chunk` are `SessionUpdate` variants. All gating removed, and the two "(if terminals exist)" test caveats dropped.

    Placement fixed: `Terminal` -- *"a display-only reference to an agent-owned terminal"* -- is a variant of **`ToolCallContent`**, alongside `content` and `diff`. It is **not** a `ContentBlock` variant; `ContentBlock` is `text` / `image` / `audio` / `resource_link` / `resource`. That mismatch is exactly why an earlier reading of the content docs page concluded terminals were absent. Added an acceptance criterion and a test for the correct union.

    Variant list reconciled. `SessionUpdate.anyOf` has 17 members: 16 named variants plus an explicit unknown-discriminator fallback. The card described 13; it was missing `state_update`, `session_info_update`, and `usage_update`. All sixteen are now listed in schema order. `state_update`'s lifecycle semantics stay with M6 -- only its wire shape is owned here.

    Also corrected while in there, all verified against the schema:
    - `plan_update` carries a tagged `PlanUpdateContent`; `planId` and `entries` live on the `items` variant (`PlanItems`), not directly on `PlanUpdate`. The card put `planId` on the update.
    - The diff patch is an optional `patch` object with `format` / `text`; `git_patch` is the `DiffPatchFormat` value, not the field name. Added that `move` / `copy` carry `oldPath` as well as `path` (`DiffPathPairChange`).
    - Added the terminal patch semantics from `TerminalUpdate` (omitted unchanged / `null` clears / value replaces; new `terminalId` starts unknown) and the explicit note that the schema exposes no input, resize, interrupt, kill, wait, release, or execution surface.
    - Added the M1-seam note for `PlanUpdate.plan: JSONValue`, matching `plan.md` -> M7.
  timestamp: 2026-07-26T15:24:46.679190+00:00
- actor: claude-code
  id: 01kyfxv3g2f4gnmh6chdb50jhh
  text: |-
    The M1 seam is closed — the "blocked on the M1 seam" note is resolved. `PlanUpdate.plan` is now `PlanUpdateContent`, a tagged union with `items(PlanItems)` and an `unknown(String, JSONValue)` fallback that keeps `planId` when the content type is one this revision does not list.

    Two things landed for this milestone beyond that.

    **Every `session/update` variant's fallback now preserves payload, not just the deferred three.** `unknown(String)` became `unknown(String, JSONValue)` across the whole tagged-union emitter, so a `sessionUpdate` value a newer peer adds round-trips with its members intact rather than being truncated to its tag. `TaggedUnionRoundTripTests.everyDeclaredTagSelectsAModeledCase` probes all 44 discriminator values the vendored schema declares, across all 13 payload-bearing unions, reading the tags from `Schema/acp-v2.json` rather than restating them.

    **One conformance gap is deliberately left here, and it is this milestone's.** v2 gives upsert fields three wire states — omitted leaves the stored value unchanged, `null` clears it, a value replaces it — and every one of them generates as a Swift `Optional`, which has two. Omitted and `null` both decode to `nil` and both re-encode as an omitted key, so a client meaning "clear" sends "unchanged". It affects the six upsert types (`UserMessage`, `AgentMessage`, `AgentThought`, `SessionInfoUpdate`, `TerminalUpdate`, `ToolCallUpdate`) — their `_meta` says so explicitly, and their definition-level prose says the same of their other fields. Carded as ^1pfngj1 with the design constraints, and pinned in its current-behaviour form by `MetaFieldTests.upsertMetaCannotYetDistinguishOmittedFromNull`, so it fails loudly when fixed.
  timestamp: 2026-07-26T19:18:44.994678+00:00
depends_on:
- 01KYD58WWGMA9JWPT0B1PQPP65
position_column: todo
position_ordinal: '8780'
title: 'M7 Session updates: upserts, chunks, and display terminals'
---
## Starting point

**This is a rewrite** — see `plan.md` -> *Starting point*. The v1 `Connection/SessionUpdateRouter.swift` and `SessionUpdateStreamTests` were deleted. The router's **fan-out and straggler-tolerance** behaviour (per-session `AsyncStream`, updates for a session with no subscriber are dropped, late updates tolerated) is version-agnostic and worth recovering from git history.

The **update semantics are not.** v1 appended; v2 upserts. `tool_call` create is gone, three-state `content` semantics are new, and `messageId` is now required everywhere. Recover the plumbing, rewrite the semantics.

**Display terminals are confirmed real and stable** — M0 settled this against the vendored `Schema/acp-v2.json`. The earlier doubt (a truncated schema fetch, plus the content-page variant list) is resolved; build the terminal section as specified below.

## What

`plan.md` -> **M7**. `session/update` carries everything that happens in a session.

**The sixteen variants**, in schema order: `user_message_chunk`, `user_message`, `agent_message_chunk`, `agent_message`, `agent_thought_chunk`, `agent_thought`, `state_update`, `tool_call_content_chunk`, `tool_call_update`, `terminal_update`, `terminal_output_chunk`, `plan_update`, `available_commands_update`, `config_option_update`, `session_info_update`, `usage_update` — plus an explicit unknown-discriminator fallback (seventeen `anyOf` members in all). Every one is modeled and round-tripped here. `state_update`'s *lifecycle semantics* (`running` / `idle` with `stopReason` / `requires_action`) belong to **M6**; this card owns its wire shape like any other variant.

**Messages.** `user_message` / `agent_message` / `agent_thought` are **whole-message upserts** taking `content` arrays with three-state semantics: **omitted = unchanged, `null`/`[]` = cleared, concrete array = replaced.** The `*_chunk` variants **append**. Every chunk and update carries a required, agent-generated **`messageId`**.

**Tool calls.** `tool_call` create is **removed**; `tool_call_update` is an upsert that both creates and patches -- the first update with a new `toolCallId` creates it. Only `toolCallId` is required, though agents should include `title` on first report. `tool_call_content_chunk` appends individual content items; an update carrying `content` **replaces** accumulated content, and later chunks append to that replacement. `status` gains **`cancelled`** and becomes **extensible**.

**Display terminals.** Agents own them; clients only render:
- the terminal reference is a variant of **`ToolCallContent`** -- `{"type": "terminal", "terminalId": …}`, alongside `content` and `diff`. It is **not** a `ContentBlock` variant: `ContentBlock` is `text` / `image` / `audio` / `resource_link` / `resource`, and that is why the content docs page shows no terminal. Model it in the right union.
- `terminal_update` upserts keyed by `terminalId`, patching `command`, absolute `cwd`, an output snapshot, and `exitStatus`. Patch semantics as elsewhere: omitted leaves the stored value unchanged, `null` clears, a value replaces; on a new `terminalId` omitted fields start unknown.
- `terminal_output_chunk` appends **base64-encoded bytes** (RFC 4648) in `data`
- output is an **authoritative replacement snapshot** for replay, correction, or resynchronization
- the schema carries **no** input, resize, interrupt, kill, wait, release, or execution surface — display only. `TerminalId` also appears on `CommandPermissionSubject` as *"the associated terminal, when already known."*

**Plans.** `plan` becomes `plan_update` carrying a tagged `PlanUpdateContent`; its one known variant, `type: "items"`, holds the required `planId` and the `entries` list. Each update replaces that plan's entries. Entry `status` gains `cancelled` and is extensible.

**Diffs.** A `changes` array of operations (`add`, `delete`, `modify`, `move`, `copy`) with absolute `path` — `move` and `copy` also carrying `oldPath` — plus optional `fileType` and `mimeType`, replacing v1's single `path` + `oldText`/`newText`; plus an optional renderable `patch` (`format` / `text`, where `git_patch` is the only ACP-defined format).

Also: `config_option_update`, `session_info_update`, `usage_update`, and slash-command availability (`available_commands_update`) with a required `type: "text"` discriminator on command `input`.

*Blocked on the M1 seam:* `PlanUpdate.plan` is `JSONValue` — required, so every `plan_update` carries an untyped payload — until `PlanUpdateContent` resolves.

## Acceptance Criteria

- [ ] Every one of the sixteen `session/update` variants is modeled and round-trips, and the unknown-discriminator fallback preserves what it received.
- [ ] Three-state `content` semantics implemented exactly (omitted / cleared / replaced).
- [ ] `tool_call_update` creates on first sight of a `toolCallId` and patches thereafter.
- [ ] `tool_call_content_chunk` appends; a `content` field replaces, and later chunks append to the replacement.
- [ ] The terminal reference is modeled as a `ToolCallContent` variant, not a `ContentBlock` variant.
- [ ] Terminal upserts and base64 output chunks handled.
- [ ] `plan_update` replaces entries per `planId`.
- [ ] Extensible `status` enums preserve unknown values.
- [ ] Per-session update stream with straggler tolerance restored.

## Tests

- [ ] Omitted vs `null` vs `[]` vs array each produce the specified result -- four distinct assertions, since silently conflating them corrupts history.
- [ ] First `tool_call_update` creates; second patches; neither duplicates.
- [ ] Content replace-then-append ordering matches spec.
- [ ] Base64 terminal output decodes to exact bytes, including non-UTF8.
- [ ] A terminal snapshot replaces prior accumulated output.
- [ ] A `terminal` `ToolCallContent` round-trips; a `terminal` payload offered where a `ContentBlock` is expected does **not** decode as a known variant.
- [ ] Unknown `status` and unknown update variants survive a round trip.
- [ ] Updates for a session with no subscriber are dropped without error.
