---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m115fpxjcmaw218yks5mrbg8
  text: |-
    ### Research

    Sweep hits (the `rg` command on the card) — 8 lines:
    - `plan.md` 85, 204, 378, 433, 437
    - `Sources/FoundationModelsACP/Connection/Client.swift:5` (public DocC)
    - `Tests/FoundationModelsACPTests/ThirdPartyInterop.swift:10` (doc comment)
    - `Tests/FoundationModelsACPTests/PermissionRequestTests.swift:100` (comment)

    The card's `rg` pattern is line-based, so it misses two more occurrences of the same stale phrase that wrap across lines:
    - `plan.md:203` — "the pinned upstream / commit `7a13081`"
    - `Tests/FoundationModelsACPTests/AgentProtocolTests.swift:201` — "in the pinned schema / revision"

    Both name the same dead pin, so both get corrected.

    Schema facts read from `Schema/acp-v2.json` (`schema-v2.0.0-alpha.3`):
    - `AuthMethodTerminal.description` ends: "The client MUST NOT pass this method to `auth/login`."
    - `LoginAuthRequest` and `LogoutAuthRequest` both say: "Agents MUST support this method when their `initialize` response advertised at least one valid authentication method."
    - `AuthMethod` has cases `terminal`, `agent`, `unknown`.
    - No runtime code enforces `authMethods`; the obligation is prose only. Thus the new test is a contract guard on the throwing default.

    DocC command: `ci.yml` delegates to `swissarmyhammer/workflows/.github/workflows/swift-ci.yaml@main` with `docc-target: FoundationModelsACP`. That workflow runs:
    `swift package generate-documentation --target FoundationModelsACP --warnings-as-errors`

    Test design: `BaselineAgent` in `AgentProtocolTests.swift` gets a stored `advertisedAuthMethods` property (default `nil`) instead of a third copied conformer, because a third copy of the baseline body would duplicate `BaselineAgent` and `FullAgent`.
  timestamp: 2026-08-27T08:30:49.266450+00:00
- actor: claude-code
  id: 01m115s4kw99pvg21zs0m2rgy1
  text: |-
    ### Implementation

    TDD order, and what actually went red:

    1. RED — wrote `AgentProtocolTests.loginAndLogoutDocsExcludeTerminalMethodsFromTheLoginObligation`, which reads `Agent.swift` through the existing `sourceOfAgentProtocolFile()` seam and asserts each of the two doc blocks names `terminal`. It failed with 2 issues, and the failure output printed both stale doc blocks word for word ("Required only when this agent's `initialize` response advertises at least one `authMethods` entry; clients must not call it otherwise"). That is the state the card calls false, so the red was the correct red.
    2. GREEN — rewrote both doc comments. `swift test --filter AgentProtocolTests`: 8 tests, all pass.
    3. Added the card's named behavior test, `terminalOnlyAuthMethodsKeepTheThrowingLoginDefault`. Stated honestly: this one passes the moment it compiles. It is a contract guard, not a driver of the change. The production change that would make it fail is a default `loginAuth` that returns `LoginAuthResponse()` instead of throwing.

    Design notes:

    - `BaselineAgent` gained a stored `advertisedAuthMethods: [AuthMethod]?` (default `nil`) instead of a third conformer. A third copy of the baseline body would have duplicated `BaselineAgent` and `FullAgent`, which the `duplication` validator treats as a blocker. Every existing `BaselineAgent()` call site keeps working through the defaulted memberwise init.
    - `docComment(above:in:)` was first written private in `AgentProtocolTests.swift`, then moved to `ProtocolSourceTestSupport.swift` beside `sourceOfAgentProtocolFile` / `sourceOfClientProtocolFile`. That file is the established home for source-reading test support, and a doc check on `Client.swift` will want the same helper.
    - Doc-comment parameter keys use the internal names (`declaration`, `source`), not the external labels (`above`, `in`), per the `swift/doc-parameter-naming` rule.

    Beyond the card's `rg` list, two more references to the dead pin were corrected. The card's pattern is line-based and both wrap across lines, so neither showed in its output:

    - `plan.md:203` — "Elicitation is **stable** in the pinned upstream / commit `7a13081`"
    - `Tests/FoundationModelsACPTests/AgentProtocolTests.swift` in `agentCarriesNoUnstableOnlyMethod` — "in the pinned schema / revision"

    A follow-up multi-line sweep, `rg -U -i 'pinned\s+(schema\s+revision|commit|upstream)'`, now also returns no hits.

    `plan.md`'s two M0/M8 history lines were rewritten rather than merely retagged, because M0 genuinely did vendor the earlier artifact set. M0 now reads "vendored from `schema-v2.0.0-alpha.3` (a later re-vendor replaced M0's first artifact set)", and M8's parenthetical now says "At M8 time the vendored schema held them unstable-only" with no version number, so neither sentence claims something false.

    Nothing under `Sources/FoundationModelsACP/Generated/` or `Schema/` was touched — `git status` on both paths is empty, and `VendoredSchemaTests.checkedInOutputMatchesAFreshRun` passes.

    DocC command read out of `.github/workflows/ci.yml`: that file delegates to `swissarmyhammer/workflows/.github/workflows/swift-ci.yaml@main` with `docc-target: FoundationModelsACP`, and that workflow runs `swift package generate-documentation --target FoundationModelsACP --warnings-as-errors`. Ran verbatim; exit 0, no warnings.
  timestamp: 2026-08-27T08:35:58.204173+00:00
- actor: claude-code
  id: 01m115sbh0q23j8adrgx6jzctf
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsACP/Connection/Agent.swift (loginAuth + logoutAuth DocC rewritten), Sources/FoundationModelsACP/Connection/Client.swift (public DocC), Tests/FoundationModelsACPTests/AgentProtocolTests.swift (2 new tests, BaselineAgent gains advertisedAuthMethods, stale comment), Tests/FoundationModelsACPTests/ProtocolSourceTestSupport.swift (new docComment(above:in:) helper), Tests/FoundationModelsACPTests/PermissionRequestTests.swift (stale comment), Tests/FoundationModelsACPTests/ThirdPartyInterop.swift (stale doc comment), plan.md (5 stale references). `swift build` clean. `swift test`: 266 tests in 25 suites and 107 tests in 14 suites, 0 failures, 0 warnings. `swift test --package-path IntegrationTests`: 6 tests in 2 suites passed. `swift package generate-documentation --target FoundationModelsACP --warnings-as-errors` exit 0, no warnings. Card `rg` sweep returns no hits; multi-line sweep returns no hits. No file under Sources/FoundationModelsACP/Generated/ or Schema/ was touched.
    - next: /review
  timestamp: 2026-08-27T08:36:05.280842+00:00
- actor: claude-code
  id: 01m115x37tj0w6f4jp2z54vy69
  text: |-
    ### test — green
    - evidence: `swift test` — 107 tests, 14 suites, 0 failed, 0 skipped, 0 warnings (fresh `swift build --build-tests` after `rm -rf .build` also 0 warnings). `swift test --package-path IntegrationTests` — 6 tests, 2 suites, 0 failed, 0 skipped, 0 warnings (fresh build after `rm -rf IntegrationTests/.build`). `swift package generate-documentation --target FoundationModelsACP --warnings-as-errors` — build complete, doc archive generated, 0 warnings/errors.
    - new tests confirmed passing: `loginAndLogoutDocsExcludeTerminalMethodsFromTheLoginObligation`, `terminalOnlyAuthMethodsKeepTheThrowingLoginDefault`.
    - `git status` confirms `Sources/FoundationModelsACP/Generated/` and `Schema/` have no changes.
    - next: none — all three gates are clean.
  timestamp: 2026-08-27T08:38:07.866820+00:00
depends_on:
- 01M112K7M506DDHQ3SN6QDCGGY
position_column: doing
position_ordinal: '80'
title: Sweep stale schema-pin references and fix loginAuth/logoutAuth DocC for terminal auth
---
## What
After the schema moves from pinned commit `7a13081` to tag `schema-v2.0.0-alpha.3`, remove every stale reference to the old pin, and correct public DocC that alpha.3 makes false.

- [x] Sweep with `rg -n -i '7a13081|alpha\.2|pinned schema revision|pinned commit' --glob '!.git' --glob '!.build' --glob '!.sah' --glob '!.kanban' .` and fix every hit. Known sites: `plan.md` lines 85, 204, 378, 433, 437; `Tests/FoundationModelsACPTests/ThirdPartyInterop.swift:10` (`schema-v2.0.0-alpha.2` in a doc comment); `Sources/FoundationModelsACP/Connection/Client.swift:5` ("the pinned schema revision promotes elicitation to the stable surface" — public DocC; say that `schema-v2.0.0-alpha.3` holds elicitation on the stable surface).
- [x] In `Sources/FoundationModelsACP/Connection/Agent.swift`, fix the DocC on `loginAuth` and on `logoutAuth`. Today both say: "Required only when this agent's `initialize` response advertises at least one `authMethods` entry; clients must not call it otherwise." Under alpha.3, `AuthMethodTerminal` says "The client MUST NOT pass this method to `auth/login`." So only non-`terminal` methods make `loginAuth` necessary. Rewrite both comments to say this. Write in ASD-STE100 Simplified Technical English.
- [x] Build DocC with warnings as errors, the same as CI, to confirm the edited comments are clean.

## Acceptance Criteria
- [x] The `rg` command above returns no hits.
- [x] `Agent.swift` DocC on `loginAuth` and `logoutAuth` states that terminal-type methods do not require `auth/login`.
- [x] The DocC build step from `.github/workflows/ci.yml` passes locally with no warnings.

## Tests
- [x] Add a test in `Tests/FoundationModelsACPTests/AgentProtocolTests.swift`: an agent whose `initialize` response advertises only `[.terminal(AuthMethodTerminal(methodId: ..., name: ...))]` and does not override `loginAuth` still throws `RequestError` method-not-found from `loginAuth`, which proves the documented contract (a terminal-only agent has no `auth/login` obligation and the default remains the throwing one).
- [x] `swift test` passes in full.
- [x] The DocC build command from CI exits 0.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #schema-alpha3