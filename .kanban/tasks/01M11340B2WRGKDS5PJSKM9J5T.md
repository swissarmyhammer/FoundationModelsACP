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
- actor: claude-code
  id: 01m1166f21d50qrzvc8v15vycz
  text: |-
    ### review — findings
    - evidence: 1 finding (1 confirmed, 0 refuted) — Tests/FoundationModelsACPTests/AgentProtocolTests.swift:194
    - scope: review sha HEAD~1..HEAD
    - next: add the logoutAuth guard test for the terminal-only agent, then run review again.
  timestamp: 2026-08-27T08:43:14.881904+00:00
- actor: claude-code
  id: 01m116708k0vxh0dwm6snbjb2y
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 7 files (Connection/Agent.swift, Connection/Client.swift, AgentProtocolTests.swift, ProtocolSourceTestSupport.swift, PermissionRequestTests.swift, ThirdPartyInterop.swift, plan.md)
    - test: green — swift test 107 tests passed; IntegrationTests 6 tests passed; DocC --warnings-as-errors exit 0
    - commit: 2a30cc1
    - review: findings — Tests/FoundationModelsACPTests/AgentProtocolTests.swift:194 (completeness/invariant-propagation: logoutAuth needs the same terminal-only guard test as loginAuth)
    - next: implement the finding
  timestamp: 2026-08-27T08:43:32.499690+00:00
- actor: claude-code
  id: 01m116fyjerb9rmr7qv73y1krm
  text: |-
    ### Implementation — review round 2

    The finding, word for word: "The new test verifies terminal-only agents throw on `loginAuth`, but the same documentation change applies to `logoutAuth` with the identical terminal-method exception. Both methods now carry the same documented requirement but only one is tested for the terminal case. Add a test verifying that terminal-only agents also throw on `logoutAuth`."

    The cause, and where it stands in the whole file:

    The change rewrote the doc comment on `loginAuth` AND on `logoutAuth`. Two tests guard that change. `loginAndLogoutDocsExcludeTerminalMethodsFromTheLoginObligation` already reads both doc blocks, so it holds both halves. `terminalOnlyAuthMethodsKeepTheThrowingLoginDefault` held only the `loginAuth` half. That is the one site of the cause in this file, and it is now closed.

    Two other tests were read and left alone, and each for a stated reason:

    - `unimplementedCapabilityGatedMethodsYieldMethodNotFoundNotACrash` already calls all four gated methods — `loginAuth`, `logoutAuth`, `deleteSession`, `setSessionConfigOption`. No gap.
    - `defaultMethodNotFoundErrorsNameTheWireMethodFromTheRoutingTable` samples `loginAuth` and `deleteSession` alone. It guards a DIFFERENT invariant — that the wire-method string each default reports agrees with the generated table — not the terminal-method documentation contract this change made. It also predates this change. Widening it is an unrelated refactor of a test that already existed, so it stays as written.

    The test was EXTENDED rather than copied. A second test would have repeated the terminal setup — the `AuthMethodTerminal` value, the `BaselineAgent(advertisedAuthMethods:)`, and the `initialize` call — which the `duplication` validator treats as a blocker, and none of its Swift carve-outs covers a test body. The prevailing pattern of this file is the one the sibling test `authMethodsAreAbsentByDefaultAndPresentWhenOverridden` already takes: it holds `loginAuth` and `logoutAuth` in one test. The finding's own example asks for the extension as well.

    The test was renamed `terminalOnlyAuthMethodsKeepTheThrowingLoginDefault` -> `terminalOnlyAuthMethodsKeepTheThrowingAuthDefaults`, because the old name says "Login" and the body now holds both defaults.

    ### The RED, which was made real

    The last round recorded honestly that `terminalOnlyAuthMethodsKeepTheThrowingLoginDefault` passed the moment it compiled. The same is true of a `logoutAuth` guard written beside it, so a plain run proves nothing. The failure was therefore made to happen: the default `logoutAuth` in `Sources/FoundationModelsACP/Connection/Agent.swift` was changed to return `LogoutAuthResponse()` in place of `try throwMethodNotFound("auth/logout")`, and the suite was run.

    `swift test --filter AgentProtocolTests` then reported:

        ✘ terminalOnlyAuthMethodsKeepTheThrowingAuthDefaults() recorded an issue at
          AgentProtocolTests.swift:215:15: Expectation failed: an error was expected
          but none was thrown

    Line 215 is the NEW expectation. The test failed on the assertion the finding asked for, and for the right reason. Two sibling tests failed beside it — `authMethodsAreAbsentByDefaultAndPresentWhenOverridden` and `unimplementedCapabilityGatedMethodsYieldMethodNotFoundNotACrash` — which is the correct blast radius for that mutation, and the other five tests of the suite stayed green.

    The mutation was then reverted. `git diff -- Sources/FoundationModelsACP/Connection/Agent.swift` is empty, so no production file carries a change from this round. The named production change that makes the new assertion fail is now on record: a default `logoutAuth` that answers instead of throwing.

    ### Gates

    - `swift build` — clean.
    - `swift test` — 107 tests in 14 suites, 0 failed, 0 skipped, 0 warnings.
    - `swift test --package-path IntegrationTests` — 6 tests in 2 suites, 0 failed.
    - `swift package generate-documentation --target FoundationModelsACP --warnings-as-errors` — exit 0, no warnings.

    Nothing under `Sources/FoundationModelsACP/Generated/` or `Schema/` was touched. `git status` shows one source file changed: `Tests/FoundationModelsACPTests/AgentProtocolTests.swift`.
  timestamp: 2026-08-27T08:48:25.678893+00:00
- actor: claude-code
  id: 01m116g4q4pdt7ksnd2e5e6cd8
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsACPTests/AgentProtocolTests.swift (+9/-2). `terminalOnlyAuthMethodsKeepTheThrowingLoginDefault` renamed to `terminalOnlyAuthMethodsKeepTheThrowingAuthDefaults` and given the `logoutAuth` expectation the finding asks for. RED proved by a temporary mutation of the default `logoutAuth` — the new expectation failed at AgentProtocolTests.swift:215 with "an error was expected but none was thrown"; the mutation is reverted and `git diff` on Sources/ is empty. `swift build` clean. `swift test` 107 tests / 14 suites, 0 failed, 0 skipped, 0 warnings. `swift test --package-path IntegrationTests` 6 tests / 2 suites passed. `swift package generate-documentation --target FoundationModelsACP --warnings-as-errors` exit 0. The 1 open Review Finding is fixed and checked.
    - next: /review
  timestamp: 2026-08-27T08:48:31.972455+00:00
- actor: claude-code
  id: 01m116jj4gsw8y4mr7va6m1y2d
  text: |-
    ### test — green
    - evidence: `swift test` at repo root — 107 tests, 14 suites, 0 failures, 0 warnings. `swift test --package-path IntegrationTests` — 6 tests, 2 suites, 0 failures, 0 warnings. `swift package generate-documentation --target FoundationModelsACP --warnings-as-errors` — build OK, doc archive built, 0 warnings.
    - `git status --porcelain -- Sources/` is empty. No source file has a change.
    - next: the task is clean. It can move to review.
  timestamp: 2026-08-27T08:49:51.248370+00:00
- actor: claude-code
  id: 01m116nwt1dev2bfzrn49y6awv
  text: |
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 80c983b) — 0 findings, 0 confirmed, 0 refuted, 7 attempted, 0 failed. 1 file reviewed (`Tests/FoundationModelsACPTests/AgentProtocolTests.swift`), 2 files excluded by `.reviewignore` (`.kanban/`).
    - prior findings: the one item from the 2026-08-27 03:39 section is checked and genuinely done — `terminalOnlyAuthMethodsKeepTheThrowingAuthDefaults` now asserts `RequestError` from `logoutAuth` as well as `loginAuth` for a terminal-only agent.
    - next: task moved to `done`. No open findings.
  timestamp: 2026-08-27T08:51:40.481568+00:00
- actor: claude-code
  id: 01m116pbcxym83z42vmpw54yec
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 1 file (Tests/FoundationModelsACPTests/AgentProtocolTests.swift, +9/-2); the terminal-only guard test is renamed to terminalOnlyAuthMethodsKeepTheThrowingAuthDefaults and now covers logoutAuth
    - test: green — swift test 107 tests passed; IntegrationTests 6 tests passed; DocC --warnings-as-errors exit 0
    - commit: 80c983b
    - review: clean — 0 findings, 7 validator pairs attempted, 0 failed; the prior finding is checked and addressed
    - next: task in done; the schema-alpha3 scope is clear
  timestamp: 2026-08-27T08:51:55.421440+00:00
depends_on:
- 01M112K7M506DDHQ3SN6QDCGGY
position_column: done
position_ordinal: 9a80
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

## Review Findings (2026-08-27 03:39)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 6 file(s) reviewed, 5 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `plan.md` — no validator matches this file

- [x] `Tests/FoundationModelsACPTests/AgentProtocolTests.swift:194` `completeness/invariant-propagation` — The new test verifies terminal-only agents throw on `loginAuth`, but the same documentation change applies to `logoutAuth` with the identical terminal-method exception. Both methods now carry the same documented requirement but only one is tested for the terminal case. Add a test verifying that terminal-only agents also throw on `logoutAuth`. For example, extend the test at line 194 to include: `await #expect(throws: RequestError.self) { _ = try await agent.logoutAuth(LogoutAuthRequest()) }`.
