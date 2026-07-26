---
depends_on:
- 01KYD58WN4KFHR3TP9HQZHT036
position_column: todo
position_ordinal: '8280'
title: 'M2 Role protocols: nine agent methods, four client entry points'
---
## Starting point

**This is a rewrite.** `plan.md` -> *Starting point* has the full inventory.

The v1 `Agent` and `Client` protocols were deleted (`Connection/Agent.swift`, `Connection/Client.swift`). Consult them in git history — the shape is a useful reference — but understand the delta is large, and mostly **subtraction**:

- **Off `Client`:** `readTextFile`, `writeTextFile`, `createTerminal`, `terminalOutput`, `waitForTerminalExit`, `killTerminal`, `releaseTerminal`. v2 removes `fs/*` and `terminal/*` outright; agents reach the client's world through MCP. The v1 `Client` had ~9 methods; v2's has **four entry points**.
- **Off `Agent`:** `loadSession` (replaced by `session/resume`), `setSessionMode` (deprecated in v1, gone in v2), and possibly `deleteSession` — M0 confirms whether `session/delete` survives.

Do not port the v1 protocols and prune. Write the v2 shape from the generated v2 routing table, then check the old code for anything worth keeping.

## What

`plan.md` -> **M2**.

Hand-written `Agent` and `Client` protocols over the generated types.

**`Agent`** (Client -> Agent): `initialize`, `auth/login`, `auth/logout`, `session/new`, `session/list`, `session/resume`, `session/close`, `session/prompt`, `session/set_config_option`, plus the `session/cancel` notification.

**`Client`** (Agent -> Client): `session/request_permission`, `elicitation/create`, plus the `session/update` and `elicitation/complete` notifications. **Four entry points** -- v2 removed `fs/*` and `terminal/*` entirely, and *"stable v2 defines no standard client capability fields."*

- Method-name mapping stays **internal and generated** (`session/new` -> `newSession`); never hand-wired.
- Capability-gated methods get defaults returning JSON-RPC method-not-found, so a conformer implements only what it advertises.
- When `capabilities.session` is advertised, an agent **must** implement the baseline: `session/new`, `session/list`, `session/resume`, `session/close`, `session/prompt`, `session/cancel`, `session/update`. Make that hard to get wrong -- ideally not merely documented.
- `auth/login` / `auth/logout` are required only when `authMethods` is non-empty.

## Test coverage to re-establish

- **The compiled-routing-table acceptance suite** (v1: `RoutingTableAcceptanceTests`) — asserts the checked-in generated `MethodTable` matches fresh generation, covers both sides and both kinds, and that stable and unstable tables are disjoint. **This is the regression guard for the wrong-wiring bug class this package exists to prevent** (the TS-SDK's `setSessionModel` -> `session/set_mode`). It was dropped with the v1 generated output; it must come back.

## Acceptance Criteria

- [ ] Both protocols compile with the generated types; no hand-written method mapping.
- [ ] Optional methods default to method-not-found.
- [ ] The session baseline requirement is enforced or checkably asserted.
- [ ] Auth methods are conditional on `authMethods`.
- [ ] A minimal conformer of each role is possible in a handful of lines.
- [ ] The compiled-routing-table acceptance suite exists again.

## Tests

- [ ] A conformer implementing only the baseline compiles and serves a session.
- [ ] Calling an unimplemented optional method yields method-not-found, not a crash.
- [ ] A stub `Client` implementing only the four entry points compiles.
- [ ] Auth methods absent when `authMethods` is empty; present when not.
- [ ] A deliberately mis-wired route fails the routing acceptance test (verified, then reverted).
