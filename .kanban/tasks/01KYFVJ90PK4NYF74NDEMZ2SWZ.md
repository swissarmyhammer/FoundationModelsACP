---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kyfxvq5z7px5nsdhmjf58tk5
  text: |-
    M1 touched the code item 1 describes, so here is what moved and what did not.

    **Item 1 is still open and still accurate.** `classifyOneOf` still has no fallback guard, and a `const`-pinning `not` variant still survives `unionVariants(of:)` and reaches `discriminatorTag`. The doc comment on `isUnknownFallbackVariant` still carries the warning, reworded.

    What changed around it: `isUnknownFallbackVariant` lost its `pinned:` parameter and is now just "has a `not` and pins no `const` of its own", because a fallback that carries payload no longer cares what the catch-all declares. One side effect on the `oneOf` path — a *payload-bearing* catch-all on a `oneOf` is now filtered out rather than modeled, which is the same treatment `anyOf` gives it. The `const`-pinning case, which is the one item 1 is about, is unaffected.

    **Item 3's premise moved.** M1 rewrote large parts of `SchemaGenerator.swift` and `Emitter.swift`, so `git log -L` on the lines round 5 cited will now point at the M1 commit rather than at `c82ca85` and friends. Re-run the review rather than working from the old finding list; some of those lines no longer exist. `objectValueUnionDeclaration` and the new `objectTaggedUnionDeclaration` were already deduplicated onto a shared `objectCarryingAUnion`, and the three struct-part helpers now take `base:union:` instead of one model type.
  timestamp: 2026-07-26T19:19:05.151931+00:00
position_column: todo
position_ordinal: 8a80
title: Generator follow-ups deferred during M0
---
## Why this card exists

Three items were deliberately deferred across M0's review rounds 3–5 as out of scope for that task. Each was a correct call at the time — M0's remit was vendor, re-point, verify — but they were left unowned with no card, which is how work quietly disappears. Nothing here blocks any milestone; pick it up when `SchemaGenerator.swift` is open for real work anyway.

## 1. `classifyOneOf` has no unknown-fallback guard

`classifyAnyOf` filters `not`-guarded catch-all variants and defers the whole definition to raw JSON when a catch-all carries payload or pins a tag. `classifyOneOf` does none of that: its body is empty-guard → all-`string` → `.stringEnum`, all-`object` → `.taggedUnion`, else throw.

So on a `oneOf`, a `const`-pinning `not` variant survives `unionVariants(of:)` (the predicate short-circuits on `!hasConstDiscriminator`) and reaches `discriminatorTag`, yielding either an extra enum case or a thrown `unsupportedShape`.

**Unreached today** — the vendored `schema-v2.0.0-alpha.2` contains zero `"oneOf"` occurrences at any depth across all three artifacts, verified over 146 definitions. It becomes live the moment a re-vendor introduces one, and v2 is a draft that is already moving. The comment on `isUnknownFallbackVariant` documents the gap and says to add the guard before relying on the behaviour.

## 2. Pin the consolidated `GeneratorError` detail strings

Round 3 consolidated three duplicated validation-failure messages onto single paths in `SchemaGenerator.swift`. Round 4 verified the dedup preserved behaviour exactly (compared as boolean predicates; one case was strictly tightened). But no test pins the resulting detail strings, so a future edit can silently change what a generation failure says. Round 4 declined this as new test surface outside its ten-finding scope, correctly, and recommended it as follow-up.

## 3. Tidy-up pass over `SchemaGenerator.swift`

Round 5's review engine produced ten findings — generic extract-a-helper and name-a-constant suggestions. All ten were dropped as out of scope because `git log -L` places every cited line on `c82ca85`, `d8ce673`, `4945073`, `b575541`, or `11f4c06`, none of which are in the reviewed range. Rounds 3 and 5 both set that precedent.

They are legitimate quality suggestions on a file that is now ~2,000 lines and carries the whole schema→Swift pipeline. The reason to batch them rather than take them piecemeal: this file's output is pinned byte-for-byte by the CI codegen diff gate, so any change must regenerate clean, and mixing cosmetic churn into a behaviour commit makes that gate harder to read.

## Acceptance Criteria

- [ ] `classifyOneOf` either gains the fallback guard `classifyAnyOf` has, or carries a comment explaining why the asymmetry is correct.
- [ ] Generation-failure detail strings are pinned by test.
- [ ] The tidy-up is applied as its own commit, with `swift package generate-acp` producing byte-identical output and the CI gate green.

## Tests

- [ ] A synthetic `oneOf` with a `const`-pinning `not` variant behaves as documented — deferred, or loudly rejected, not silently mismodelled.
- [ ] Each consolidated validation failure asserts its detail string.
- [ ] `swift test` green and `git diff` on `Sources/FoundationModelsACP/Generated` empty after regeneration.
