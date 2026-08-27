---
assignees:
- claude-code
depends_on:
- 01M112K7M506DDHQ3SN6QDCGGY
position_column: todo
position_ordinal: '8280'
title: Sweep stale schema-pin references and fix loginAuth/logoutAuth DocC for terminal auth
---
## What
After the schema moves from pinned commit `7a13081` to tag `schema-v2.0.0-alpha.3`, remove every stale reference to the old pin, and correct public DocC that alpha.3 makes false.

- [ ] Sweep with `rg -n -i '7a13081|alpha\.2|pinned schema revision|pinned commit' --glob '!.git' --glob '!.build' --glob '!.sah' --glob '!.kanban' .` and fix every hit. Known sites: `plan.md` lines 85, 204, 378, 433, 437; `Tests/FoundationModelsACPTests/ThirdPartyInterop.swift:10` (`schema-v2.0.0-alpha.2` in a doc comment); `Sources/FoundationModelsACP/Connection/Client.swift:5` ("the pinned schema revision promotes elicitation to the stable surface" — public DocC; say that `schema-v2.0.0-alpha.3` holds elicitation on the stable surface).
- [ ] In `Sources/FoundationModelsACP/Connection/Agent.swift`, fix the DocC on `loginAuth` and on `logoutAuth`. Today both say: "Required only when this agent's `initialize` response advertises at least one `authMethods` entry; clients must not call it otherwise." Under alpha.3, `AuthMethodTerminal` says "The client MUST NOT pass this method to `auth/login`." So only non-`terminal` methods make `loginAuth` necessary. Rewrite both comments to say this. Write in ASD-STE100 Simplified Technical English.
- [ ] Build DocC with warnings as errors, the same as CI, to confirm the edited comments are clean.

## Acceptance Criteria
- [ ] The `rg` command above returns no hits.
- [ ] `Agent.swift` DocC on `loginAuth` and `logoutAuth` states that terminal-type methods do not require `auth/login`.
- [ ] The DocC build step from `.github/workflows/ci.yml` passes locally with no warnings.

## Tests
- [ ] Add a test in `Tests/FoundationModelsACPTests/AgentProtocolTests.swift`: an agent whose `initialize` response advertises only `[.terminal(AuthMethodTerminal(methodId: ..., name: ...))]` and does not override `loginAuth` still throws `RequestError` method-not-found from `loginAuth`, which proves the documented contract (a terminal-only agent has no `auth/login` obligation and the default remains the throwing one).
- [ ] `swift test` passes in full.
- [ ] The DocC build command from CI exits 0.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #schema-alpha3