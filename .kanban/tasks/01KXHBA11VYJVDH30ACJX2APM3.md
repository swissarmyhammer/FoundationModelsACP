---
depends_on:
- 01KXHB9KHBC38R4V0C82EM38TY
position_column: todo
position_ordinal: '8780'
title: Generate and check in the full v1 type surface + wire-conformance tests
---
## What
Run the finished generator against the vendored v1.19 schema, commit `Sources/FoundationModelsACP/Generated/*.swift`, and prove wire conformance (spec §2, §3, §6):

- Commit the full generated type surface: all request/response/notification payload types, `SessionUpdate`, `ContentBlock`, `ToolCall`/`ToolCallUpdate`, `Plan`, capabilities, permission types, `RequestError` (with codes -32700…-32603 plus ACP's -32000 authRequired and -32002 resourceNotFound, structured `data: JSONValue?` — never smuggle JSON through the message string), ID newtypes, and the Unstable namespace.
- Note (spec §7.2): v1.19 unified ID naming conventions — the generated newtypes come from regeneration, never hand-patched.
- Write wire-conformance tests against real JSON fixtures matching the published protocol docs.

## Acceptance Criteria
- [ ] Generated/ compiles as part of the package with no hand edits (consumers build with zero codegen)
- [ ] `initialize` request/response fixtures round-trip, with `protocolVersion` as bare integer `1`
- [ ] `_meta` on any message survives decode→encode untouched
- [ ] Unknown capability fields degrade to defaults; absent optionals are omitted (no `null`) on encode

## Tests
- [ ] `Tests/FoundationModelsACPTests/WireConformanceTests.swift` — fixture round-trips for `initialize`, `session/new`, `session/prompt`, `session/update` (every variant), `tool_call` lifecycle, `RequestError` with structured data
- [ ] `Tests/FoundationModelsACPTests/MetaPreservationTests.swift` — `_meta` round-trip on requests, responses, and notifications
- [ ] Run `swift test` — exits 0

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.