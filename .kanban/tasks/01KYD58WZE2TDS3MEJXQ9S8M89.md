---
depends_on:
- 01KYD58WXZM3KYPQ12K4VNPRPG
position_column: todo
position_ordinal: '8880'
title: M8 Permissions and elicitation
---
## Starting point

**This is a rewrite** — see `plan.md` -> *Starting point*. v1 had `requestPermission` on the deleted `Client` protocol; the request shape is restructured in v2 (`title` / `description` / tagged `subject`), so the old signature is of limited use. Elicitation is genuinely new work: it was **unstable** in v1 and this package never implemented it.

The one thing worth recovering from git history is how the v1 connection handled a long-lived reverse request without blocking the read loop — that constraint is unchanged and is the reason M3 comes first.

## What

`plan.md` -> **M8**. The two Client methods that wait on a human.

**`session/request_permission`** is restructured in v2 to separate prompt copy from context:
- required **`title`** -- the human-readable prompt text
- optional **`description`** -- supporting copy
- optional **`subject`**, a tagged union:
  - `tool_call` -- payload is a `ToolCallUpdate` upsert shape
  - `command` -- self-contained: required `command`, required **absolute** `cwd`, optional `toolCallId` / `terminalId`
- `options` and the response shape are unchanged from v1

**Elicitation is stable in v2** (it was unstable in v1): `elicitation/create` is a Client method, `elicitation/complete` a Client notification reporting that a URL-mode interaction finished.

- `mode`: `form` or `url`, required.
- **Scope, exactly one:** `sessionId` (optionally with `toolCallId`) or `requestId` for interactions outside a session.
- Form mode: `requestedSchema`, a flat JSON Schema of primitives/enums. **MUST NOT** request secrets, credentials, passwords, API keys, tokens, private keys, or payment data.
- URL mode: HTTPS `url` + `elicitationId`. Credentials **MUST NOT** come back over ACP; the client **MUST** display the target host and obtain consent before navigating; no prefetching. The agent **MUST** verify the authenticated user identity matches between initiation and completion.
- Response: `action` = `accept` | `decline` | `cancel`, with optional `content` (conforming to `requestedSchema` on form accept; typically omitted for URL).
- Capability-gated; requesting an unsupported mode is **`-32602`**.

Both are long-lived requests that must never block the connection read loop (M3).

## Acceptance Criteria

- [ ] Permission requests model `title` / `description` / tagged `subject` with both variants.
- [ ] `command` subject requires an absolute `cwd`, enforced at decode time.
- [ ] Elicitation form and URL modes round-trip, including scope alternatives.
- [ ] Capability gating implemented; unsupported mode yields `-32602`.
- [ ] `elicitation/complete` correlates by `elicitationId`.
- [ ] The security obligations are documented on the API where an implementer will actually see them.

## Tests

- [ ] Both `subject` variants round-trip; a relative `cwd` in a `command` subject fails decoding.
- [ ] All three `action` values decode; an unknown action degrades via the fallback.
- [ ] Scope: `sessionId`, `sessionId` + `toolCallId`, and `requestId` all round-trip; neither-present is rejected.
- [ ] An unsupported-mode request produces `-32602`.
- [ ] A pending permission request does not block concurrent notifications on the same connection.
