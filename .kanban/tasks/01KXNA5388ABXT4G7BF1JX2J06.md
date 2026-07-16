---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
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