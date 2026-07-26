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
depends_on:
- 01KYD58WKPK64VW7RWG16B89QC
position_column: todo
position_ordinal: '8180'
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

- [ ] `ACP` and `RequestError` restored; the full v2 generated output still compiles.
- [ ] Generated types cover the full v2 schema.
- [ ] `AbsolutePath` rejects relative paths at decode time.
- [ ] `ToolCallLocation.line` accepts `0` — no 1-based invariant is enforced anywhere.
- [ ] Every enum and tagged union has an `unknown(String)` (or equivalent) fallback.
- [ ] Decode -> encode round-trips preserve unknown cases and `_`-prefixed extensions byte-for-byte in content.
- [ ] `RequestError` carries structured `data`; no JSON smuggled through the message string.
- [ ] The three dropped suites above exist again, against v2 types.

## Tests

- [ ] A relative path fails decoding with a clear error.
- [ ] `ToolCallLocation` decodes with `line: 0`, with `line` omitted, and with `line: null` — the v1 test that required `0` to *fail* must not be recreated.
- [ ] A payload with an unrecognized enum case round-trips without loss.
- [ ] A payload with a `_customThing` extension round-trips without loss.
- [ ] `_meta` patch semantics: omitted vs null vs value behave per spec.
- [ ] `JSONValue` round-trips all six kinds including nested containers.
