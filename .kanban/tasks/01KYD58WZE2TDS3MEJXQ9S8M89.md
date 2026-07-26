---
comments:
- actor: claude-code
  id: 01kyfgctmyecth8n6gtjahat7m
  text: |-
    Rescoped against the vendored `Schema/acp-v2.json` + `acp-v2.meta.json` / `acp-v2.meta.unstable.json` (`schema-v2.0.0-alpha.2`, vendored in M0).

    The card asserted "**Elicitation is stable in v2** (it was unstable in v1)". That is backwards. `elicitation/create` and `elicitation/complete` appear only in `acp-v2.meta.unstable.json`; the stable `clientMethods` manifest has exactly two entries, `session/request_permission` and `session/update`. There are no stable elicitation request/response types in the schema to generate against.

    What changed:
    - Title: "M8 Permissions and elicitation" -> "M8 Permissions (elicitation deferred to a re-vendor)", matching `plan.md` -> M8.
    - Card rescoped to `session/request_permission` only. Its `title` / `description` / tagged `subject` detail is unchanged -- it was correct.
    - The whole elicitation section moved under a *Deferred* heading, explicitly blocked on a re-vendor that promotes elicitation to stable, and flagged for re-verification at that point since the shape is still moving upstream. Kept verbatim rather than deleted: it is the scope of the follow-on card.
    - Elicitation acceptance criteria and tests demoted from checkboxes to deferred prose, so they no longer gate this card. The `action` = accept/decline/cancel test went with them -- that is `ElicitationAction`, not the permission outcome.
    - Added permission-side coverage the card was missing: optional/omitted `subject`, the unknown-`subject`-tag fallback, and a `command` subject carrying `toolCallId` / `terminalId`.
    - Added an acceptance check that nothing is implemented or stubbed against the unstable manifest.
    - Starting-point line "Elicitation is genuinely new work: it was unstable in v1 and this package never implemented it" removed as misleading in context -- it is still unstable in the vendored v2.
    - Also corrected: this is now the *only* long-lived stable Client request, since `session/prompt` acknowledges immediately.
  timestamp: 2026-07-26T15:23:45.694507+00:00
depends_on:
- 01KYD58WXZM3KYPQ12K4VNPRPG
position_column: todo
position_ordinal: '8880'
title: M8 Permissions (elicitation deferred to a re-vendor)
---
## Starting point

**This is a rewrite** — see `plan.md` -> *Starting point*. v1 had `requestPermission` on the deleted `Client` protocol; the request shape is restructured in v2 (`title` / `description` / tagged `subject`), so the old signature is of limited use.

The one thing worth recovering from git history is how the v1 connection handled a long-lived reverse request without blocking the read loop — that constraint is unchanged and is the reason M3 comes first.

**Scope note:** this card is `session/request_permission` **only**. Elicitation was scoped in here on the assumption it had become stable in v2; it has not. See *Deferred* below.

## What

`plan.md` -> **M8**. The one stable Client request that waits on a human.

**`session/request_permission`** is restructured in v2 to separate prompt copy from context:
- required **`title`** -- the human-readable prompt text
- optional **`description`** -- supporting copy
- optional **`subject`**, a tagged union:
  - `tool_call` -- payload is a `ToolCallUpdate` upsert shape
  - `command` -- self-contained: required `command`, required **absolute** `cwd`, optional `toolCallId` / `terminalId`
- `options` and the response shape are unchanged from v1

It is a long-lived request that must never block the connection read loop (M3). In the stable surface it is the **only** such request, now that `session/prompt` acknowledges immediately.

## Deferred: elicitation (out of scope for this card, kept as reference)

**Elicitation is unstable-only in the vendored `schema-v2.0.0-alpha.2`, not stable.** `elicitation/create` and `elicitation/complete` appear in `acp-v2.meta.unstable.json` and in neither the stable manifest nor the stable schema, so there are no request/response types to generate against. Upstream `main` has already promoted them, so expect them stable on the next re-vendor.

**Blocked on a re-vendor that promotes elicitation to stable.** Do not implement any of the following until then; when it lands, this section is the scope of the follow-on work, and it should become its own card rather than reopening this one.

Reference material, still believed accurate and worth keeping — **re-verify against the schema at the time it is vendored, since it is moving**:

- `elicitation/create` is a Client method, `elicitation/complete` a Client notification reporting that a URL-mode interaction finished.
- `mode`: `form` or `url`, required.
- Scope, exactly one: `sessionId` (optionally with `toolCallId`) or `requestId` for interactions outside a session.
- Form mode: `requestedSchema`, a flat JSON Schema of primitives/enums. **MUST NOT** request secrets, credentials, passwords, API keys, tokens, private keys, or payment data.
- URL mode: HTTPS `url` + `elicitationId`. Credentials **MUST NOT** come back over ACP; the client **MUST** display the target host and obtain consent before navigating; no prefetching. The agent **MUST** verify the authenticated user identity matches between initiation and completion.
- Response: `action` = `accept` | `decline` | `cancel`, with optional `content` (conforming to `requestedSchema` on form accept; typically omitted for URL).
- Capability-gated; requesting an unsupported mode is **`-32602`**.
- Like `session/request_permission`, `elicitation/create` is long-lived and must not block the read loop.

Deferred acceptance/tests, for the follow-on card: elicitation form and URL modes round-trip including scope alternatives; capability gating with `-32602` on an unsupported mode; `elicitation/complete` correlates by `elicitationId`; the security obligations documented on the API where an implementer will actually see them; scope variants (`sessionId`, `sessionId` + `toolCallId`, `requestId`) round-trip and neither-present is rejected; all three `action` values decode with an unknown action degrading via the fallback.

## Acceptance Criteria

- [ ] Permission requests model `title` / `description` / tagged `subject` with both variants.
- [ ] `command` subject requires an absolute `cwd`, enforced at decode time.
- [ ] `subject` is optional, and an omitted `subject` round-trips.
- [ ] The unknown-`subject`-tag fallback preserves what it received.
- [ ] Nothing elicitation-related is implemented or stubbed against the unstable manifest.

## Tests

- [ ] Both `subject` variants round-trip; a relative `cwd` in a `command` subject fails decoding.
- [ ] A `command` subject carrying `toolCallId` and `terminalId` round-trips.
- [ ] A pending permission request does not block concurrent notifications on the same connection.
