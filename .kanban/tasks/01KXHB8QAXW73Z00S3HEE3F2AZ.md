---
depends_on:
- 01KXHB88Q1GSGHMPXHNSMKM2XF
position_column: todo
position_ordinal: '8480'
title: 'Codegen: tagged unions and string enums with unknown(String) fallback'
---
## What
Extend `acp-generate` to emit the union shapes (spec §2, §3):

- **Tagged unions** (`oneOf` with discriminator `type` / `kind` / `sessionUpdate`) → Swift `enum` with associated values + hand-rolled `Codable` keyed on the discriminator. Covers `ContentBlock`, `SessionUpdate` (including `usageUpdate`, `currentModeUpdate`), `ToolCallContent` (including `terminal(TerminalId)`), `RequestPermissionOutcome`.
- **String enums** (`ToolKind`, `ToolCallStatus`, `StopReason`, `PermissionOptionKind`, plan entry status/priority, …) → enums with **hand-rolled `Codable`** mapping the snake_case wire strings (`in_progress`, `end_turn`, `allow_once`) and routing any unrecognized value to `unknown(String)` so a newer peer can't crash decoding. (Raw-value `String` enums can't carry that payload — must be hand-rolled.)
- On encode, `unknown(value)` re-emits its captured string.

## Acceptance Criteria
- [ ] Emitted union enums decode every discriminator variant in the vendored schema and re-encode byte-equivalent JSON (modulo key order)
- [ ] Decoding an unrecognized string-enum value (e.g. `"telepathy"` as a `ToolKind`) yields `.unknown("telepathy")`, not an error, and re-encodes as `"telepathy"`
- [ ] Wire strings are snake_case on the wire, camelCase cases in Swift

## Tests
- [ ] `Tests/ACPGenerateTests/TaggedUnionTests.swift` — decode/encode fixtures for each `SessionUpdate` and `ContentBlock` variant
- [ ] `Tests/ACPGenerateTests/UnknownFallbackTests.swift` — unknown discriminators and unknown string-enum values round-trip via `unknown(String)`
- [ ] Run `swift test` — exits 0

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.