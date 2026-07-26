---
depends_on:
- 01KYD58WR23B5R69691FKDWJSG
position_column: todo
position_ordinal: '8480'
title: M4 Initialization and capability negotiation
---
## Starting point

**This is a rewrite** — see `plan.md` -> *Starting point*. v1 `initialize` handling, `ProtocolVersionTests`, and `Core/ProtocolVersion.swift` were deleted; M1 restores `ProtocolVersion`. The v1 negotiation code is in git history, but the initialize payload shape changed substantially in v2 (see below), so treat it as reference only, not a port.

## What

`plan.md` -> **M4**.

v2 restructures initialize and both roles now use **identical field names**:

- Required **`info`** object (v1 had optional, role-specific `clientInfo` / `agentInfo`).
- Required **`capabilities`** object (v1 had role-specific `clientCapabilities` / `agentCapabilities`).
- **Support markers are empty objects `{}`**, not booleans. Omitted or `null` means unsupported.
- Prompt and MCP capabilities **nest under `capabilities.session`** -- including `session.mcp.stdio`, `session.mcp.http`, and `session.additionalDirectories`.
- `loadSession` is gone, as are individual `list` / `resume` / `close` markers (baseline when `session` is advertised).
- `clientCapabilities.fs` and `.terminal` are **entirely removed**.

Send `"protocolVersion": 2`. A peer that answers with a lower version is one we **cannot serve** -- we are v2-only by decision -- so that must fail with a clear, actionable error naming the version mismatch, not a vague handshake failure. This is the single most likely real-world friction point of the v2-only decision, so make the diagnostic good.

## Acceptance Criteria

- [ ] `initialize` round-trips required `info` and `capabilities`.
- [ ] Empty-object markers distinguish supported / unsupported / absent correctly.
- [ ] Nested `capabilities.session.*` modeled, including both MCP transports and `additionalDirectories`.
- [ ] `protocolVersion: 2` sent and asserted.
- [ ] A non-2 peer produces a clear version-mismatch error naming both versions.

## Tests

- [ ] Full initialize exchange over `InMemoryTransport`.
- [ ] `{}` vs `null` vs omitted each map to the right support state.
- [ ] A peer replying `protocolVersion: 1` yields the version-mismatch error, and the message names v1 and v2 explicitly.
- [ ] Capability round-trip preserves unknown nested keys.
