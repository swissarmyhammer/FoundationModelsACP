---
comments:
- actor: claude-code
  id: 01kyfgk4wseqepmwft0psc4ar4
  text: |-
    Corrected against the vendored `Schema/acp-v2.json` (`schema-v2.0.0-alpha.2`, vendored in M0) and the current tree.

    **The 1-based line-number invariant does not exist in v2.** The card asserted "**1-based line numbers.** Same treatment [as absolute paths]", with an acceptance criterion and a test demanding that 0-based line numbers fail decoding. Implementing that would **reject payloads v2 permits**. The schema has exactly one line-valued field, `ToolCallLocation.line`, typed `["integer","null"]` with `minimum: 0` and described only as *"Optional line number within the file."* No base is stated there or on the v2 tool-calls page.

    This is a **deliberate divergence from v1**, which did state 1-based — flagged as such in the description so it reads as a decision, not a lapse. The rule is inverted rather than deleted: the test now requires `line: 0` (and omitted, and `null`) to decode, and explicitly says the v1 "0 must fail" test must not be recreated.

    `wireInvariantFields` recorded as **empty by design**: v2 gives absolute paths a first-class `AbsolutePath` `$def`, so the invariant rides each field's `$ref` and a per-field override table would just be a drift-prone second copy of the schema. `GeneratorConfig.acpV2` documents this in place. The override mechanism stays for a future revision that states an invariant in prose alone.

    Other stale claims fixed, verified against the tree:
    - `Core/ProtocolVersion.swift` and `Core/ForgivingDecoding.swift` are **already restored** (M0 brought them back so the regenerated output would compile; `ProtocolVersion` now carries `.v2`). The card listed them as deleted and told the implementer to restore them "before anything else". The generated output compiles today; that opening step is gone.
    - `Core/LineNumber.swift` moved out of "rebuild" and into an explicit do-not-restore: the generator emits no reference to it, because there is no `.lineNumber` mapping and no v2 field to attach one to.
    - The rebuild list is now just `Core/ACP.swift` and `Connection/RequestError.swift`.
    - `ForgivingDecodingTests` stays in scope, but the parenthetical "deleted with `ForgivingDecoding.swift`" was corrected -- the file is back, the tests are not.

    Also added: a short *placeholder seam* section pointing at `plan.md` -> M1 for the four deferred union shapes. M2 (^fzv61ky), M5 (^ht1sh5g), and M7 (^4vnprpg) now each carry a "blocked on the M1 seam" note naming the surface it untypes for them, and those references would otherwise dangle. The full instructions are left in `plan.md` rather than duplicated here.
  timestamp: 2026-07-26T15:27:12.793759+00:00
- actor: claude-code
  id: 01kyfvpmv8mjbkxddskg7ty4a5
  text: |-
    ## Picked up after M0 closed — what carries over

    *(Restored. This comment's own warning about markdown tables fired on itself: the serializer wrapped the line carrying the literal separator row so that the three dashes landed at column zero, which split the YAML document, truncated this comment at that point, and left the card reading `title: Untitled` with its front matter stranded in the description body. Rewritten below with the separator described in prose instead of quoted. The text is otherwise the original.)*

    M0 is `done` (commits `ed220ab` → `e094323`, six on `v2-reset`, none pushed). `schema-v2.0.0-alpha.2` is vendored, the generator is re-pointed and taught v2's `anyOf` vocabulary, and the suite is at 64 tests / 9 suites green with the CI codegen diff gate restored and verified able to catch a hand-edit.

    **This card was already corrected against the vendored schema**, so read it as current. Two of its original instructions are now wrong and have been fixed: `ProtocolVersion` and `ForgivingDecoding` were listed as deleted with an instruction to restore them "before anything else" — M0 already restored both (`ProtocolVersion` carries `.v2`), and the generated output compiles today. And the "1-based line numbers, enforced at decode time" requirement is gone: the vendored schema has exactly one line-valued field, `ToolCallLocation.line`, described only as "Optional line number within the file" **with `minimum: 0`**. It explicitly permits zero. Enforcing 1-based would reject payloads v2 allows. That is a deliberate divergence from v1, which did state 1-based.

    ### The real work: close the placeholder seam

    Four definitions defer to `JSONValue` today, in two shapes that fail in opposite directions — `plan.md` → *Starting point* has the full table with the API surface each one untypes. **Take `SetSessionConfigOptionRequest` first.** It is the cheapest and the most expensive to leave: the only deferral that untypes a *routed stable method's entire params object*, so M2 would otherwise generate `setSessionConfigOption(_ params: JSONValue)`. `plan.md` → M1 carries the three-step recipe, and step 3 matters — skipping it makes generation *throw* rather than emit.

    Then the three tagged unions (`AuthMethod`, `PlanUpdateContent`, `ReplayFrom`), which need `unknown(String, JSONValue)` so the fallback can carry the payload it currently drops.

    **Write the round-trip test in the same change, not after.** An unexercised two-associated-value `Codable` case is exactly the "preservation asserted rather than real" failure this milestone exists to close. The harness already exists — `ACPGenerateTests` depends on `ACPGenerateCore`, which depends on `FoundationModelsACP`, so the generated module is already linked into the test binary and the test costs one `import`. An earlier agent claimed this was untestable, checked, and withdrew the claim.

    **Completion signal:** resolving rows 1–4 makes **eight** structs reachable that nothing references today. Six JSON-RPC envelope types will never be reached by any row and must be excluded from the signal. Verify the enumeration yourself — this count has been wrong twice.

    ### Traps that have already cost time

    - **Never run `swift format`.** No config exists; it reformats the whole 4-space codebase to 2-space including the checked-in generated output the CI gate pins byte-for-byte. Four agents have hit this and had to revert wholesale.
    - **Never put a markdown table in a kanban comment.** A table's separator row — the one made of dashes between pipes — parses as a YAML document delimiter and corrupts the task record. That is not hypothetical: it is what happened to this comment. Bullet lists only. Tables in `plan.md` are fine.
    - **Watch for stale git worktrees under `.claude/worktrees/`.** One was silently intercepting `files` reads and edits while `grep files` on the same absolute path returned `HEAD` — an agent editing through it would have written to a detached tree and watched the change vanish. Cleared, but check `git worktree list` if edits behave strangely.
    - **The hash stamp hides generator changes.** `rm Sources/FoundationModelsACP/Generated/.schema-hash` to force a run.

    ### On claims

    Four confident exhaustiveness claims failed during M0 — the orphan triage, "the only union stage with this defect", "zero `$ref`s anywhere", and "seven read sites". Every one passed its own internal check while being wrong. If you state a count or an "only", derive it and say how.
- actor: claude-code
  id: 01kyfwj51xe2ezkp0e1zzgbhtg
  text: |-
    Seam rows 3 and 4 closed; rows 1 and 2 next.

    **Row 4 — `SetSessionConfigOptionRequest`** (taken first, as instructed). The three coupled `SchemaGenerator.swift` edits landed, plus one the recipe did not name: `unionVariants(of:)` is the shared catch-all filter, and the value-union stage now needs the *opposite* answer from every other stage. Split into `unionVariants(of:)` (drops every catch-all — the string-enum, tagged-union, and discriminated-union emitters synthesize their own fallback) and `valueUnionVariants(of:)` (keeps a catch-all that declares a member beyond the discriminator, because there the catch-all *is* the default case). Both read `declaredUnionVariants(of:)`. Skip that split and the bare catch-all in `objectValueUnionWithBareFallbackSchema` becomes a second default and generation throws `expected exactly one default value variant, found 2`.

    `ValueUnionCaseModel.tag: String?` became `selector: ValueUnionSelector` with three cases — `.tag`, `.untagged`, `.capturedTag`. Two boolean-ish fields would have been an implicit invariant; the union genuinely has three states, because the pre-existing discriminator-less default (`objectValueUnionSchema`'s `text`) still exists beside the new catch-all and still takes one associated value and re-encodes no tag.

    **Row 3 — `AuthMethod`, `PlanUpdateContent`, `ReplayFrom`.** `isUnknownFallbackVariant` lost its `pinned:` parameter entirely: with a fallback that carries payload, what a catch-all declares no longer decides anything. The `const`-pinning half of the old predicate is what still defers (`valueUnionWithConstPinningFallbackSchema`), so that guard stayed in `classifyAnyOf`.

    **`unknown(String)` -> `unknown(String, JSONValue)` is an emitter-wide change, not a per-definition one.** `taggedUnionDeclaration` and `discriminatedUnionDeclaration` each emit one fallback shape for every union they render, so all 19 unions in `Unions.generated.swift` gained the payload-carrying fallback, not just the three. That is the right answer anyway — a `session/update` variant a newer peer adds was being truncated too — but it is worth knowing the diff is wider than the card's three names.

    **The payload is the raw object *less* the discriminator**, via two new `JSONValue` members in `Core/JSONValue.swift`: `init(from:excludingMember:)` and `encodeMembers(to:)`. Capturing the whole object instead would put the tag in two places that can disagree. `encodeMembers` writes through a dynamic-key keyed container — `JSONValue.encode(to:)` uses a *single-value* container, and calling that on an encoder that already vended a keyed container traps rather than merging, so `try payload.encode(to: encoder)` (what the struct-payload cases do) is not available here.

    **Verification, not assertion.** `Tests/FoundationModelsACPTests/` is new (added to `Package.swift`) and holds `UnknownFallbackRoundTripTests`, 10 tests. Round-trips compare parsed `JSONValue` trees, not text, since member order is not part of a JSON document's value. Checked the cover is real: reverting the emitter so the fallback drops tag and payload turns **7 of the 10 red**; restored and green again.

    Suite: 84 tests / 10 suites. `swift build` and the generated-output diff gate are green at this point.
  timestamp: 2026-07-26T18:56:23.101116+00:00
- actor: claude-code
  id: 01kyg254hm56d1bmndncr8mkag
  text: |-
    ## M1 complete — seam closed, green, ready for review

    **Final state.** `swift build --build-tests` clean. `swift test`: **123 tests / 16 suites**, zero failures (was 64 / 9). DocC builds clean under `--warnings-as-errors`. Regenerating from the vendored artifacts with the hash stamp dropped is a byte-for-byte no-op, so the CI codegen diff gate passes.

    ### Scope: the seam was six definitions, not four

    The card's *placeholder seam* section and the handover both say "four". `plan.md`'s table has **five rows of deferrals**, and rows 1-4 hold **six** definitions — the four named plus `ErrorCode` (row 1) and `DiffChange` / `SessionConfigOption` (row 2). Since the completion signal is defined over rows 1-4, resolving only the named four could never have made it go green. All six are resolved. Row 5's eight stay deferred, deliberately.

    Two of the six needed a new emission family rather than a fallback change:
    - **`ErrorCode`** — the enum stage was string-only. It is now scalar-kind-driven by one `enumRawKinds` table mapping the JSON `type` keyword to the raw Swift type, so `ErrorCode` emits `unknown(Int)`. An integer cannot name its own case, so integer-enum cases are named from each variant's `title` through a new `swiftCaseName(fromTitle:)` that splits on whitespace as well as underscores.
    - **`DiffChange` / `SessionConfigOption`** — new `.objectTaggedUnion` family: base struct plus a nested `Payload` enum. Nested name is fixed rather than derived from the discriminator, because `SessionConfigOption`'s discriminator is `type` and `SessionConfigOption.Type` is metatype syntax. `objectValueUnionDeclaration` and `objectTaggedUnionDeclaration` share one `objectCarryingAUnion` renderer; the struct scaffolding was identical.

    ### Completion signal, derived rather than trusted

    Ran the same orphan analysis over `HEAD`'s generated output and over the working tree: **26 orphan declarations before, 16 after**, and the set difference is exactly the ten `plan.md` names (`AuthMethodAgent`, `DiffPathChange`, `DiffPathPairChange`, `PlanItems`, `ReplayFromStart`, `SessionConfigBoolean`, `SessionConfigId`, `SessionConfigSelect`, `DiffFileType`, `SessionConfigOptionCategory`). Total declarations unchanged at 146 both times — the placeholders became structs and enums in place. Method: parse every top-level declaration, then ask whether any *other* declaration mentions its name as an identifier or as a routing-table string literal.

    Two corrections to the handover's phrasing of that signal. It says "eight structs"; the group is **ten declarations** — eight structs and two enums, which is what `plan.md` says. It says "six JSON-RPC envelope types"; there are **five** (`AgentRequest`, `AgentNotification`, `ClientRequest`, `ClientNotification`, `ProtocolLevelNotification`), and the sixth is presumably one of the two routing roots, which `plan.md` counts separately.

    ### What the adversarial review caught, and what it cost

    Ran `double-check`. It returned REVISE with seven findings. Two were real defects in shipped behaviour, and both are now fixed with cover:

    - **A hand-built fallback payload could hijack the discriminator.** Two keyed containers over one encoder share an object and the *later* write wins, so `AuthMethod.unknown("_vendor_sso", ["type": "agent"])` encoded `{"type":"agent"}` — silently re-decoding as a different variant — and a nested payload could overwrite a base property. Wire-sourced values were safe because decode drops those names, but the cases are public and take two associated values. `encodeMembers(to:reserving:)` now rejects a payload claiming an owned name, and the emitter emits the same list on both arms from one helper so the two cannot drift.
    - **My exhaustive tag probe was swallowing 37 of 44 tags.** It treated any `DecodingError` as "the tag matched", but a union reading the *wrong* discriminator key throws `keyNotFound` before comparing any tag, so nine of thirteen unions were asserting nothing. My first fix for this was also wrong — it compared `key.stringValue` to the discriminator, which a wrong-key union never produces — and I only found that out because the mutation test I ran to prove the fix did not go red. The working answer is a separate premise test, `everyUnionReadsTheDiscriminatorItsVariantsPin`, which decodes an unmatched tag per union outside any catch.

    The other five were a wrong count in a doc comment (my `_meta` classifier missed a description that wraps "are\nequivalent" across a newline — it is five, not four), a stale "8 of them" in a generator comment that this change itself invalidated, a missing collision guard on `objectValueUnionModel` that its sibling stage had, an unsanitized `valueEnumName`, and an `ACP.swift` doc describing a directory that does not exist. All fixed; the two new generator guards are covered by tests that pin the detail string rather than just asserting "it threw".

    **Re-verification was requested and did not return** after ~35 minutes. The gate is advisory in `really-done` and bounded to one re-check; the hard requirement — verification commands green — is satisfied above, and every finding from the completed round was acted on rather than argued past. One suggestion was deliberately not taken: guarding a *flattened payload's* member names against the base object's. No vendored payload collides today, and it belongs with whatever change introduces one.

    ### Verified by mutation, not by assertion

    Each behavioural claim was checked by breaking the production code and watching the right tests go red:
    - Fallback drops tag and payload -> **7 of 10** `UnknownFallbackRoundTripTests` red.
    - Every emitted tag mangled -> **exactly 44** probe failures, matching the 44 tags derived independently from the schema.
    - Integer enums removed from `enumRawKinds` -> both `ErrorCode` tests red.
    - Owned-member guard stubbed out -> the hijack test red.
    - Emitted `CodingKeys` raw value mangled -> `everyUnionReadsTheDiscriminatorItsVariantsPin` red.
    All restored and green after each.

    ### Left deferred, and why

    - **Three-state patch semantics.** v2 gives upsert fields three wire states — omitted leaves unchanged, `null` clears, a value replaces — and a Swift `Optional` has two, so a client meaning "clear" currently sends "unchanged". Six `_meta` fields say so explicitly and the same rule governs their siblings' other fields. Carded as ^1pfngj1, noted on M7 (^4vnprpg), and pinned in its current-behaviour form by `MetaFieldTests.upsertMetaCannotYetDistinguishOmittedFromNull` so it fails loudly when fixed. The one acceptance-criteria checkbox left unticked.
    - **Row 5's eight placeholders.** Three are the extension escape hatch with no stated shape; five are untagged unions whose branches pin no discriminator. `VendoredSchemaTests.onlyTheDeliberatelyFreeFormDefinitionsStayUntyped` pins the list by name.

    ### For the next agent

    - **This card's own record was corrupted** by the handover comment: a wrapped line put a table separator at column zero, which split the YAML document, truncated that comment mid-sentence, and left the card reading `title: Untitled` with its front matter stranded in the description body. Repaired through the kanban API — comment restored with the separator described in prose, title and description and `depends_on` restored. The warning in that comment was right; it just could not survive stating itself literally.
    - **`unknown(String)` -> `unknown(String, JSONValue)` is emitter-wide**, so all 11 stand-alone tagged unions changed, not just the three named. That is why the generated diff is large.
    - The `.discriminatedUnion` family matches **zero** vendored definitions — only synthetic generator tests reach it. Worth knowing before assuming a change there is covered by the vendored suite.
    - `swift format` was never run, per the standing warning.
  timestamp: 2026-07-26T20:34:08.052103+00:00
depends_on:
- 01KYD58WKPK64VW7RWG16B89QC
position_column: doing
position_ordinal: '80'
title: M1 Types and conventions, enforced at decode time
---
## Starting point

**This is a rewrite.** `plan.md` -> *Starting point* has the full inventory.

**Survives from v1, do not rewrite:** `Core/JSONValue.swift`, `Core/AbsolutePath.swift`, `Core/MethodInfo.swift`, `Core/WireRawValueCodable.swift`. These are v2-agnostic and the generator itself imports them. `AbsolutePath` already rejects relative paths at decode time.

**Already restored in M0:** `Core/ProtocolVersion.swift` (now carrying `.v2`) and `Core/ForgivingDecoding.swift` — the regenerated v2 output references them and would not compile otherwise. The checked-in generated output **compiles today**; this task no longer opens with a make-it-build step.

**Deleted, and yours to rebuild:** `Core/ACP.swift` (the namespace anchor) and `Connection/RequestError.swift`. Their v1 implementations are in git history and were sound; recovering and re-checking them against v2 is legitimate and faster than reinventing.

**`Core/LineNumber.swift` is deliberately *not* restored** — see *Conventions* below. Nothing in the v2 output references it.

## What

`plan.md` -> **M1** and **Conventions the type system should enforce**.

Generated models, unions, and enums from the v2 schema, plus the hand-written pieces that are deliberately never generated: `JSONValue`, `AbsolutePath`, `RequestError`, and the `unknown(String)` fallbacks.

**Conventions are type-system obligations, not documentation:**

- **Absolute paths everywhere.** An `AbsolutePath` newtype turns a relative path into a decode-time error rather than a runtime surprise three layers up. v2 gives absolute paths a first-class `AbsolutePath` schema `$def`, so the invariant rides each field's own `$ref` and the generator needs no per-field override table — which is why `GeneratorConfig.acpV2.wireInvariantFields` is **empty by design**, and `AbsolutePath` is simply listed as hand-written. A per-field table would only be a second, drift-prone copy of the schema.
- **No line-number invariant. This is a deliberate divergence from v1, not an oversight.** v1 stated 1-based line numbers and enforced them through a hand-written `LineNumber` type and a `.lineNumber` entry in `wireInvariantFields`. **v2 states no such thing.** The vendored schema has exactly one line-valued field, `ToolCallLocation.line`, described only as *"Optional line number within the file"* — and it carries `minimum: 0`, so the schema explicitly permits `0`. The v2 tool-calls page does not state a base either. Enforcing 1-based would therefore **reject payloads v2 permits**. The generator keeps the override mechanism (still covered by `GeneratorCoreTests`) for a revision that states the invariant in prose alone, but nothing uses it today. Do not restore `LineNumber`, and do not add a `.lineNumber` mapping, until a re-vendor states the invariant.
- `camelCase` object keys, `snake_case` discriminator values.
- **Unknown values are accepted and preserved.** Unknown enum and tagged-union cases must round-trip intact when proxying -- v2 states this explicitly, and it is what allows a newer peer to talk to us without data loss. Values beginning with `_` are implementation-specific; unknown non-underscore values are reserved for future versions.
- `_meta` follows patch semantics in updates, scoped to its parent object.

## The placeholder seam M0 left for this task

Four union shapes currently defer to raw `JSONValue` rather than truncate what their catch-all carries, untyping fourteen properties in all — including `InitializeResponse.authMethods`, `PlanUpdate.plan`, `ResumeSessionRequest.replayFrom`, and the entire `session/set_config_option` params object. **`plan.md` -> *Milestones* -> M1 carries the full instructions**, including which one to take first (`SetSessionConfigOptionRequest`), the three coupled `SchemaGenerator.swift` edits it needs, and the round-trip test that must land in the same change. M2, M5, and M7 each note the surface this seam untypes for them; resolving it here is what unblocks their typed payloads.

## Test coverage to re-establish

The reset dropped these suites along with the v1 schema. They were real coverage, not ceremony — recreate them against v2 rather than letting them lapse:

- **`ForgivingDecodingTests`** — the forgiving-decode helpers. `ForgivingDecoding.swift` itself came back in M0; its tests did not.
- **`TaggedUnionRoundTripTests`** — runtime decode/encode of every generated tagged-union variant against wire fixtures: decode picks the right case, re-encoding is byte-equivalent modulo key order.
- **`UnknownFallbackRoundTripTests`** — runtime proof that unrecognized string-enum values and union discriminators decode to `.unknown` and re-encode their captured string.

## Acceptance Criteria

- [x] `ACP` and `RequestError` restored; the full v2 generated output still compiles.
- [x] Generated types cover the full v2 schema.
- [x] `AbsolutePath` rejects relative paths at decode time.
- [x] `ToolCallLocation.line` accepts `0` — no 1-based invariant is enforced anywhere.
- [x] Every enum and tagged union has an `unknown(String)` (or equivalent) fallback.
- [x] Decode -> encode round-trips preserve unknown cases and `_`-prefixed extensions byte-for-byte in content.
- [x] `RequestError` carries structured `data`; no JSON smuggled through the message string.
- [x] The three dropped suites above exist again, against v2 types.

## Tests

- [x] A relative path fails decoding with a clear error.
- [x] `ToolCallLocation` decodes with `line: 0`, with `line` omitted, and with `line: null` — the v1 test that required `0` to *fail* must not be recreated.
- [x] A payload with an unrecognized enum case round-trips without loss.
- [x] A payload with a `_customThing` extension round-trips without loss.
- [ ] `_meta` patch semantics: omitted vs null vs value behave per spec. **Partly.** Where the schema says omitted and `null` are equivalent, they are, and `nil` never encodes as an explicit null. Six upsert `_meta` fields say `null` is a distinct clear signal, which a Swift `Optional` cannot express; carded as ^1pfngj1 for M7 and pinned in its current form by `MetaFieldTests.upsertMetaCannotYetDistinguishOmittedFromNull`.
- [x] `JSONValue` round-trips all six kinds including nested containers.
