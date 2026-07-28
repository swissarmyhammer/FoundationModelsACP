---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kyme3q7yykc0dxndxeqgzmy1
  text: |-
    Implemented the fix and a regression test via TDD.

    Fix: added `guard !modeled.isEmpty else { throw GeneratorError.unsupportedShape(context: name, detail: Self.emptyUnionDetail) }` in classifyAnyOf's object branch, right after computing `modeled`, mirroring the `!modeled.isEmpty` guard already present a few lines lower in the `.taggedUnion` branch. Reuses the shared `emptyUnionDetail` constant ("empty union") rather than inventing a new string, since the acceptance criteria specifically wanted the same final error text, just thrown more directly. Updated `emptyUnionDetail`'s doc comment and `classifyAnyOf`'s own doc comment to name this as a fourth shared call site.

    Test: added `objectAnyOfWhoseOnlyVariantIsTheUnknownFallbackFailsAtClassification` to AnyOfUnionTests.swift. Key design note for future readers: a plain "object anyOf with only a not-guarded catch-all" schema does NOT discriminate fixed-vs-unfixed behavior at the generate() level, because the vacuous-truth bug (returning .objectTaggedUnion) still ends up throwing the identical GeneratorError.unsupportedShape(context:, detail: "empty union") via objectTaggedUnionModel -> taggedUnionModel's own filtered-to-empty guard - exactly as the task description says ("fails safe today, same error text"). So the test schema deliberately also gives the base object an extra required property `corrupt` with an invalid `"type": 1`, which is harmless if the classification-site guard fires first (as it does post-fix) but throws a misleading `unhandled type` error if objectTaggedUnionModel's structModel runs first (pre-fix path). This makes the test genuinely load-bearing.

    Mutation-tested manually: reverted the new guard, ran `swift test --filter` on the new test, confirmed it failed with exactly the misleading `unhandled type Optional(FoundationModelsACP.JSONValue.number(1.0))` error (not "any error" and not silently passing) - proving the guard is load-bearing for the compound schema. Restored the guard, re-ran, confirmed green again.

    Verification: `swift build` succeeds. `swift test` green: 293 tests (198 + 95) across 28 suites, 0 failures, 0 warnings (baseline was 292; +1 for the new test). `swift package --allow-writing-to-package-directory generate-acp` reports "nothing regenerated" (byte-identical against vendored schema, hash unchanged) - confirms this fix is behavior-preserving for all schemas currently in the vendored artifacts.

    Spawned an adversarial double-check agent per the really-done gate; awaiting its verdict before final handoff.
  timestamp: 2026-07-28T13:20:02.302132+00:00
- actor: claude-code
  id: 01kymedz8qsbwxcy67cayetcdn
  text: |-
    Adversarial double-check PASSED. Findings: (1) guard placement correct, no behavior change for schemas with >=1 real payload variant - confirmed by full AnyOfUnionTests suite pass including objectValueUnionClassifiesAndEmits and objectCarryingATaggedPayloadUnionEmitsANestedPayload; (2) test schema well-formed and genuinely exercises the intended dispatch-order divergence; (3) test comment accurate; (4) informational-only finding that classifyOneOf has the same latent gap (unconditionally returns .taggedUnion without checking a modeled-equivalent non-empty, relying on taggedUnionModel's downstream throw) - correctly out of scope for this task, filed as follow-up task 01KYMED438PSP949389RJRCGD7 (^rjrcgd7); (5) minor wording nit (called an `if` condition a "guard below") - fixed, now says "condition below".

    Final verification (all fresh, this session): `swift build` succeeds. `swift test`: 293 tests (198 + 95) across 28 suites, 0 failures, 0 warnings (baseline 292 + 1 new test). `swift package --allow-writing-to-package-directory generate-acp`: "nothing regenerated", schema hash unchanged, zero diff in Sources/FoundationModelsACP/Generated - byte-identical regeneration confirmed.

    Diff: Sources/ACPGenerateCore/SchemaGenerator.swift (+26/-5: the guard, its inline comment, and two doc-comment updates), Tests/ACPGenerateTests/AnyOfUnionTests.swift (+56: the new regression test).

    Task left in `doing` per the /implement skill contract - ready for /review.
  timestamp: 2026-07-28T13:25:38.199237+00:00
position_column: doing
position_ordinal: '80'
title: classifyAnyOf's object-branch has a vacuous-truth gap symmetric to the empty-anyOf fix
---
## Why this card exists

Surfaced by the adversarial double-check on task 01KYFVJ90PK4NYF74NDEMZ2SWZ (^emz2swz), which added an empty-`variants` guard to the top of `classifyAnyOf` in `Sources/ACPGenerateCore/SchemaGenerator.swift`. That fix closed one vacuous-truth hazard (an empty `anyOf` silently succeeding instead of throwing). The double-check found a sibling instance of the same pattern one branch lower, deliberately left alone as out of scope for that task.

## The gap

Inside `classifyAnyOf`, after the (now-guaranteed non-empty) top-level guard:

```swift
let modeled = variants.filter { $0[Self.notKey] == nil }
if members[Self.typeKey]?.stringValue == Self.objectTypeName, members[Self.propertiesKey] != nil {
    if modeled.allSatisfy({ $0[Self.allOfKey] != nil }) {
        return .objectTaggedUnion
    }
    ...
```

`modeled` can be empty even though `variants` is not — this happens whenever every variant in an object-typed `anyOf` is `not`-guarded (all genuine catch-alls, per `fallbacksAreGenuineCatchAlls`). `modeled.allSatisfy({ $0[Self.allOfKey] != nil })` over an empty array is vacuously `true`, so classification returns `.objectTaggedUnion` for a union with no real payload variant at all.

The sibling branch a few lines lower already guards against exactly this:

```swift
if modeled.count < variants.count, !modeled.isEmpty, modeled.allSatisfy(hasConstDiscriminator) {
    return .taggedUnion
}
```

The `!modeled.isEmpty` there makes the omission in the object-branch above look like an oversight rather than a deliberate asymmetry.

## Why this is not urgent

It fails safe today: `objectTaggedUnionModel` → `taggedUnionModel` re-derives its variant list via `unionVariants(of:)` (which independently filters unknown-fallback variants) and throws `GeneratorError.unsupportedShape(detail: emptyUnionDetail)` when the resulting case list is empty — the same error text, just reached via a more indirect path with a less proximate cause. It is also unreached by the current vendored schema (`Schema/acp-v2.json` and both meta variants contain zero object-typed `anyOf` definitions where every variant is `not`-guarded), verified structurally as part of the double-check.

## Acceptance criteria

- [ ] Add `!modeled.isEmpty` (or equivalent) to the object-branch condition in `classifyAnyOf`, for symmetry with the guard already present in the `.taggedUnion` branch below it, so the failure is thrown at the classification site with a clear proximate cause instead of relying on a downstream re-derivation to catch it.
- [ ] A synthetic-schema test pins the resulting behavior (throws `GeneratorError.unsupportedShape` with a clear detail, not a silent `.objectTaggedUnion` misclassification).
- [ ] `swift test` green, `swift package generate-acp` byte-identical regeneration.