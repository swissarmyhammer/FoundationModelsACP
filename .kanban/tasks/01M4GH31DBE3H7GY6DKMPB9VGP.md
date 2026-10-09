---
assignees:
- claude-code
position_column: todo
position_ordinal: '8780'
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