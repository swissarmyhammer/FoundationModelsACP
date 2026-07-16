---
assignees:
- claude-code
comments:
- actor: wballard
  id: 01kxndma3nsn0e9mxzt2f2qaen
  text: |-
    Implementation landed (TDD; generator-only, no hand edits to generated files). Summary + signature changes for consumers:

    GENERATOR (ACPGenerateCore)
    - classify(): anyOf now routes via classifyAnyOf. An object def carrying BOTH `type:object`+`properties` AND `anyOf` → .objectValueUnion; a pure-anyOf whose variants pin a `const` discriminator → .discriminatedUnion; every other anyOf (AuthMethod, EmbeddedResourceResource, AgentResponse/ClientResponse, ErrorCode, RequestID, SessionConfigOptionCategory/SelectOptions, AvailableCommandInput) stays .deferredUnion(anyOf). The `const`-discriminator trigger uniquely selects McpServer among pure-anyOf defs; the object+anyOf combo uniquely selects SetSessionConfigOptionRequest — both verified structurally against Schema/acp-v1.json.
    - New models DiscriminatedUnionModel / ObjectValueUnionModel (SchemaModel.swift) + builders discriminatedUnionModel / objectValueUnionModel (SchemaGenerator.swift). Shared discriminator-reading extracted to discriminatorTag(of:context:) (taggedUnionModel refactored onto it — byte-identical output for the 5 existing oneOf unions). Fail-loud on: no default variant, >1 default, discriminated variant without a single $ref payload, torn discriminators, >1 value member.
    - Emitter.swift: discriminatedUnionDeclaration + objectValueUnionDeclaration (+ valueUnion* helpers). Extracted codingKeyCase/encodeCall/initParameter shared with the struct emitter (output byte-identical). New Emitter file section is doc-first-line-period/param-labeled/named-constant clean.

    GENERATED TYPES (checked-in output regenerated; byte-idempotent — forced a second generate, git diff empty)
    - McpServer → Sources/.../Generated/Unions.generated.swift: `public enum McpServer: Codable, Hashable, Sendable { case http(McpServerHttp); case sse(McpServerSse); case stdio(McpServerStdio); case unknown(String) }`. Decode switches on decodeIfPresent(type): "http"/"sse" → those, nil → .stdio (missing-type default), any other → .unknown(preserved). Encode flattens the payload beside `type`; .stdio omits `type`; .unknown re-emits just `{type: value}`.
    - SetSessionConfigOptionRequest → Models.generated.swift: `public struct` with sessionId: SessionId, configId: SessionConfigId, value: Value, meta: JSONValue?, and a nested `public enum Value { case boolean(Bool); case valueId(SessionConfigValueId) }`. Value decodes type=="boolean" → .boolean; default branch (absent OR unknown type) decodes `value` as SessionConfigValueId → .valueId (this is the unknown-type-with-string graceful fallback). .valueId encodes with no discriminator.
    - Neither name remains in Unresolved.generated.swift (grep count 0). Remaining 9 anyOf + 3 free-form seams unchanged.

    CONSUMER MIGRATIONS (McpServer/SetSessionConfigOptionRequest are no longer = JSONValue)
    - SessionProvider.MCPServerConfig (= McpServer) is now the enum. Tests/.../Bridge/SessionProviderTests.swift builds `.stdio(McpServerStdio(args:[],command:AbsolutePath("/usr/local/bin/srv")!,env:[],name:"srv"))` instead of `.object([...])`.
    - Tests/.../RoleDispatchTests.swift builds `SetSessionConfigOptionRequest(configId:sessionId:value:.valueId(...))` instead of `.object([...])`.
    - Tests/ACPGenerateTests/TaggedUnionTests.swift deferred-seam assertion updated McpServer → AuthMethod (still deferred).
    - Bridge/SessionProvider.swift + Connection/{Agent,ClientSideConnection,AgentSideConnection}.swift reference the type name only (still valid; now a real type).

    TESTS ADDED: Tests/ACPGenerateTests/AnyOfUnionTests.swift (8 — vendored emission for both types, miniature discriminatedUnion + objectValueUnion positive classification, 3 fail-loud cases) and Tests/FoundationModelsACPTests/McpServerWireTests.swift (7 — http/sse/stdio round-trips, unknown-type preservation, boolean + value_id + unknown-type-string-fallback).

    VERIFY: swift build clean; swift test --skip FoundationModelsACPEvals → 185 FoundationModelsACPTests + 116 ACPGenerateTests = 301, exit 0, zero warnings. swift run acp-generate byte-idempotent (regeneration leaves Generated/ unchanged).
  timestamp: 2026-07-16T12:15:09.941801+00:00
- actor: wballard
  id: 01kxndxsf48qf8gpmgdg5p72qw
  text: |-
    Review pass 1: CLEAN, converged in one iteration → done.

    `review sha HEAD~1..HEAD` cannot run as a single batch: Models.generated.swift is 266808 bytes, over the engine's 262144-byte batch cap (expected per the codegen threads). Reviewed per-file instead, excluding that machine-generated artifact (validated via the generator tests):
    - Sources/ACPGenerateCore/{SchemaGenerator,Emitter,SchemaModel}.swift — 0 findings (14 rules attempted, 0 failed).
    - Tests/{ACPGenerateTests/AnyOfUnionTests,FoundationModelsACPTests/McpServerWireTests}.swift (new) — 0 findings.
    - Sources/.../Generated/{Unions,Unresolved}.generated.swift (under cap) — 0 findings.
    Existing-test edits (TaggedUnionTests/SessionProviderTests/RoleDispatchTests) are the mandatory call-site migrations, out of review scope per the existing-test exception.

    CI diff gate re-verified: `swift run acp-generate` then `git diff --exit-code Sources/.../Generated/` → exit 0 (byte-idempotent). Final commit b575541 (local only, not pushed). swift test --skip FoundationModelsACPEvals → 185 + 116 = 301 tests, exit 0, zero warnings.
  timestamp: 2026-07-16T12:20:20.580121+00:00
position_column: done
position_ordinal: '9780'
title: 'Codegen: resolve McpServer and SetSessionConfigOptionRequest placeholder seams into typed unions'
---
## What

`Sources/FoundationModelsACP/Generated/Unresolved.generated.swift` typealiases 14 schema definitions to `JSONValue` as "placeholder seams". Two of them are consumer-facing on stable v1 methods and must become real types:

- **`McpServer`** — `NewSessionRequest.mcpServers` is currently effectively `[JSONValue]` (surfaced to users as `typealias MCPServerConfig = McpServer` in `Sources/FoundationModelsACP/Bridge/SessionProvider.swift`). The schema (`Schema/acp-v1.json` `$defs.McpServer`) is an `anyOf` whose variants carry a `const` `type` discriminator: `"http"` → `McpServerHttp`, `"sse"` → `McpServerSse`, and a discriminator-less default → `McpServerStdio`. All three payload structs are already generated in `Sources/FoundationModelsACP/Generated/Models.generated.swift`. Generate `McpServer` as a tagged union enum (`http`/`sse`/`stdio` + `unknown(String)` fallback, per the existing union conventions in `Unions.generated.swift`), with the rule "missing `type` on the wire decodes as `stdio`".
- **`SetSessionConfigOptionRequest`** — currently `JSONValue` while its Response is a real struct. The schema is an object (`sessionId`, `configId`, `_meta`) merged with a top-level `anyOf` for the value: a `type: "boolean"` const variant and a default `value_id` variant (string `SessionConfigValueId`, also the graceful fallback for unknown `type` + string payload). Generate the struct with a typed nested value union honoring that default/fallback rule.

Implementation lives in the generator, not hand-edits: extend classification in `Sources/ACPGenerateCore/SchemaGenerator.swift` (`classify` currently sends any top-level `anyOf` to `.deferredUnion` — see `SchemaModel.swift` `case deferredUnion`) to recognize (a) `anyOf` with const-`type` discriminators + one default variant, and (b) object-with-embedded-`anyOf`; emit via `Sources/ACPGenerateCore/Emitter.swift`. Then `swift run acp-generate` to regenerate; the two names must move out of `Unresolved.generated.swift`. Remaining placeholders (e.g. `RequestID`, `ErrorCode`, `AgentResponse`) stay deferred — update their doc header only if the wording changes. The CI diff gate (`.github/workflows/ci.yml`) must stay green, i.e. regenerated output is committed.

Migrate call sites that currently rely on `McpServer == JSONValue` (e.g. `Tests/FoundationModelsACPTests/Bridge/SessionProviderTests.swift` builds `[MCPServerConfig] = [.object(...)]`) to the typed variants.

## Acceptance Criteria

- [ ] `McpServer` is a generated tagged union with `http`/`sse`/`stdio` cases wrapping the existing payload structs and an unknown fallback; a JSON object without `type` decodes as `.stdio`; encode re-emits the correct discriminator (none for stdio if that is the wire form).
- [ ] `SetSessionConfigOptionRequest` is a generated struct with typed `sessionId`/`configId`/`_meta` and a typed value union (boolean variant + `value_id` default, unknown-`type`-with-string-payload falls back to `value_id`).
- [ ] Neither name appears in `Unresolved.generated.swift` after `swift run acp-generate`; generated output is committed and `git diff --exit-code` passes after a fresh generate (CI diff gate).
- [ ] Decoding is forgiving per existing conventions: malformed variants degrade without throwing where the union conventions allow, and unknown discriminators are preserved through encode.

## Tests

- [ ] Generator-level tests in `Tests/ACPGenerateTests/` (alongside the existing `GeneratorCoreTests.swift`) covering the two new classifications.
- [ ] Wire-conformance tests in `Tests/FoundationModelsACPTests/WireConformanceTests.swift` (or a new `McpServerWireTests.swift`): decode/encode round-trip for http, sse, stdio (with and without explicit `type`), unknown-type preservation; `SetSessionConfigOptionRequest` boolean and value_id forms.
- [ ] `swift test --skip FoundationModelsACPEvals` → green; `swift run acp-generate && git diff --exit-code` → clean.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.