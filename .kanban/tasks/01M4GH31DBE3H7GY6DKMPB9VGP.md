---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4hcycfavqe7hhyehxrp8dqq
  text: |-
    Implementation done. Discoveries:
    - Line numbers in the card were old. ClientSideConnection reference is now at the `initialize(_:)` doc comment. PermissionRequestTests reference is at the suite doc comment.
    - The acceptance commands did not find all indirect references. I also found "this milestone" (ReplayTransportTests, ThirdPartyInterop, PromptLifecycleTests ordering test), "the task references" (RoutingCoverageTests), and "*Testing strategy*" (GoldenSessionEndToEndTests, OutOfOrderConvergenceTests). I changed all of them.
    - `"m1"` string values in tests (message IDs, auth method IDs) are not milestone references. The acceptance rg is case-sensitive, so they do not match.
    - ProtocolVersionMismatchError now holds the short v2-only reason. ClientSideConnection.initialize points to it. README Cautions holds the same short reason.
    - plan.md deletion is staged by `git rm`. Nothing is committed.
    - insertUserMessage and the ResponseHooks success-only hooks are not changed.
  timestamp: 2026-10-09T22:36:06.506697+00:00
- actor: claude-code
  id: 01m4hcygmv6j7za01mysee7264
  text: |-
    ### implement — changed
    - evidence: 15 files — plan.md (deleted), README.md, Sources/FoundationModelsACP/Core/ProtocolVersion.swift, Sources/FoundationModelsACP/Connection/ClientSideConnection.swift, IntegrationTests/Tests/FoundationModelsACPIntegrationTests/SchemaConformanceTests.swift, Tests/FoundationModelsACPTests/{ThirdPartyInterop,ReplayTransportTests,GoldenSessionEndToEndTests,OutOfOrderConvergenceTests,PermissionRequestTests,PromptLifecycleTests,SessionLifecycleTests,RoutingCoverageTests,InitializeNegotiationTests}.swift. Both acceptance rg commands find nothing. `swift build --build-tests` clean; `swift test` 482 + 135 tests pass, 0 warnings; `swift test --package-path IntegrationTests` 7 tests pass.
    - next: /review
  timestamp: 2026-10-09T22:36:10.779996+00:00
- actor: claude-code
  id: 01m4hd1zk5zq10smzgxj40mzt4
  text: |-
    ### test — green
    - evidence: swift test (root) 482 tests in 50 suites + 135 tests in 17 suites passed; IntegrationTests 7 passed; builds with -warnings-as-errors clean in both packages; both acceptance rg checks found nothing.
    - next: commit, then review.
  timestamp: 2026-10-09T22:38:04.389205+00:00
position_column: doing
position_ordinal: '8180'
title: Remove plan.md and the references to it
---
## Problem

`plan.md` is old. All its milestones are done, and some text is not correct now (for example, lines 408-414 say that the `_meta` omitted-or-null gap is open, but `PatchField` closed it).

## Work

1. Delete `plan.md`.
2. Remove or change each direct reference to it:
   - `README.md:69` and `README.md:73`. Move the short *v2 only* reason into the README *Cautions* section, because it is not in other locations.
   - `Sources/FoundationModelsACP/Connection/ClientSideConnection.swift:237`
   - `Sources/FoundationModelsACP/Core/ProtocolVersion.swift:31`
   - `IntegrationTests/Tests/FoundationModelsACPIntegrationTests/SchemaConformanceTests.swift:52`
   - `Tests/FoundationModelsACPTests/ReplayTransportTests.swift:7`, `ThirdPartyInterop.swift:2,10`, `GoldenSessionEndToEndTests.swift:10`, `OutOfOrderConvergenceTests.swift:10`, `PermissionRequestTests.swift:6`, `PromptLifecycleTests.swift:301`.
3. Scan all comments. Change each comment that refers to the plan indirectly, for example by a milestone id (`M1` to `M9`), so that the comment stands alone. Known indirect references:
   - `Tests/FoundationModelsACPTests/RoutingCoverageTests.swift:10` ("from M2")
   - `Tests/FoundationModelsACPTests/SessionLifecycleTests.swift:16` ("M3's tester"), `:144` ("The real M5 agent"), `:146` ("the actual M5 session lifecycle"), `:389` ("M1's comment on this card")
   - `Tests/FoundationModelsACPTests/InitializeNegotiationTests.swift:8` ("shape M4 models")
   - `Tests/FoundationModelsACPTests/PromptLifecycleTests.swift:84` ("The M6 agent")
4. Comments must give the reason directly. They must not point to a deleted file or to a milestone id.

## Acceptance

- `rg -n "(^|[^-])plan\.md" --glob '!.kanban/**'` finds nothing.
- `rg -n "\bM[0-9]\b" Sources Tests IntegrationTests README.md` finds no milestone reference.
- The build passes, and all tests pass.