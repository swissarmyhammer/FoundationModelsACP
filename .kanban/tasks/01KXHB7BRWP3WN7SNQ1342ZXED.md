---
depends_on:
- 01KXHB6V536ZBBFC24M9WQXWMM
position_column: todo
position_ordinal: '8180'
title: 'Hand-written core types: JSONValue, ProtocolVersion, AbsolutePath'
---
## What
Implement the hand-written primitive types the generated code and connection layer build on (spec §2, §3, §4), in `Sources/FoundationModelsACP/Core/`:

- `JSONValue.swift` — enum over arbitrary JSON: `.null, .bool, .number(Double), .string, .array([JSONValue]), .object([String: JSONValue])`; `Codable`, `Sendable`, `Hashable`. Used for `_meta`, `rawInput`, `rawOutput`, MCP env; preserved round-trip, never interpreted.
- `ProtocolVersion.swift` — `RawRepresentable` over `UInt16`; `static let v1 = 1`, `static let latest = v1`. Encodes/decodes as the **bare integer** `1`; decoding MUST reject strings like `"v1"` or `"1.0.0"` with a decoding error.
- `AbsolutePath.swift` — newtype over `String` enforcing the wire invariant (spec §4): initializer/decoder rejects relative paths.
- `LineNumber.swift` — newtype enforcing the other §4 wire invariant: ACP line numbers are **1-based**; initializer/decoder rejects `0` (and negatives). Both invariants are compile- or decode-time errors, not silent interop bugs — the generator (separate task) maps schema path/location fields onto these types.

## Acceptance Criteria
- [ ] `JSONValue` round-trips arbitrary JSON (including nested objects/arrays and `null`) byte-equivalently modulo key order
- [ ] `ProtocolVersion(rawValue: 1)` encodes to `1` (bare integer); decoding `"v1"` and `"1.0.0"` throws
- [ ] `AbsolutePath` decode of `"relative/path"` throws; `"/abs/path"` succeeds
- [ ] `LineNumber` decode of `0` throws; `1` succeeds and encodes as the bare integer
- [ ] All four are `Sendable` and compile under Swift 6 strict concurrency

## Tests
- [ ] `Tests/FoundationModelsACPTests/JSONValueTests.swift` — round-trip of nested fixtures, `_meta` preservation
- [ ] `Tests/FoundationModelsACPTests/ProtocolVersionTests.swift` — bare-int encode, string rejection
- [ ] `Tests/FoundationModelsACPTests/WireInvariantTests.swift` — AbsolutePath relative rejection / absolute accept; LineNumber zero rejection / 1-based accept
- [ ] Run `swift test` — exits 0

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.