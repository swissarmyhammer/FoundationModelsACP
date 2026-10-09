---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4ghdnt5t8snxp4v541k76s3
  text: |-
    Research: the tag `schema-v2.0.0-alpha.8` (released 2026-10-09) has the `error` stop reason and the idle `error` object. The release asset digests agree with local SHA-256 of the downloaded files:
    - schema.json 9bd47adb2af5f28c48d4ea6b3fe781ca05a152ab42defba04d141c432d2fa830
    - meta.json ad94c01f… (same as alpha.7)
    - meta.unstable.json d9c1d9ab… (same as alpha.7)
    - schema.unstable.json b09f7d8782ec6ea5d12fc710010212a56f18afa682e2d8222caf6a2aee2c63f9

    Shape changes in alpha.8 that are larger than the task text expects:
    1. The `StopReason` $def is removed. `IdleStateUpdate` is now a flat union: base properties `stopReason` (string|null) and `_meta`, and an `anyOf` with one variant per stop reason (end_turn, max_tokens, max_turn_requests, refusal, cancelled, error, other, none). The `error` variant does `allOf: [$ref ErrorStopReason]`. `ErrorStopReason` has one property `error` (`Error` | null).
    2. `notice`, `compaction_update`, `compaction_summary_chunk` move to the stable `SessionUpdate`. `CompactionId`, `CompactionStatus`, `CompactionSummaryChunk`, `CompactionUpdate`, `Notice`, `NoticeSeverity` are now stable $defs.
    3. `x-deserialize-default-on-error` / `x-deserialize-skip-invalid-items` removed from some array fields (AuthMethodTerminal, NewSessionRequest, ResumeSessionRequest). Doc text changes on ClientRequest and MessageId.
    4. The meta manifests did not change.
  timestamp: 2026-10-09T14:35:07.461538+00:00
- actor: claude-code
  id: 01m4gk1bam3zwbdnf5x3jgxd4m
  text: |-
    Decision from the user (question asked during implement): option A. Use the stable compaction and notice types everywhere. The merge engine and SessionEntry use the stable `CompactionUpdate`, `CompactionSummaryChunk`, `Notice`. Delete `Unstable.SessionUpdate`. Stop the emission of the duplicate `Unstable.Compaction*` and `Unstable.Notice*` types (remove the v2-unstable schema set emission). Keep the vendored unstable schema file and the `Unstable` method table.

    Also found: after a first regeneration with alpha.8, the generator emits `IdleStateUpdate` as `JSONValue` (Unresolved.generated.swift: "variants pin discriminators the generator cannot reconcile"), and no `StopReason` type. Generator support for the new flat stop-reason union is necessary. The stable `CompactionUpdate` also needs the patch-semantics entries in `GeneratorConfig.acpV2`.
  timestamp: 2026-10-09T15:03:20.660983+00:00
- actor: claude-code
  id: 01m4gk8gb7x9x2przjdx8r77en
  text: 'Generator design for the alpha.8 IdleStateUpdate shape: a new definition family `objectPropertyEnum`. Shape: an object definition whose `anyOf` variants pin a `const` on one of the object''s own declared properties. Each `const` variant can flatten one `$ref` payload with `allOf`. The `not` catch-all is dropped (the enum has `unknown(String)`). A variant that sets the property to `type: null` is the "no value" variant. Emission: a top-level scalar enum named from the property (`stopReason` -> `StopReason`, with `.error`), and a struct whose property takes that enum (`stopReason: StopReason?`, forgiving) plus each payload member as an optional property (`error: ACPError?`). The generator fails loudly when a payload member is required, a payload member collides with a base property, or the enum name collides with a definition name. Existing families are not changed: before, a pinned member that is also a base property always failed `validateUnclaimed`.'
  timestamp: 2026-10-09T15:07:15.175761+00:00
- actor: claude-code
  id: 01m4gm885bf86payg80www6q6s
  text: |-
    Implementation landed (not committed; task stays in doing).

    What changed:
    - Vendored `schema-v2.0.0-alpha.8` (all four assets; SHA-256 agrees with the release digests). Schema/README.md table and the unstable-document section are updated.
    - Generator: new family `objectPropertyEnum` (SchemaModel.swift, SchemaGenerator.swift). Output: top-level `StopReason` enum with `.error`, and `IdleStateUpdate { error: ACPError?, stopReason: StopReason?, meta }`. Unions are now put in name order with `NamedDeclaration`/`inNameOrder` (a duplicate name fails loudly). `referencedDefinition` and `inEmissionOrder` are extracted and shared.
    - GeneratorConfig.acpV2: patch fields for the stable `CompactionUpdate`. The `acpV2Unstable` config and `SchemaSet.acpV2Unstable` are removed (option A); `Unstable.*` compaction/notice generated files and `.Unstable.schema-hash` are deleted.
    - Hand-written: SessionEntry and SessionMergeEngine use the stable types and the new `SessionUpdate` cases; `UnstableSessionUpdate.swift` is deleted; PendingPromptCorrelator switch has the three new cases.
    - Tests: new PropertyEnumUnionTests (10) and IdleErrorRoundTripTests (4, the card's round trip); unstable tests moved to stable types; VendoredSchemaTests inventories and counts updated, plus tests for the CompactionUpdate patch fields and the IdleStateUpdate shape.

    Upstream contract changes found (tests follow the schema):
    - alpha.8 removed `x-deserialize-default-on-error` / `x-deserialize-skip-invalid-items` from `AuthMethodTerminal.args`/`env` and from two arrays of New/ResumeSessionRequest, and `x-deserialize-default-on-error` from `ResumeSessionRequest.replayFrom`. A malformed `args` is a decode error now; the two TaggedUnionRoundTripTests are changed to say so.
    - A malformed `compaction_update`/`notice` payload is now a decode error of the notification, the same as each other stable variant (before, the merge engine kept it as an unknown entry). Task ^2jmpa1s (log a known session/update variant that does not decode) covers this area.
    - AnyOfUnionTests: the tagged-payload shape that pins a base property is now the property-enum shape; it still fails loudly, now with "flattened payload Alpha requires x". Classification needs each variant to hold only the pinned property, so the value-union collision case keeps its old error.

    Process note: one rename used `sed -i` on CompactionNoticeRoundTripTests.swift (`Unstable.` prefix removal); all other edits used the edit tool.
  timestamp: 2026-10-09T15:24:35.371027+00:00
- actor: claude-code
  id: 01m4gm8d9r9hx8r7sn9a1hyjw6
  text: |-
    ### implement — changed
    - evidence: `swift build --build-tests` 0 warnings; `swift test` 445 tests/44 suites + 135 tests/17 suites passed; `swift test --package-path IntegrationTests` 7 passed; CI codegen gate (stamps removed, `generate-acp`, `diff -r`) clean; `swift package generate-documentation --target FoundationModelsACP --warnings-as-errors` clean. Files: Schema/acp-v2.json, Schema/acp-v2.unstable.json, Schema/README.md, Sources/ACPGenerateCore/{GeneratorConfig,SchemaGenerator,SchemaModel,SchemaSet}.swift, Sources/FoundationModelsACP/Generated/* (regenerated; Unstable.* deleted), Sources/FoundationModelsACP/Session/{PendingPromptCorrelator,SessionEntry,SessionMergeEngine}.swift, UnstableSessionUpdate.swift deleted, Connection/Client.swift (doc), Tests/ACPGenerateTests/{PropertyEnumUnionTests (new),AnyOfUnionTests,UnstableVendoredSchemaTests,VendoredSchemaTests}.swift, Tests/FoundationModelsACPTests/{IdleErrorRoundTripTests (new),CompactionNoticeSessionUpdateTests (moved),CompactionNoticeRoundTripTests (moved),SessionMergeEngineCompactionTests,SessionMergeEngineTests,TaggedUnionRoundTripTests,PromptLifecycleTests,AgentProtocolTests,PermissionRequestTests,ThirdPartyInterop}.swift
    - next: /review
  timestamp: 2026-10-09T15:24:40.632426+00:00
- actor: claude-code
  id: 01m4gmf9mps4wswbtsvt6s0hz0
  text: |-
    ### test — green
    - evidence: swift test (root) 445 tests in 44 suites + 135 tests in 17 suites passed, 0 failed; swift test (IntegrationTests) 7 tests passed; clean rebuild of both packages: 0 warnings, 0 errors; no skip markers.
    - next: commit, then review.
  timestamp: 2026-10-09T15:28:26.262986+00:00
position_column: doing
position_ordinal: '80'
title: Re-vendor the v2 schema to get the error stop reason and the idle error object
---
## Problem

The prompt-lifecycle spec (https://agentclientprotocol.com/protocol/v2/prompt-lifecycle) has `stopReason: "error"` and an `error` object (`code`, `message`, optional `data`) on the idle `state_update`. The vendored schema is `schema-v2.0.0-alpha.7` (`Schema/README.md:8`). It does not have these items:

- `StopReason` has no `error` case (`Generated/Unions2.generated.swift:697-730`).
- `IdleStateUpdate` has only `stopReason` and `_meta` (`Generated/Models4.generated.swift:377-427`). The decoder drops a received `error` member without a log (`Models4.generated.swift:411-415`). A proxy loses it.

## Work

1. Find the newest `schema-v2.*` tag that has the `error` stop reason and the idle `error` object. If no tag has them, stop and report.
2. Vendor the schema and the meta manifests. Run `swift package generate-acp`. Follow `CONTRIBUTING.md`.
3. Fix the hand-written code and the tests that the regenerated types break.
4. Add a round-trip test: an idle update with `stopReason: "error"` and `error {code, message, data}` decodes and encodes with no data loss.

## Acceptance

- `StopReason.error` exists, and `IdleStateUpdate` has a typed `error` field.
- The CI codegen diff gate passes.
- All tests pass.

#acp-lifecycle