---
assignees:
- claude-code
position_column: todo
position_ordinal: 8d80
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