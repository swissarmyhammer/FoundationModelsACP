---
comments:
- actor: claude-code
  id: 01kyfgbjp9pvdqt4fgzpxf6zgf
  text: |-
    Corrected against the vendored `Schema/acp-v2.json` + `acp-v2.meta.json` / `acp-v2.meta.unstable.json` (`schema-v2.0.0-alpha.2`, vendored in M0). The card predated the vendor and its counts were wrong.

    What changed:
    - Title: "nine agent methods, four client entry points" -> "eleven agent methods, two client entry points". (Retitled twice: it first read "ten", counting only the requests, which contradicted the eleven-method manifest count in the next bullet.)
    - `Agent` list gained `session/delete`. The stable manifest lists eleven agent methods: `initialize`, `auth/login`, `auth/logout`, `session/new`, `session/list`, `session/resume`, `session/close`, `session/delete`, `session/prompt`, `session/set_config_option`, and the `session/cancel` notification.
    - `Client` corrected from "four entry points" to two: `session/request_permission` and the `session/update` notification. That is the whole of `clientMethods` in the stable manifest.
    - `elicitation/create` / `elicitation/complete` removed from the stable `Client` surface. They appear only in `acp-v2.meta.unstable.json`; there are no stable request/response types to generate against. Recorded as deferred until a re-vendor promotes them rather than dropped.
    - `$/cancel_request` called out as protocol-level (`protocolMethods`), not a role-protocol member.
    - Starting point: the `deleteSession` open question is resolved -- it survives as stable `session/delete`, gated on `capabilities.session.delete`.
    - Added the M1-seam note for `session/set_config_option` params, matching `plan.md` -> M2.
    - Acceptance/test bullets follow: "four entry points" -> "two", capability gate for `session/delete`, and a new check that no unstable-only method lands on a role protocol.
  timestamp: 2026-07-26T15:23:04.777688+00:00
- actor: claude-code
  id: 01kyfxsvfc4zrhygnw82h6j9qf
  text: |-
    The M1 seam is closed — this card's "blocked on the M1 seam" note is resolved and has been removed from `plan.md`.

    `session/set_config_option` now routes a real params type. `SetSessionConfigOptionRequest` generates as a struct with `sessionId: SessionId`, `configId: SessionConfigId`, `value: SetSessionConfigOptionRequest.Value`, and `_meta`, so M2 will emit `setSessionConfigOption(_ params: SetSessionConfigOptionRequest)` rather than `(_ params: JSONValue)`. `MethodTable.generated.swift` already carries `paramsTypeName: "SetSessionConfigOptionRequest"` and it now resolves to that struct.

    Nothing else in the stable routing table resolves to a placeholder: `Unresolved.generated.swift` is down to eight typealiases, and `VendoredSchemaTests.stableMethodTableRoutesExactlyTheStableManifest` pins every params and result type name.
  timestamp: 2026-07-26T19:18:04.012194+00:00
- actor: claude-code
  id: 01kyjdrxrky6hr3zsa9w42xn9c
  text: |-
    Implemented.

    - `Sources/FoundationModelsACP/Connection/Agent.swift` — new `Agent` protocol. `initialize` plus the six session-baseline methods (`newSession`, `listSessions`, `resumeSession`, `closeSession`, `prompt`, `sessionCancel`) are required members with no default — a conforming type must implement them directly, which is how the session-baseline requirement is enforced rather than merely documented. The four capability-gated methods (`loginAuth`, `logoutAuth`, `deleteSession`, `setSessionConfigOption`) get default implementations in an `extension Agent` that throw `RequestError.methodNotFound(<wire method>)`. Method names are exactly the generated routing table's `handlerName`s (e.g. `session/cancel` -> `sessionCancel`, not v1's `cancel`) — no hand-wired mapping.
    - `Sources/FoundationModelsACP/Connection/Client.swift` — new `Client` protocol: exactly `sessionUpdate` and `requestPermission`, both required, no defaults — that is the entire stable client surface, so there is nothing left to gate. No `elicitation/*`, no `fs/*`/`terminal/*`.
    - `Tests/FoundationModelsACPTests/AgentProtocolTests.swift` — a `BaselineAgent` conformer implementing only the seven required methods compiles and serves a session; a `FullAgent` conformer overrides all four capability-gated methods too. Covers: baseline-only conformance, unimplemented capability-gated methods throwing `RequestError` (not crashing), the thrown error's `data.method` matching the routing table's wire name for that handler (cross-checked against `ACPMethodTable.methods`, not hardcoded twice), auth methods absent-by-default/present-when-overridden, `session/delete` gated independently, and no unstable-only (elicitation) method appearing on `Agent`.
    - `Tests/FoundationModelsACPTests/ClientProtocolTests.swift` — a `StubClient` actor implementing only the two entry points compiles and works; asserts no unstable-only method and no removed v1 `fs/*`/`terminal/*` method appears on `Client`.
    - `Tests/FoundationModelsACPTests/ProtocolSourceTestSupport.swift` — shared helper reading the two hand-written protocol files' source, for the elicitation/removed-method source-scan assertions above.
    - `Tests/ACPGenerateTests/RoutingTableTests.swift` — re-established `RoutingTableAcceptanceTests` (dropped with the v1 generated output): `checkedInTableMatchesFreshGeneration` (redundant with, but independent of, `VendoredSchemaTests.checkedInOutputMatchesAFreshRun` — this one is scoped to the routing table specifically and named to match the v1 regression-guard suite), `compiledTableCoversBothSidesAndKinds`, `compiledUnstableTableIsDisjointFromStable`.

    Verified the acceptance suite actually catches a wrong-wiring bug: temporarily renamed one checked-in `handlerName` (`setSessionConfigOption` -> `setSessionMode`) in `MethodTable.generated.swift`, confirmed `checkedInTableMatchesFreshGeneration` failed, then reverted (`git status` clean afterward, `swift test` green again).

    Design notes for the next milestone (M3, connections):
    - `session/update` is on the *baseline list* in the task text but is a `Client` method the agent calls, not an `Agent` method — it cannot be enforced by the `Agent` protocol's shape alone. The session-baseline enforcement here covers everything actually declared on `Agent`; wiring an agent's session handlers to an actual `Client` connection is M3's job.
    - `session/close`/`session/delete` return typed `CloseSessionResponse`/`DeleteSessionResponse` (not `Void`), per the generated routing table — a deliberate correction versus the v1 precedent where `closeSession`/`deleteSession` were `throws`-only.
    - `session/set_config_option` is not part of the baseline (it's not in the seven-method list), so it is capability-gated with a default, same treatment as `session/delete` and the two auth methods.

    Verified green: `swift build --build-tests` clean, 0 warnings. `swift test` = 135 tests / 19 suites / 0 failures (61 FoundationModelsACPTests + 74 ACPGenerateTests), up from the 123/16 baseline by exactly the 12 new tests (6 in `AgentProtocolTests`, 3 in `ClientProtocolTests`, 3 in `RoutingTableAcceptanceTests`). No generated file touched; `git status` on `Sources/FoundationModelsACP/Generated/` is clean and `checkedInOutputMatchesAFreshRun`/`checkedInTableMatchesFreshGeneration` both pass, so the codegen diff gate is unaffected. `swift-format` was not run per standing instruction.
  timestamp: 2026-07-27T18:35:39.667212+00:00
- actor: claude-code
  id: 01kyje43jkzkg8m723b87t153d
  text: |-
    Adversarial double-check (background `double-check` agent) returned REVISE with two non-blocking findings, both fixed:

    1. `RoutingTableAcceptanceTests.compiledTableCoversBothSidesAndKinds` covered agent+request, client+notification, agent+notification, and protocolLevel+notification, but never the client+request cell of the (side x kind) matrix. Added `session/request_permission` side/kind assertions to close it.
    2. `Agent.swift`'s `setSessionConfigOption` doc comment omitted any statement of its gating condition, unlike its three capability-gated siblings. Added a note that the vendored schema declares no dedicated capability flag for it, and that gating is implicit via whether a session reports any `configOptions`.

    Everything else the double-check verified independently (handler names/sides/kinds/result types cross-checked against `MethodTable.generated.swift`, doc claims cross-checked against `Schema/acp-v2.json` prose, baseline-conformer test really implements only the required members, unimplemented-method test calls a genuinely un-overridden default, fresh `swift build --build-tests` + `swift test` run by the agent itself) came back clean.

    Re-verified green after both fixes: `swift build --build-tests` clean, 0 warnings; `swift test` = 135 tests / 19 suites / 0 failures (61 FoundationModelsACPTests + 74 ACPGenerateTests). Leaving in `doing` for `/review`.
  timestamp: 2026-07-27T18:41:46.067087+00:00
depends_on:
- 01KYD58WN4KFHR3TP9HQZHT036
position_column: doing
position_ordinal: '80'
title: 'M2 Role protocols: eleven agent methods, two client entry points'
---
## Starting point

**This is a rewrite.** `plan.md` -> *Starting point* has the full inventory.

The v1 `Agent` and `Client` protocols were deleted (`Connection/Agent.swift`, `Connection/Client.swift`). Consult them in git history — the shape is a useful reference — but understand the delta is large, and mostly **subtraction**:

- **Off `Client`:** `readTextFile`, `writeTextFile`, `createTerminal`, `terminalOutput`, `waitForTerminalExit`, `killTerminal`, `releaseTerminal`. v2 removes `fs/*` and `terminal/*` outright; agents reach the client's world through MCP. The v1 `Client` had ~9 methods; v2's has **two entry points**.
- **Off `Agent`:** `loadSession` (replaced by `session/resume`) and `setSessionMode` (deprecated in v1, gone in v2). `deleteSession` **survives** — M0 confirmed `session/delete` is stable in v2 and distinct from `session/close`, gated on `capabilities.session.delete`.

Do not port the v1 protocols and prune. Write the v2 shape from the generated v2 routing table, then check the old code for anything worth keeping.

## What

`plan.md` -> **M2**.

Hand-written `Agent` and `Client` protocols over the generated types.

**`Agent`** (Client -> Agent) — **ten requests plus one notification**: `initialize`, `auth/login`, `auth/logout`, `session/new`, `session/list`, `session/resume`, `session/close`, `session/delete`, `session/prompt`, `session/set_config_option`, plus the `session/cancel` notification.

**`Client`** (Agent -> Client) — **two entry points**: `session/request_permission` (request) and `session/update` (notification). That is the entire stable client surface — v2 removed `fs/*` and `terminal/*`, and *"stable v2 defines no standard client capability fields."*

**`$/cancel_request` is protocol-level**, not a member of either role protocol. It is the sole entry in the schema's `protocolMethods`, and belongs with the connection plumbing (M3), not with `Agent`/`Client`.

**Elicitation is deferred, not part of `Client`.** `elicitation/create` and `elicitation/complete` are **unstable-only** in the vendored `schema-v2.0.0-alpha.2` — they appear in `acp-v2.meta.unstable.json` and in neither the stable manifest nor the stable schema, so there are no request/response types to generate against. Do not put them on the `Client` protocol. Pick them up when a re-vendor promotes them; upstream `main` already has.

- Method-name mapping stays **internal and generated** (`session/new` -> `newSession`); never hand-wired.
- Capability-gated methods get defaults returning JSON-RPC method-not-found, so a conformer implements only what it advertises. `session/delete` is one of these (`capabilities.session.delete`); so are `auth/login` / `auth/logout`.
- When `capabilities.session` is advertised, an agent **must** implement the baseline: `session/new`, `session/list`, `session/resume`, `session/close`, `session/prompt`, `session/cancel`, `session/update`. Make that hard to get wrong -- ideally not merely documented.
- `auth/login` / `auth/logout` are required only when `authMethods` is non-empty.

*Blocked on the M1 seam:* `session/set_config_option` has no params type until `SetSessionConfigOptionRequest` resolves — generated against today's output it would emit `setSessionConfigOption(_ params: JSONValue)`.

**Resolved.** M1 closed this seam: `SetSessionConfigOptionRequest` now generates as a real struct (`sessionId`, `configId`, `value: SetSessionConfigOptionRequest.Value`, `_meta`), so `setSessionConfigOption` routes a typed params object rather than `JSONValue`.

## Test coverage to re-establish

- **The compiled-routing-table acceptance suite** (v1: `RoutingTableAcceptanceTests`) — asserts the checked-in generated `MethodTable` matches fresh generation, covers both sides and both kinds, and that stable and unstable tables are disjoint. **This is the regression guard for the wrong-wiring bug class this package exists to prevent** (the TS-SDK's `setSessionModel` -> `session/set_mode`). It was dropped with the v1 generated output; it must come back.

## Acceptance Criteria

- [x] Both protocols compile with the generated types; no hand-written method mapping.
- [x] Optional methods default to method-not-found.
- [x] The session baseline requirement is enforced or checkably asserted.
- [x] Auth methods are conditional on `authMethods`; `session/delete` is conditional on `capabilities.session.delete`.
- [x] A minimal conformer of each role is possible in a handful of lines.
- [x] Neither role protocol carries an unstable-only method — elicitation in particular.
- [x] The compiled-routing-table acceptance suite exists again.

## Tests

- [x] A conformer implementing only the baseline compiles and serves a session.
- [x] Calling an unimplemented optional method yields method-not-found, not a crash.
- [x] A stub `Client` implementing only the two entry points compiles.
- [x] Auth methods absent when `authMethods` is empty; present when not.
- [x] A deliberately mis-wired route fails the routing acceptance test (verified, then reverted).
