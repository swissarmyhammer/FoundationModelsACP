---
assignees:
- claude-code
position_column: todo
position_ordinal: 8f80
title: classifyOneOf has the same latent vacuous-classification gap classifyAnyOf's object-branch fix just closed
---
## Why this card exists

Surfaced by the adversarial double-check on task 01KYKCX3XZWEP3PZ77826RC4A5 (^26rc4a5), which added a `!modeled.isEmpty` guard to `classifyAnyOf`'s object branch so an object-typed `anyOf` whose variants are all `not`-guarded catch-alls throws directly at the classification site instead of relying on a downstream re-derivation to catch it.

## The gap

`classifyOneOf` (in `Sources/ACPGenerateCore/SchemaGenerator.swift`) has the same shape, once `fallbacksAreGenuineCatchAlls` passes:

```swift
guard fallbacksAreGenuineCatchAlls(of: variants) else {
    return .deferredUnion(keyword: Self.oneOfKey)
}
return .taggedUnion
```

It unconditionally returns `.taggedUnion` without ever checking whether a `modeled`-equivalent (payload-bearing) subset is non-empty. If every variant of a `oneOf` were a genuine `not`-guarded catch-all, classification would still return `.taggedUnion`, and only `taggedUnionModel`'s own `guard let discriminator else { throw ... }` would catch it downstream — the exact "reached less directly" pattern the sibling task just closed for `anyOf`'s object branch.

This is already covered today by an *existing* test — `TaggedUnionTests.oneOfWhoseOnlyVariantIsTheUnknownFallbackFailsOnTheEmptyUnionDetail` — which pins the downstream throw. So this is not urgent and not silently broken; it is the same directness/proximate-cause improvement, not yet applied to `classifyOneOf`.

## Suggested fix

Mirror `classifyAnyOf`'s object-branch fix: compute the modeled (non-`not`-guarded) variant set in `classifyOneOf` and guard on `!modeled.isEmpty` before returning `.taggedUnion`, throwing `GeneratorError.unsupportedShape(context: name, detail: Self.emptyUnionDetail)` directly when empty.

## Acceptance criteria

- [ ] `classifyOneOf` throws `GeneratorError.unsupportedShape(detail: emptyUnionDetail)` directly when every `oneOf` variant is a genuine catch-all, rather than relying on `taggedUnionModel`'s downstream re-derivation.
- [ ] Existing test `TaggedUnionTests.oneOfWhoseOnlyVariantIsTheUnknownFallbackFailsOnTheEmptyUnionDetail` still passes (same final error, now thrown more directly) — consider adding a compound-schema regression test analogous to `AnyOfUnionTests.objectAnyOfWhoseOnlyVariantIsTheUnknownFallbackFailsAtClassification`, which uses a deliberately-broken sibling property to make the fix's directness observable/load-bearing rather than a no-op pinning test.
- [ ] `swift test` green, `swift package generate-acp` byte-identical regeneration.