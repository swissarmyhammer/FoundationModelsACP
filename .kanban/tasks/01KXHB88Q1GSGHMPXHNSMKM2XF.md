---
depends_on:
- 01KXHB7BRWP3WN7SNQ1342ZXED
- 01KXHB7QEVKA0ZDJCRAZWTTEGJ
position_column: todo
position_ordinal: '8380'
title: 'Codegen generator core: structs, ID newtypes, optional/forgiving decoding'
---
## What
Build the custom schema→Swift generator's core (spec §2, §6; §10 generator choice resolved: custom, since the checked-in pipeline runs only on schema change and output is reviewed as a normal diff). Add an executable target `acp-generate` (e.g. `Sources/acp-generate/`) that parses `Schema/acp-v1.json` and emits idiomatic Swift for the non-union shapes:

- **Objects** → `struct` + `Codable` + explicit `CodingKeys` (wire camelCase: `sessionId`, `toolCallId`).
- **ID newtypes** (`SessionId`, `ToolCallId`, `TerminalId`, `PermissionOptionId`, `SessionModeId`, …) → distinct `RawRepresentable` structs, never bare `String`.
- **Wire-invariant field mapping (spec §4):** schema fields that carry file paths (`cwd` in `session/new`, `ToolCallLocation.path`, `fs/*` request paths) emit as the hand-written `AbsolutePath`, and line-number fields (e.g. `ToolCallLocation.line`, `fs/read_text_file` line) emit as `LineNumber` — never bare `String`/`Int` — so a relative path or 0-based line is a decode-time error. Maintain the field→invariant-type mapping as generator configuration reviewed with the output.
- **Capability-gated optional fields** → optionals; on encode, omit `nil` entirely (never emit `null`).
- **Forgiving decoding** for capability/`info` objects: defaults-on-error per field (the Rust SDK's `DefaultOnError`/`VecSkipError` equivalent) — an unknown or malformed capability field degrades to "unsupported", never fails the `initialize` handshake.
- Free-form fields (`_meta`, `rawInput`, `rawOutput`, MCP env) map to the hand-written `JSONValue`.
- Emission can be string-templating or SwiftSyntax — pick whichever yields readable, reviewable output; all emitted types are `Codable & Sendable`.

Tagged unions, string enums, and routing are follow-on tasks — structure the generator so they slot in.

## Acceptance Criteria
- [ ] `swift run acp-generate` parses the vendored schema without error and emits compilable Swift for object/newtype shapes into a designated output dir
- [ ] Emitted structs use explicit `CodingKeys`; encode omits nil fields; ID types are distinct (mixing two ID types is a compile error)
- [ ] Generated `session/new` params type `cwd` as `AbsolutePath` and location types use `LineNumber`; decoding a relative cwd or a 0 line throws
- [ ] A malformed capability field in a fixture decodes to defaults instead of throwing

## Tests
- [ ] `Tests/ACPGenerateTests/GeneratorCoreTests.swift` — feed a miniature schema fixture, assert emitted Swift contains expected struct/newtype declarations, CodingKeys, and AbsolutePath/LineNumber field mappings
- [ ] `Tests/ACPGenerateTests/ForgivingDecodingTests.swift` — compile-time fixture types + JSON fixtures proving defaults-on-error and nil-omission behavior
- [ ] Run `swift test` — exits 0

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.