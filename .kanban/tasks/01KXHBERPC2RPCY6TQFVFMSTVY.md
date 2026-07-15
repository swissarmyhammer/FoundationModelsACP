---
comments:
- actor: wballard
  id: 01kxkqztnnfepm7nqgg2fre4w4
  text: |-
    Picked up. Research complete over the current tree (bridge-core ^f1esxqp, role-protocols ^872z threads + generated models).

    DESIGN — session-management forwarding on `FoundationModelsAgent` (actor conforming to `Agent`). The four methods are OVERRIDDEN on the actor (they can't rely on static protocol-default gating, since a single conformer advertises-or-not per provider instance at runtime); each checks its hook and forwards, else throws `RoleRouting.methodNotFound(handler:on:.agent)` (= -32601):
    - `listSessions(ListSessionsRequest)` → `provider.listSessions` → `ListSessionsResponse(sessions:)` ([SessionSummary]=[SessionInfo]).
    - `resumeSession(ResumeSessionRequest)` and `loadSession(LoadSessionRequest)` → `provider.restoreSession(sessionId)`; the restored `LanguageModelSession` is stored into the bridge map (`sessions[id]=SessionState(session:)`) so subsequent prompts hit the identical serializeTurn→runTurn→streamTurn path a fresh session does. Returns `ResumeSessionResponse()`/`LoadSessionResponse()`.
    - `deleteSession(DeleteSessionRequest)` → `provider.deleteSession(sessionId)`, then drops any live copy from the map (a deleted session must not stay promptable).
    - `closeSession(CloseSessionRequest)` → drops the live session from the map; no provider hook (it's purely local).

    CAPABILITY GATING (initialize) — add to the existing list/resume/delete:
    - `close`: advertised iff the provider is a store (any of list/resume/delete hooks present). Satisfies the card: "supported whenever sessions are" AND "the bare one-liner advertises none of these" (all hooks nil → no close). Purely-local close needs no dedicated hook.
    - `loadSession: true` iff `restoreSession != nil` — load forwards to the same restore hook as resume, so advertise==honor for both (closes the advertise-vs-honor window the bridge-core comment flagged as intentional-until-this-task).

    FM API: the bridge never constructs a `LanguageModelSession` itself for restore — the provider's `restoreSession` hook does (typically `LanguageModelSession(model:transcript:)`, verified-real in the ^f1esxqp thread). The in-memory test store will exercise that real restore ctor from a stored Transcript to satisfy the "probe the real init" requirement.

    TESTS (Tests/FoundationModelsACPTests/Bridge/SessionManagementTests.swift): an in-memory `SessionStore` backing all hooks. Hook-PRESENT: session/list|resume|delete|close round-trip over the wire via `ClientSideConnection` outbound methods, asserting wire responses + store side effects. Hook-ABSENT: `initialize` caps off (list/resume/delete/close all nil) + direct `agent.<method>` throws -32601. Resume turn-path proof is DETERMINISTIC (no live model): after resume, `serializeTurn(for:resumedId){ runTurn(for:resumedId,generate:scripted) }` (prompt's exact structure minus streamTurn's real model) yields `.endTurn` + emits session/update identically to a fresh session; serializeTurn throwing invalidParams for an un-resumed id proves resume registered the restored session. TDD: RED first.
  timestamp: 2026-07-15T20:37:44.245043+00:00
- actor: wballard
  id: 01kxkrbe2yv2ewc4rqyyf35476
  text: |-
    Implementation landed. swift build --build-tests: 0 warnings/errors. swift test: 156 FoundationModelsACPTests + 108 ACPGenerateTests = 264 pass, 0 failures, 0 warnings. New SessionManagementTests (9 tests) ran 3x consecutively — deterministic, no live model, no SIGTRAP risk.

    Production (Sources/FoundationModelsACP/Bridge/FoundationModelsAgent.swift):
    - initialize now gates `close` (advertised iff `managesSessionStore` = any of list/resume/delete hooks present) and `loadSession: Bool` (iff restoreSession present), alongside the existing list/resume/delete gating. Bare one-liner (all hooks nil) advertises none.
    - New "Session management" section: `listSessions` → provider.listSessions → ListSessionsResponse; `resumeSession`/`loadSession` → private `restore(_:forHandler:)` which calls provider.restoreSession and stores the restored LanguageModelSession into `sessions[id]` (so the turn path finds it); `deleteSession` → provider.deleteSession then drops the live map entry (deleted session must not stay promptable); `closeSession` drops the live map entry (no hook — purely local). Each hook-absent path throws via private `unsupported(_:)` = RoleRouting.methodNotFound(handler:on:.agent) (-32601), matching the Agent protocol default the actor overrides.

    FM API PROBE: the bridge never builds a LanguageModelSession for restore — the provider's restoreSession hook does. Confirmed `LanguageModelSession(model: SystemLanguageModel.default, transcript:)` compiles+runs (the test store restores from a stored Transcript via exactly that ctor) — the verified-real restore init from the ^f1esxqp thread, now exercised.

    TESTS (Tests/FoundationModelsACPTests/Bridge/SessionManagementTests.swift): in-memory `InMemorySessionStore` (Mutex-backed, Sendable) backs all four hooks. Hook-present: list/delete/resume/close round-trip over the wire via ClientSideConnection outbound methods (list returns stored SessionInfos, delete removes from store, resume returns ResumeSessionResponse(), close returns empty ok); full-store initialize advertises all four caps + loadSession. Hook-absent (singleSessionProvider, no hooks): initialize caps all nil + loadSession false; direct agent.{listSessions,resumeSession,loadSession,deleteSession,closeSession} all throw -32601. Resume turn-path proof (deterministic, NO live model): pre-resume serializeTurn→invalidParams (session unknown); after resume, both the resumed id AND a fresh newSession id run prompt()'s exact serializeTurn{runTurn{scripted}} structure and behave identically — both .endTurn, both emit the same agentMessageChunk update over the wire. closeSessionDropsLiveSessionFromMap independently proves close removes the map entry (post-close serializeTurn→invalidParams). Checkpoint + review next.
  timestamp: 2026-07-15T20:44:04.574953+00:00
depends_on:
- 01KXHBDAK0NQ5RA2NWTF1ESXQP
position_column: doing
position_ordinal: '80'
title: 'Bridge session management: provider hooks → list/resume/delete/close'
---
## What
Forward the session-management surface to the `SessionProvider` hooks (spec §7.1 — note §7.2: this seam is the ACP v2 baseline shape, not optional polish):

- `listSessions` → `provider.listSessions` (→ `[SessionSummary]`); `resumeSession`/`loadSession` → `provider.restoreSession` (typically `LanguageModelSession(model:tools:transcript:)`); `deleteSession` → `provider.deleteSession`; `closeSession` drops the live session from the bridge's map (and is supported whenever sessions are).
- Absent hooks → capability off in `initialize` AND JSON-RPC -32601 method-not-found if called anyway (spec §4).
- The bare one-liner (`FoundationModelsAgent(connection:session:)`) advertises none of these — it doesn't pretend to have a store.
- A resumed session behaves identically to a fresh one for subsequent prompts (same turn path).

## Acceptance Criteria
- [ ] With all hooks present: `session/list`, `session/resume`, `session/delete`, `session/close` round-trip through the provider and return correct wire responses
- [ ] With hooks absent: capabilities are off and direct calls answer -32601
- [ ] A prompt on a resumed session runs the normal turn path against the restored `LanguageModelSession`

## Tests
- [ ] `Tests/FoundationModelsACPTests/Bridge/SessionManagementTests.swift` — in-memory provider store exercising all four methods, both hook-present and hook-absent variants
- [ ] Run `swift test` — exits 0

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.