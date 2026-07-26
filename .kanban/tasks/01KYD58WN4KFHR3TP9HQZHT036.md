---
depends_on:
- 01KYD58WKPK64VW7RWG16B89QC
position_column: todo
position_ordinal: '8180'
title: M1 Types and conventions, enforced at decode time
---
## Starting point

**This is a rewrite.** `plan.md` -> *Starting point* has the full inventory.

**Survives from v1, do not rewrite:** `Core/JSONValue.swift`, `Core/AbsolutePath.swift`, `Core/MethodInfo.swift`, `Core/WireRawValueCodable.swift`. These are v2-agnostic and the generator itself imports them. `AbsolutePath` already rejects relative paths at decode time.

**Deleted, and yours to rebuild:** `Core/LineNumber.swift`, `Core/ProtocolVersion.swift`, `Core/ForgivingDecoding.swift`, `Core/ACP.swift` (the namespace anchor), and `Connection/RequestError.swift`. The generator still *emits* references to `LineNumber`, `ProtocolVersion`, and the `forgivingDecode*` helpers, so the v2 generated output will not compile until you restore them — that is the first thing to do in this task, before anything else.

Their v1 implementations are in git history and were sound; recovering and re-checking them against v2 is legitimate and faster than reinventing.

## What

`plan.md` -> **M1** and **Conventions the type system should enforce**.

Generated models, unions, and enums from the v2 schema, plus the hand-written pieces that are deliberately never generated: `JSONValue`, `AbsolutePath`, `RequestError`, and the `unknown(String)` fallbacks.

**Conventions are type-system obligations, not documentation:**

- **Absolute paths everywhere.** An `AbsolutePath` newtype turns a relative path into a decode-time error rather than a runtime surprise three layers up.
- **1-based line numbers.** Same treatment.
- `camelCase` object keys, `snake_case` discriminator values.
- **Unknown values are accepted and preserved.** Unknown enum and tagged-union cases must round-trip intact when proxying -- v2 states this explicitly, and it is what allows a newer peer to talk to us without data loss. Values beginning with `_` are implementation-specific; unknown non-underscore values are reserved for future versions.
- `_meta` follows patch semantics in updates, scoped to its parent object.

## Test coverage to re-establish

The reset dropped these suites along with the v1 schema. They were real coverage, not ceremony — recreate them against v2 rather than letting them lapse:

- **`ForgivingDecodingTests`** — the forgiving-decode helpers, deleted with `ForgivingDecoding.swift`.
- **`TaggedUnionRoundTripTests`** — runtime decode/encode of every generated tagged-union variant against wire fixtures: decode picks the right case, re-encoding is byte-equivalent modulo key order.
- **`UnknownFallbackRoundTripTests`** — runtime proof that unrecognized string-enum values and union discriminators decode to `.unknown` and re-encode their captured string.

## Acceptance Criteria

- [ ] `LineNumber`, `ProtocolVersion`, `ForgivingDecoding`, `RequestError` restored; generated v2 output compiles.
- [ ] Generated types cover the full v2 schema.
- [ ] `AbsolutePath` rejects relative paths at decode time; 0-based line numbers rejected likewise.
- [ ] Every enum and tagged union has an `unknown(String)` (or equivalent) fallback.
- [ ] Decode -> encode round-trips preserve unknown cases and `_`-prefixed extensions byte-for-byte in content.
- [ ] `RequestError` carries structured `data`; no JSON smuggled through the message string.
- [ ] The three dropped suites above exist again, against v2 types.

## Tests

- [ ] Relative path and 0-based line each fail decoding with a clear error.
- [ ] A payload with an unrecognized enum case round-trips without loss.
- [ ] A payload with a `_customThing` extension round-trips without loss.
- [ ] `_meta` patch semantics: omitted vs null vs value behave per spec.
- [ ] `JSONValue` round-trips all six kinds including nested containers.
