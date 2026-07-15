---
comments:
- actor: wballard
  id: 01kxhngxxqaznsphjs03zzdw9a
  text: |-
    Picked up; schema research complete. Key discoveries about Schema/acp-v1.json (v1.19.0) for this and later codegen tasks:

    - 142 $defs: 105 objects, 10 bare-string ID newtypes (SessionId, ToolCallId, TerminalId, PermissionOptionId, SessionModeId, AuthMethodId, MessageId, SessionConfigGroupId, SessionConfigId, SessionConfigValueId), 12 oneOf (unions + string enums, LATER), 11 anyOf (unions, LATER), 3 untyped free-form (ExtRequest/ExtResponse/ExtNotification), 1 integer (ProtocolVersion — hand-written in Core, generator must skip).
    - Forgiving decoding is DATA-DRIVEN: the schema carries `x-deserialize-default-on-error` (serde DefaultOnError) and `x-deserialize-skip-invalid-items` (VecSkipError) extension keywords plus `default` values. No need to hardcode which fields are forgiving.
    - Contrary to the ^zwttegj meta-manifest finding, the MAIN schema DOES carry `x-side`/`x-method` on each request/response def (e.g. NewSessionRequest: x-side=agent, x-method=session/new) — 43 defs have them. Routing task can use either these or the meta routing tables.
    - Optionality = absence from `required` + nullable unions `type: [X, "null"]` / `anyOf: [$ref, null]`. `allOf: [$ref]` is the standard ref-with-description wrapper.
    - No `const` discriminator fields inside object defs and no Swift-keyword property names anywhere.
    - `AgentRequest`/`ClientRequest`/`AgentNotification`/`ClientNotification` are JSON-RPC envelope OBJECTS whose `params` is an inline anonymous anyOf — resolver maps unsupported inline fragments to JSONValue as the union seam.
    - `Error` def collides with Swift.Error — generator config renames it ACPError (def names never appear on wire, so rename is safe).
    - Wire-invariant field table (generator config): AbsolutePath for {CreateTerminalRequest,ListSessionsRequest,LoadSessionRequest,NewSessionRequest,ResumeSessionRequest,SessionInfo}.cwd, {Diff,ReadTextFileRequest,ToolCallLocation,WriteTextFileRequest}.path, McpServerStdio.command, {LoadSessionRequest,NewSessionRequest,ResumeSessionRequest,SessionInfo}.additionalDirectories (element type); LineNumber for {ReadTextFileRequest,ToolCallLocation}.line. Invariant-mapped fields decode STRICT (override wins over x-deserialize-default-on-error) per the task's wire-invariant section.

    Plan: library target ACPGenerateCore (testable) + thin executable acp-generate; emit Identifiers/Models/Unresolved .generated.swift into Sources/FoundationModelsACP/Generated; deferred unions/enums emit as `public typealias X = JSONValue` placeholder seams so output compiles now and later stages replace them; forgiving-decode runtime helpers land in Core/ForgivingDecoding.swift.
  timestamp: 2026-07-15T01:16:10.039081+00:00
- actor: wballard
  id: 01kxhpw6a8c3j4rhw60ekzjv6z
  text: |-
    Implementation landed (TDD RED→GREEN throughout). Summary for later codegen tasks:

    STRUCTURE
    - New library target `ACPGenerateCore` (testable generator core) + thin executable `acp-generate` (Sources/acp-generate/main.swift; `swift run acp-generate [schema-path] [output-dir]`, defaults Schema/acp-v1.json → Sources/FoundationModelsACP/Generated).
    - Pipeline: parse (JSONDecoder→JSONValue, reusing the Core type) → classify defs (objectStruct | stringIdentifier | deferredUnion(oneOf/anyOf/enum) | freeform | handwritten) → build StructModel/PropertyModel → string-template emission (Emitter.swift). Unknown shapes throw GeneratorError — fail loud, never emit wrong types.
    - Output: Identifiers.generated.swift (10 ID newtypes on WireRawValueCodable — non-failable init(rawValue:) satisfies the failable requirement), Models.generated.swift (105 structs, 6.4k lines), Unresolved.generated.swift (26 placeholder `public typealias X = JSONValue` seams for the union/enum stages + free-form Ext*). All checked in and compiling as part of the library. Emission is deterministic (name-sorted defs; properties required-first, `_meta` last, alpha within groups) — reran generator, byte-identical.

    KEY DECISIONS (relevant to union/enum/routing stages)
    - GeneratorConfig.acpV1 carries: wire-invariant field table ("Def.field" → AbsolutePath/LineNumber, 17 entries incl. McpServerStdio.command and 4 additionalDirectories array fields), typeRenames ["Error" → "ACPError"] (shadowing Swift.Error), handwrittenDefinitions ["ProtocolVersion"]. Union stage should REPLACE the placeholder typealias in Unresolved.generated.swift with real types of the SAME names — refs already point at those names.
    - Invariant-mapped fields decode STRICT even when schema says default-on-error (relative cwd / line 0 throw — acceptance tested against real generated types).
    - Forgiving decoding is schema-driven: x-deserialize-default-on-error → forgivingDecode(IfPresent), x-deserialize-skip-invalid-items → forgivingDecodeArray(IfPresent). Runtime helpers live in Sources/FoundationModelsACP/Core/ForgivingDecoding.swift (internal; FailableDecodeBox + KeyedDecodingContainer extensions).
    - Object `default` values render as `Type()`; the generator VALIDATES recursively that the schema default object equals the target struct's own per-field defaults and throws on divergence (added after a double-check review finding; RED-first tests cover it). Non-empty object defaults on free-form JSONValue fields also throw.
    - Encode: explicit encode(to:) with encodeIfPresent for non-required optionals (nil omitted, never null); schema-required nullable fields would encode explicit null (none exist in v1.19.0).
    - structs emit Codable, Hashable, Sendable; explicit CodingKeys (raw value only for `_meta`→meta); public memberwise init with nil/schema defaults.

    STATUS: swift build clean, swift test 58/58 green (GeneratorCoreTests 12, ForgivingDecodingTests 16, GeneratedTypeAcceptanceTests 7, existing 23). Double-check verdict REVISE→fixed (object-default faithfulness validation); re-verification pending.
  timestamp: 2026-07-15T01:39:47.656991+00:00
depends_on:
- 01KXHB7BRWP3WN7SNQ1342ZXED
- 01KXHB7QEVKA0ZDJCRAZWTTEGJ
position_column: doing
position_ordinal: '80'
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
- [x] `swift run acp-generate` parses the vendored schema without error and emits compilable Swift for object/newtype shapes into a designated output dir
- [x] Emitted structs use explicit `CodingKeys`; encode omits nil fields; ID types are distinct (mixing two ID types is a compile error)
- [x] Generated `session/new` params type `cwd` as `AbsolutePath` and location types use `LineNumber`; decoding a relative cwd or a 0 line throws
- [x] A malformed capability field in a fixture decodes to defaults instead of throwing

## Tests
- [x] `Tests/ACPGenerateTests/GeneratorCoreTests.swift` — feed a miniature schema fixture, assert emitted Swift contains expected struct/newtype declarations, CodingKeys, and AbsolutePath/LineNumber field mappings
- [x] `Tests/ACPGenerateTests/ForgivingDecodingTests.swift` — compile-time fixture types + JSON fixtures proving defaults-on-error and nil-omission behavior
- [x] Run `swift test` — exits 0

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.