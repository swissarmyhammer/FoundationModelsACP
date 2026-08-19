---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0d01xc48dwxge68v7dnggtt
  text: |-
    Research complete. Findings:

    - `classifyObjectTypedAnyOf` (SchemaGenerator.swift) returns `.objectTaggedUnion` when all modeled variants have `allOf`. The scope variants have no `const` discriminator, thus `discriminatorTag` throws.
    - Plan: add a `DefinitionKind.objectScopeUnion` case. In `classifyObjectTypedAnyOf`, when all variants have `allOf` and no variant has a `const` discriminator, return the new case. All other paths do not change.
    - Model: add `ObjectScopeUnionModel` and `ScopeUnionCaseModel` to SchemaModel.swift. The model holds the base struct, the fixed property name `scope`, the fixed enum name `Scope`, and one case for each variant. Each case holds the case name (from `title`), the payload type (from the `$ref`), and the required keys of the referenced definition.
    - The model builder reads the referenced definition from the schema `$defs` to get its `required` keys. It makes sure the key sets are disjoint. Keys that are not disjoint cause `GeneratorError.unsupportedShape`. An empty `required` list also causes `GeneratorError.unsupportedShape`, because decode cannot select the variant.
    - Emission: reuse `Emitter.objectCarryingAUnion` with a new nested `Scope` enum. Decode probes `container.contains(.key)` in schema order. Encode calls `payload.encode(to: encoder)`, thus the wire object has no nested `scope` key.
    - Refactor for reuse: split `flattenedPayloadType` into a reference extractor plus `referencedTypeName`, so the scope path can read the raw definition name without a copy of the `allOf` guard.
    - Tests go in Tests/ACPGenerateTests/FlattenedScopeUnionTests.swift with swift-testing `@Test`/`#expect`, synthetic schemas, and `GeneratorConfig()` (not `.acpV2`), the same style as AnyOfUnionTests.swift.
  timestamp: 2026-08-19T12:31:05.604184+00:00
- actor: claude-code
  id: 01m0d0y8kqcbhnzg8byvg175kv
  text: |-
    Implementation complete. TDD was used for each production change: each test failed first, and then the code made it pass.

    Scope-union feature (the card's primary work):
    - SchemaModel.swift: new `DefinitionKind.objectScopeUnion`, `ScopeUnionCaseModel`, `ObjectScopeUnionModel`.
    - SchemaGenerator.swift: `classifyObjectTypedAnyOf` splits on the absence of a `const` discriminator; `objectScopeUnionModel` reads each variant's `$ref`, gets the referenced definition's `required` keys, and makes sure the key sets are disjoint and not empty; refactor split `flattenedPayloadReference` and `referencedDefinitionName` out of the existing helpers for reuse.
    - Emitter.swift: `objectScopeUnionDeclaration` reuses `objectCarryingAUnion`; the nested `Scope` enum decodes by `container.contains(.key)` probes in schema order and encodes with `payload.encode(to: encoder)`, thus the wire object has no nested `scope` key.
    - Tests/ACPGenerateTests/FlattenedScopeUnionTests.swift: positive emission test, non-disjoint negative test (exact `unsupportedShape` detail), empty-required negative test.

    Discovered work — the new schema snapshot exposed three more generator gaps. Acceptance criterion 1 (generate-acp exits 0) and the test gate made them part of this card:
    1. `StringFormat` pins the const `date-time`. `swiftCaseName(fromWire:)` now also splits on a hyphen. A new `swiftMemberName(fromWire:)` keeps the old rule (no hyphen) for names the emitter writes as `CodingKeys` cases (discriminators, value members, scope probe keys), so `AnyOfUnionTests.aValueMemberThatIsNotAnIdentifierFailsLoudly` stays correct. Test: UnknownFallbackTests.kebabCaseWireValueMapsToACamelCaseCase.
    2. The elicitation schemas declare `default` and `enum` members. `swiftName(forWireName:)` now puts backticks around a Swift keyword. Test: GeneratorCoreTests.keywordPropertyNamesAreBacktickedInEmittedSource.
    3. `ElicitationSchema.type` has the string default `"object"` on an enum-typed field. `defaultExpressionParts` now renders a string default on a non-String field through `Type(wireValue:)`. Test: GeneratorCoreTests.stringDefaultOnAnEnumTypedFieldRendersThroughWireValueInit.

    Vendored pins: `generate-acp` was run (exit 0, 6 files regenerated, stable on a second run: "up to date"). VendoredSchemaTests pins were updated to the new vendored surface: tagged/scalar union inventories (+ElicitationPropertySchema, +MultiSelectItems, +ElicitationSchemaType, +StringFormat), Payload nesting (+CreateElicitationRequest), a new Scope-nesting pin, the unresolved list (+CreateElicitationResponse, +ElicitationContentValue), the stable routing table (+elicitation/create, +elicitation/complete as stable client methods), the unstable table (-the two elicitation entries), and the per-file declaration counts (13/2/120/27/10). Note for the follow-up task ^2g9jejv: its "update VendoredSchemaTests expected mappings" step is now already done; the regenerated `Sources/FoundationModelsACP/Generated/` diff is in the working tree, not committed.

    Result: `swift test --filter ACPGenerateTests` — 101 tests in 13 suites, all pass, zero warnings in the changed code. The full suite was not run, per the dispatch instructions.
  timestamp: 2026-08-19T12:46:34.615274+00:00
- actor: claude-code
  id: 01m0d0yf8a2jbrcgq3esp7ayzc
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/ACPGenerateCore/SchemaModel.swift, Sources/ACPGenerateCore/SchemaGenerator.swift, Sources/ACPGenerateCore/Emitter.swift, Tests/ACPGenerateTests/FlattenedScopeUnionTests.swift (new), Tests/ACPGenerateTests/UnknownFallbackTests.swift, Tests/ACPGenerateTests/GeneratorCoreTests.swift, Tests/ACPGenerateTests/VendoredSchemaTests.swift; plus the regenerated Sources/FoundationModelsACP/Generated/ (6 files, uncommitted). `swift package --allow-writing-to-package-directory generate-acp` exits 0. `swift test --filter ACPGenerateTests`: 101 tests in 13 suites, all pass.
    - next: /review; then task ^2g9jejv (client surface wiring and commit of the regenerated diff).
  timestamp: 2026-08-19T12:46:41.418955+00:00
- actor: claude-code
  id: 01m0d122ezqnm1m10xjhz825d8
  text: |-
    ### test — red

    - Command: `swift test`. This is the full test suite. No filter was used.
    - ACPGenerateTests: 101 tests ran. All tests passed. There were no warnings.
    - FoundationModelsACPTests: 247 tests ran. 4 issues occurred. All 4 issues are in one test: `RoutingCoverageTests.everyClientMethodReachesExactlyItsOwnHandlerAndNoOther()`.
    - One cause makes all 4 issues occur. The regenerated file `MethodTable.generated.swift` now lists two new client methods. These are `elicitation/complete` (handler name `elicitationComplete`) and `elicitation/create` (handler name `createElicitation`). The `RoutingCoverageTests` test has no driver case for these handler names. The `Client` protocol in `Sources/FoundationModelsACP/Connection/` has no method for these handlers. The test reports "no driver wired for client handler" and "reached [] instead" for both methods.
    - This work is reserved for task ^2g9jejv. That task will add the elicitation methods to the `Client` protocol. The task instructions say to not do this work here. I made no code change to fix this.
    - No other test failed. No build warning occurred.
    - Result: red. The task is blocked. Task ^2g9jejv must add the elicitation methods to the `Client` protocol and the test drivers before this test can pass.
  timestamp: 2026-08-19T12:48:39.391552+00:00
- actor: claude-code
  id: 01m0d14abg67myx5zfyaf0h824
  text: |-
    ### finish iteration 1 — red
    - implement: changed — 7 files plus 6 regenerated files
    - test: red — swift test; ACPGenerateTests 101/101 pass; RoutingCoverageTests.everyClientMethodReachesExactlyItsOwnHandlerAndNoOther has 4 issues (no handler for elicitationCreate / elicitationComplete)
    - commit: none — the tree is not green
    - decision: the red tests need the wiring that task ^2g9jejv owns. The freshness test RoutingTableTests compares the checked-in MethodTable with a fresh generation, thus a revert of Generated/ is not possible. The two tasks become green only together. Next step: implement ^2g9jejv in the same tree, then test, then make one checkpoint commit for both.
  timestamp: 2026-08-19T12:49:53.008871+00:00
position_column: doing
position_ordinal: '80'
title: 'Generator: support flattened untagged scope union (Elicitation modes)'
---
# Generator: support flattened untagged scope union (Elicitation modes)

## What

The vendored ACP v2 schema now pins upstream commit `7a13081ae8cb2b93d02ea0c8b538c4f3a086768c`, which promotes elicitation to the stable client surface. The files in `Schema/` and `Schema/README.md` are already replaced in the working tree (not committed). The generator fails on the new snapshot:

```
acp-generate: unsupported schema shape at ElicitationFormMode variant 0: expected exactly one inline property (the discriminator)
```

Cause: `ElicitationFormMode` and `ElicitationUrlMode` in `Schema/acp-v2.json` have a shape the generator has not met before. Each is an object-typed definition with inline `properties` and `required`, plus a top-level `anyOf` whose variants are single-`$ref` `allOf` wrappers with **no** discriminator property (`ElicitationSessionScope`, `ElicitationRequestScope`). This is a flattened untagged union inside an object (serde `#[serde(flatten)]` on an untagged enum). In `Sources/ACPGenerateCore/SchemaGenerator.swift`, `classifyObjectTypedAnyOf` (line 663) sees that all modeled variants carry `allOf` and classifies the definition as `.objectTaggedUnion`; the tagged path then throws in `discriminatorTag(of:context:)` (line 944) because the variants have no inline discriminator property.

Implement, in `Sources/ACPGenerateCore/SchemaGenerator.swift` (and the emission/render code it feeds):

- A new emission model for this shape: a struct with the inline properties plus one `scope` property whose type is a new enum with one case for each `$ref` variant.
- Decode: select the variant by its required keys. The keys are disjoint: `sessionId` selects the session scope, `requestId` selects the request scope. Probe in schema order.
- Encode: flatten the members of the selected variant into the parent object. The wire object must not contain a nested `scope` key.
- Classify only this exact shape into the new model: object-typed, inline properties present, all modeled `anyOf` variants are single-`$ref` `allOf` wrappers without a `const` discriminator. Other shapes must keep their current classification (`classifyObjectTypedAnyOf` currently returns `.objectTaggedUnion` when all variants carry `allOf` — the new branch must split on the absence of a `const` discriminator).

Use synthetic schemas for tests in this task. Do not depend on the full vendored regeneration; that is the follow-up task.

## Acceptance Criteria

- [x] `swift package --allow-writing-to-package-directory generate-acp` exits with code 0 on the new vendored `Schema/acp-v2.json`.
- [x] The generated source declares `ElicitationFormMode` and `ElicitationUrlMode` as structs, each with a scope enum that has `session` and `request` cases.
- [x] A decoded value with `sessionId` selects the session case; a decoded value with `requestId` selects the request case.
- [x] An encoded value places the scope members at the top level of the object, with no nested `scope` key.
- [x] Definitions that matched existing classifications before this change still produce identical output.

## Tests

- [x] New file `Tests/ACPGenerateTests/FlattenedScopeUnionTests.swift`: feed `SchemaGenerator` a synthetic schema with the flattened-union shape; assert generation succeeds and the emitted source contains the struct, the scope enum, and the required-key decode probes.
- [x] Add a negative case: a variant set whose required keys are not disjoint must throw `GeneratorError.unsupportedShape`, not decode ambiguously.
- [x] Run `swift test --filter ACPGenerateTests` — all pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#elicitation