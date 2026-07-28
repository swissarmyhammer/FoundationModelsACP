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
- actor: claude-code
  id: 01kyg3vp97mhyd51qvfme58cxd
  text: |
    ## Two more items surfaced during M1, same character as the three above

    Both were deliberately kept out of `c9810f3` to avoid widening a commit whose generated output is pinned byte-for-byte. Neither blocks anything.

    - **Five surviving typealiases carry a stale generated banner.** `Unresolved.generated.swift`'s remaining eight are `AgentResponse`, `ClientResponse`, `EmbeddedResourceResource`, `ExtNotification`, `ExtRequest`, `ExtResponse`, `RequestID`, `SessionConfigSelectOptions` — row 5 of `plan.md`'s table, now classified as **permanently** deferred (three are the extension escape hatch with no declared shape; five are untagged unions whose branches pin no discriminator). But five still emit the banner "Placeholder seam: ... until a later generator stage replaces it," which reads as pending work. The text comes from the emitter, so correcting it is a generator change plus a regeneration, and the generated docs currently contradict the plan.

    - **Possibly dead test helpers.** `assertRoundTrips` and `canonicalized` in `Tests/ACPGenerateTests/TaggedUnionTests.swift` were reported as uncalled. The report came from a review engine whose line numbers were stale elsewhere in the same run, so **verify before deleting** rather than trusting it. If genuinely uncalled they are a trivial sweep; the file is pre-existing and was outside M1's scope, which is why it was not touched.

    ## Also worth folding in when this card is picked up

    Three findings from M1's closing review target repeated literals in `Models.generated.swift` (real locations 1607/1636 and 4659/4679, not the line numbers the engine reported). The engine's premise is drift between parallel decode and encode lists, and that premise is wrong: both sides are emitted from a single helper, `ownedMembers(discriminator:siblingMembers:)` in `Emitter.swift`, inlined twice. There is one source of truth and no drift is possible. Recorded here as considered-and-declined rather than pending, so nobody re-raises it as new.
  timestamp: 2026-07-26T21:03:55.687556+00:00
- actor: claude-code
  id: 01kykbb1xa5v1xrv6j30jakk76
  text: |-
    Implementation landed in three commits:

    - 97b7b65 — classifyOneOf now mirrors classifyAnyOf's fallback guard: a not-guarded oneOf variant that also pins its own const now defers the whole definition (.deferredUnion) instead of surviving unionVariants(of:) unfiltered and reaching discriminatorTag as a mismodeled extra case. Verified RED->GREEN by temporarily reverting the guard: without it, the synthetic test schema produced an actual enum with a spurious Tag.b case (the exact "silently mismodelled" failure mode the task described) instead of deferring. Added tests pinning the exact GeneratorError.unsupportedShape detail strings for the three validation-failure mechanisms consolidated during an earlier M0 round: emptyUnionDetail (shared by classifyOneOf, taggedUnionModel, objectValueUnionModel), discriminatorDisagreement (shared by agreedDiscriminator and valueUnionDiscriminator), and flattenedPayloadType (shared by taggedUnionModel and discriminatedPayloadType/discriminatedUnionModel) — each exercised from two distinct call sites via synthetic schemas to prove no drift. Also removed assertRoundTrips/canonicalized from TaggedUnionTests.swift after verifying via grep they were genuinely unused (dead code), and fixed a stray orphaned doc-comment fragment on TaggedUnionEmissionTests.

    - c188da1 — regenerated Unresolved.generated.swift to pick up a corrected placeholder banner. The generator's deferredUnionReason(keyword:fragment:) now composes the banner from the definition's own variants: the five anyOf-deferred typealiases (AgentResponse, ClientResponse, EmbeddedResourceResource, RequestID, SessionConfigSelectOptions) now read "Permanently deferred: no variant of this anyOf union pins a discriminator..." instead of the misleading "Placeholder seam: ... until a later generator stage replaces it." Confirmed via git diff --stat that only Unresolved.generated.swift changed (5 lines) — the other four generated files regenerated byte-identical.

    - 3e41631 — tidy-up pass on SchemaGenerator.swift, re-derived from a fresh review-engine run against the current file (per the warning that M0's old line-numbered findings are stale post-M1). Extracted fallbacksAreGenuineCatchAlls(of:) to deduplicate the near-identical fallback guard my own classifyOneOf fix had just introduced alongside classifyAnyOf's pre-existing one. Added objectTypeName/nullTypeName constants replacing repeated free-standing "object"/"null" literals (matching the file's existing ...Key constant pattern). Also reworded emptyUnionDetail from "empty oneOf" to keyword-neutral "empty union" since the same constant is thrown from anyOf-reached call sites too, where "empty oneOf" was factually wrong — a narrow correctness fix bundled into this commit since it doesn't touch Sources/FoundationModelsACP/Generated at all (verified via empty regen diff). Declined the review engine's "string"/"integer" literal-duplication findings after inspection: those literals appear only as independent dictionary keys in two unrelated lookup tables (enumRawKinds vs scalarTypes), not real logic duplication. Also declined two generic "extract a helper, function is complex" findings as unbacked by genuine duplication, consistent with how M0 rounds 3 and 5 handled the same category of finding for this file.

    Verified: swift build --build-tests clean (0 warnings), swift test 268 tests / 26 suites / 0 failures (up from the 260/25 baseline), and swift package generate-acp regeneration diffs empty against Sources/FoundationModelsACP/Generated after each commit. Double-check adversarial review spawned; verdict pending.

    Left in `doing` per the /implement process, pending the double-check verdict and then /review.
  timestamp: 2026-07-28T03:12:22.442324+00:00
- actor: claude-code
  id: 01kykbn3jzre6dwz55azqqm389
  text: |-
    Double-check adversarial review: PASS, no findings.

    The reviewer independently hand-traced all three items against the production code (not just the tests' own claims):

    - classifyOneOf: confirmed by tracing the pre-fix code path that the "Ambiguous" test schema would have silently produced an extra enum case without the guard, and confirmed both the guard and its doc comments are correct. Confirmed zero `oneOf` occurrences in Schema/acp-v2.json (still unreached, as documented).
    - The 6 GeneratorError detail-string tests: hand-traced each synthetic schema through the actual production call path (classifyOneOf, taggedUnionModel, objectValueUnionModel, agreedDiscriminator/discriminatorDisagreement, valueUnionDiscriminator/pinnedDiscriminators, flattenedPayloadType/discriminatedPayloadType/discriminatedUnionModel) and confirmed every asserted context/detail string, including the sort-order-sensitive ones, matches what the code actually produces.
    - Tidy-up commit 3e41631: confirmed via callgraph/grep that taggedUnionModel really is reachable from anyOf-classified unions too, so the emptyUnionDetail wording fix ("empty oneOf" -> "empty union") is a real, disclosed correctness fix rather than scope creep, and confirmed it belongs in this commit since it never touches Sources/FoundationModelsACP/Generated. Independently reran swift build --build-tests and swift test fresh (268/26, 0 failures) and confirmed VendoredSchemaTests.checkedInOutputMatchesAFreshRun passes, which byte-compares the checked-in generated files against a fresh in-memory regeneration.
    - M1 sanity checks: confirmed all five permanently-deferred typealiases (AgentResponse, ClientResponse, EmbeddedResourceResource, RequestID, SessionConfigSelectOptions) genuinely have no anyOf variant pinning a discriminator const in Schema/acp-v2.json, and confirmed assertRoundTrips/canonicalized had zero references anywhere in the tree both before and after removal.

    Final state: 268 tests / 26 suites / 0 failures / 0 warnings (up from the 260/25 baseline). Three commits (97b7b65, c188da1, 3e41631) on v2-reset. All three original task items and both M1-surfaced follow-ups are complete. Leaving in `doing` for `/review` per the /implement process.
  timestamp: 2026-07-28T03:17:51.839678+00:00
position_column: doing
position_ordinal: '80'
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
