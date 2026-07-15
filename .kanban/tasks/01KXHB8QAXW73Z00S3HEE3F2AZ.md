---
comments:
- actor: wballard
  id: 01kxj1epv7rwqftcnkc7kapf0r
  text: |-
    Picked up; schema research complete. The 12 oneOf defs split cleanly (trusting the schema over the card's illustrative list):

    STRING ENUMS (7) — oneOf of {type:string, const} variants: ToolKind (10 cases incl. switch_mode), ToolCallStatus (4), Role (2), PermissionOptionKind (4), StopReason (5 incl. max_turn_requests), PlanEntryPriority (3), PlanEntryStatus (3).

    TAGGED UNIONS (5) — every variant is internally-tagged serde style: {type:object, required:[<disc>], properties:{<disc>:{const:tag}}, allOf:[{$ref: Payload}]} with payload FLATTENED at the same level as the discriminator; allOf may be absent (payload-less variant):
    - ContentBlock (disc `type`): text/TextContent, image/ImageContent, audio/AudioContent, resource_link/ResourceLink, resource/EmbeddedResource
    - SessionUpdate (disc `sessionUpdate`, 11 variants): user_message_chunk|agent_message_chunk|agent_thought_chunk → ContentChunk (NOT bare ContentBlock as plan.md sketches), tool_call/ToolCall, tool_call_update/ToolCallUpdate, plan/Plan, available_commands_update/AvailableCommandsUpdate, current_mode_update/CurrentModeUpdate, config_option_update/ConfigOptionUpdate, session_info_update/SessionInfoUpdate, usage_update/UsageUpdate
    - ToolCallContent (disc `type`): content/Content, diff/Diff, terminal/Terminal (payload is the Terminal struct wrapping terminalId — NOT bare TerminalId as the card sketches)
    - RequestPermissionOutcome (disc `outcome` — not type/kind/sessionUpdate): cancelled (NO payload), selected/SelectedPermissionOutcome
    - SessionConfigOption (disc `type`): select/SessionConfigSelect, boolean/SessionConfigBoolean

    All 20 payload structs already exist in Models.generated.swift. The 11 anyOf defs (RequestID, McpServer, AuthMethod, AgentResponse, ClientResponse, ErrorCode, EmbeddedResourceResource, SessionConfigOptionCategory, SessionConfigSelectOptions, AvailableCommandInput, SetSessionConfigOptionRequest) stay as placeholder typealias seams — out of this task's scope (oneOf only), left for the full-surface task ^jx2apm3.

    Design: classifier gains stringEnum/taggedUnion kinds (oneOf that fits neither shape → GeneratorError, fail loud); new emitted file Unions.generated.swift keeps these out of the review-cap-busting Models.generated.swift; Unresolved.generated.swift shrinks to anyOf + free-form seams. String enums: hand-rolled Codable via wireValue property + init(wireValue:) pair, unknown(String) fallback re-encoding its captured string. Tagged unions: hand-rolled Codable keyed on discriminator, payload flattened via `payload.encode(to: encoder)` container merging; unknown(String) captures the discriminator only — re-encode emits just {disc: value}, unrecognized-variant payload fields are NOT preserved (matches card's unknown(String); routing/bridge tasks should know this).
  timestamp: 2026-07-15T04:44:40.167015+00:00
- actor: wballard
  id: 01kxj2hdte3kmy92qp9t393bt8
  text: |-
    Implementation landed (TDD RED→GREEN throughout). Summary:

    GENERATOR (ACPGenerateCore)
    - classify(): oneOf now resolves via classifyOneOf → stringEnum (all variants {type:string, const}) | taggedUnion (all variants discriminated objects) | GeneratorError on empty/mixed shapes. anyOf/enum keywords stay deferredUnion placeholder seams (reason string reworded to "until a later generator stage replaces it").
    - New models: EnumCaseModel/StringEnumModel, UnionCaseModel/TaggedUnionModel (SchemaModel.swift). New builders stringEnumModel/taggedUnionModel validate the serde internally-tagged shape hard: exactly one inline property (the discriminator) with const, required == [disc], consistent discriminator across variants, allOf must be a single payload $ref if present. swiftCaseName maps snake_case→camelCase and rejects non-identifier results AND Swift keywords (fail loud — `case default` would not compile); validateCaseNames rejects duplicates and collisions with the `unknown` fallback case.
    - Emitter: stringEnumDeclaration (wireValue property + init(wireValue:) pair, singleValueContainer Codable, unknown(String) fallback re-encoding its captured string) and taggedUnionDeclaration (CodingKeys on the discriminator, decode switches on the discriminator with payload decoded from the SAME decoder — internally-tagged flatten; encode writes the discriminator then payload.encode(to: encoder) merges into the same keyed object; payload-less variants supported; unknown(String) captures/re-emits the discriminator only).
    - NEW OUTPUT FILE Unions.generated.swift (~34 KB, under the review engine's 262144-byte cap) carries all 12 resolved oneOf types; Unresolved.generated.swift shrinks to the 11 anyOf + 3 free-form seams. Models/Identifiers byte-identical (refs already pointed at these names). Regeneration idempotent.

    TESTS (all mandated files present)
    - TaggedUnionTests.swift: TaggedUnionRoundTripTests — every variant of all 5 unions (5 ContentBlock, 11 SessionUpdate, 3 ToolCallContent, 2 RequestPermissionOutcome, 2 SessionConfigOption) round-trips byte-equivalent modulo key order (canonicalized-JSON comparison + decode-back equality); TaggedUnionEmissionTests — emitted-source assertions + fail-loud cases (mixed oneOf, torn discriminators, extra inline props, keyword wire value).
    - UnknownFallbackTests.swift: exhaustive wire↔case tables for all 7 string enums (31 values, decode + exact re-encode); unknown fallback round-trips (bare fragment, nested-in-payload sibling path, unknown union discriminators incl. payload-dropping re-encode assertion); missing discriminator still throws DecodingError.

    VERIFICATION: swift build clean; swift test 140/140 green (70 FoundationModelsACPTests + 70 ACPGenerateTests), zero warnings. Double-check verdict REVISE → all 3 findings fixed (exhaustive enum coverage, stale placeholder doc, keyword hardening); bounded re-check in flight. NOTE for routing/full-surface tasks (^tt9qwxj, ^jx2apm3): union types live in Unions.generated.swift; SessionUpdate.unknown re-encodes only {sessionUpdate: value} — unrecognized-variant payloads are not preserved by design.
  timestamp: 2026-07-15T05:03:37.806535+00:00
depends_on:
- 01KXHB88Q1GSGHMPXHNSMKM2XF
position_column: doing
position_ordinal: '80'
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